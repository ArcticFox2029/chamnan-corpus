// Nguồn token kiểu service cho những lời gọi mà routing-service tự khởi xướng — hiện chỉ có
// customs-service. Token lấy bằng client credentials qua POST /v1/auth/token của
// identity-service và được giữ lại tới sát hạn, vì access token chỉ sống 15 phút
// (OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS) còn một lần lập tuyến có thể gọi ra ngoài chục lần.

package upstream

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ClientCredentials là cặp khoá của một dòng identity.api_credentials. KeyPrefix là phần hiện
// trên console và cũng là tay cầm để tra cứu; secret chỉ được identity-service trả về đúng một
// lần lúc tạo và nằm trong Secret của Kubernetes từ đó.
type ClientCredentials struct {
	KeyPrefix string
	Secret    string
}

// ServiceTokenCache hiện thực ServiceTokenSource.
type ServiceTokenCache struct {
	identityBaseURL string
	creds           ClientCredentials
	http            *http.Client

	mu        sync.Mutex
	token     string
	expiresAt time.Time
}

// refreshMargin là khoảng an toàn trước hạn. Đổi token sớm 60 giây rẻ hơn nhiều so với việc
// một lời gọi customs-service chết vì token hết hạn giữa đường.
const refreshMargin = 60 * time.Second

// NewServiceTokenCache dựng nguồn token trỏ vào identity-service.
func NewServiceTokenCache(identityBaseURL string, creds ClientCredentials) *ServiceTokenCache {
	return &ServiceTokenCache{
		identityBaseURL: strings.TrimRight(identityBaseURL, "/"),
		creds:           creds,
		http:            &http.Client{Timeout: 2 * time.Second},
	}
}

// Token trả token còn hạn, cấp mới khi cần.
func (c *ServiceTokenCache) Token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.token != "" && time.Until(c.expiresAt) > refreshMargin {
		return c.token, nil
	}

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", c.creds.KeyPrefix)
	form.Set("client_secret", c.creds.Secret)
	// Xin đúng phạm vi cần dùng, không hơn: routing-service chỉ đọc bảng thuế và tờ khai.
	form.Set("scope", "customs:read tariffs:read")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.identityBaseURL+"/v1/auth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-OF-Actor-Kind", "service")
	if id := TraceID(ctx); id != "" {
		req.Header.Set("X-OF-Trace-Id", id)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("identity-service không cấp được token: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("identity-service trả %d khi cấp token kiểu service", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", fmt.Errorf("phản hồi token không đọc được: %w", err)
	}

	c.token = body.AccessToken
	c.expiresAt = time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
	return c.token, nil
}

// Invalidate xoá token đang giữ. Gọi khi customs-service trả 401: khả năng cao credential vừa
// bị thu hồi và identity.credential.revoked đang trên đường tới.
func (c *ServiceTokenCache) Invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.token, c.expiresAt = "", time.Time{}
}
