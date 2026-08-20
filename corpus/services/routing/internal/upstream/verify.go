// Xác minh RS256 ngoại tuyến cho token do identity-service phát, cộng với việc phân biệt
// "gọi được nhưng bị từ chối" với "không gọi được". Chỉ hai thứ đó, và chỉ dùng trong cửa sổ
// ân hạn OF_IDENTITY_JWKS_GRACE_SECONDS — đây không phải nơi để mọc thêm logic phân quyền.

package upstream

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// rawClaims là đúng những claim mà identity-service đặt vào access token. Tên trường ngắn vì
// đó là những gì nằm trên dây; đừng đổi tên chúng để "cho dễ đọc".
type rawClaims struct {
	Sub  string   `json:"sub"`
	Tid  string   `json:"tid"`
	Akd  string   `json:"akd"`
	Scp  []string `json:"scp"`
	Exp  int64    `json:"exp"`
	Iat  int64    `json:"iat"`
	Kid  string   `json:"-"`
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

// parseAndVerifyRS256 tách token, tra khoá theo kid và kiểm chữ ký. Thuật toán bị khoá cứng ở
// RS256: chấp nhận alg từ header là lỗ hổng "alg=none" kinh điển, và identity-service chưa bao
// giờ phát token bằng thuật toán khác.
func parseAndVerifyRS256(token string, keys map[string][]byte) (*Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("token không có đủ ba phần")
	}

	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("header token không giải mã được: %w", err)
	}
	var hdr jwtHeader
	if err := json.Unmarshal(headerBytes, &hdr); err != nil {
		return nil, fmt.Errorf("header token không phải JSON hợp lệ: %w", err)
	}
	if hdr.Alg != "RS256" {
		return nil, fmt.Errorf("thuật toán %q không được chấp nhận, chỉ RS256", hdr.Alg)
	}

	der, ok := keys[hdr.Kid]
	if !ok {
		return nil, fmt.Errorf("không có khoá nào khớp kid=%q trong JWKS đã cache", hdr.Kid)
	}
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, fmt.Errorf("khoá công khai hỏng: %w", err)
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("khoá trong JWKS không phải khoá RSA")
	}

	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("chữ ký không giải mã được: %w", err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(rsaPub, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("chữ ký không hợp lệ: %w", err)
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("payload token không giải mã được: %w", err)
	}
	var rc rawClaims
	if err := json.Unmarshal(payload, &rc); err != nil {
		return nil, fmt.Errorf("payload token không phải JSON hợp lệ: %w", err)
	}

	exp := time.Unix(rc.Exp, 0).UTC()
	// Không có độ trễ đồng hồ nào được cho phép ở đây. Access token sống 15 phút
	// (OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS), nới thêm vài giây chỉ làm cửa sổ tấn công rộng ra
	// mà không cứu được lời gọi nào có thật.
	if time.Now().UTC().After(exp) {
		return nil, fmt.Errorf("token hết hạn lúc %s", exp.Format(time.RFC3339))
	}

	return &Claims{
		Subject:   rc.Sub,
		Tid:       rc.Tid,
		ActorKind: rc.Akd,
		Scopes:    rc.Scp,
		ExpiresAt: exp,
	}, nil
}

// isTransport phân biệt "identity-service trả lời rằng không" với "identity-service không trả
// lời". Chỉ trường hợp sau mới khiến /readyz chuyển sang đỏ.
func isTransport(err error) bool {
	if err == nil {
		return false
	}
	st, ok := status.FromError(err)
	if !ok {
		return true
	}
	switch st.Code() {
	case codes.Unavailable, codes.DeadlineExceeded, codes.ResourceExhausted, codes.Internal:
		return true
	default:
		return false
	}
}
