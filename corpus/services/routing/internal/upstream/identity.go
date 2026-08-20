// Package upstream gom mọi thứ routing-service gọi ra ngoài. Đúng ba đích được phép theo §1.1:
// identity-service, geo-service và customs-service. Bất kỳ client nào khác xuất hiện trong
// package này đều là một cạnh đồng bộ mới trong đồ thị gọi, và §7 quy tắc 8 cấm điều đó.
package upstream

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	identityv1 "github.com/orbitalfreight/platform/libs/gen/go/identity/v1"
	"google.golang.org/grpc"
)

// Introspector là bề mặt mà tầng HTTP thấy. Có interface ở đây vì hai lý do rất cụ thể: test
// của httpapi không được mở kết nối gRPC, và chế độ ân hạn JWKS bên dưới cần được thay thế
// nguyên khối khi chạy thử kịch bản "identity-service sập".
type Introspector interface {
	Introspect(ctx context.Context, token, traceID string) (*Claims, error)
}

// Claims là phần kết quả introspection mà routing-service thật sự dùng. Trường Tid được so
// với header X-OF-Tenant ở middleware; lệch nhau là 403 theo §0.3.
type Claims struct {
	Subject   string
	Tid       string
	ActorKind string // user | service | device | partner
	Scopes    []string
	ExpiresAt time.Time
	Offline   bool // true khi kết quả đến từ chế độ ân hạn chứ không từ identity-service
}

// ErrCredentialScopedOffline được trả khi identity-service không với tới được và token là
// token của một credential (X-OF-Actor-Kind = service | partner | device). §1.2 nói rõ: khi
// mất identity-service, chỉ token người dùng mới được xác minh cục bộ bằng JWKS đã cache,
// còn lời gọi kiểu credential bị từ chối hẳn.
var ErrCredentialScopedOffline = errors.New("identity-service không sẵn sàng: từ chối lời gọi theo credential")

// GRPCIntrospector gọi identity.v1.TokenIntrospection/Introspect trên OF_IDENTITY_GRPC_ADDR.
// Đây là lời gọi mà mọi service trong nền tảng đều thực hiện trước khi làm bất cứ việc gì.
type GRPCIntrospector struct {
	client   identityv1.TokenIntrospectionClient
	jwks     *jwksCache
	grace    time.Duration
	timeout  time.Duration

	mu       sync.RWMutex
	lastGood time.Time
}

// NewGRPCIntrospector dựng client trên một kết nối đã có. Kết nối do cmd/routingd tạo và
// đóng, vì nó cũng chính là kết nối dùng cho /readyz.
func NewGRPCIntrospector(conn *grpc.ClientConn, jwksURL string, grace time.Duration) *GRPCIntrospector {
	return &GRPCIntrospector{
		client:  identityv1.NewTokenIntrospectionClient(conn),
		jwks:    newJWKSCache(jwksURL, grace),
		grace:   grace,
		timeout: 800 * time.Millisecond,
	}
}

// Introspect hỏi identity-service; nếu không với tới được thì rơi xuống xác minh chữ ký RS256
// cục bộ với bộ JWKS đã cache, nhưng chỉ trong OF_IDENTITY_JWKS_GRACE_SECONDS và chỉ cho token
// người dùng. traceID được chuyển tiếp nguyên vẹn để log của identity-service ghép được với log
// của chúng ta.
func (g *GRPCIntrospector) Introspect(ctx context.Context, token, traceID string) (*Claims, error) {
	ctx, cancel := context.WithTimeout(ctx, g.timeout)
	defer cancel()

	resp, err := g.client.Introspect(ctx, &identityv1.IntrospectRequest{
		Token:   token,
		TraceId: traceID,
	})
	if err == nil {
		if !resp.GetActive() {
			return nil, fmt.Errorf("token không còn hiệu lực")
		}
		g.mu.Lock()
		g.lastGood = time.Now()
		g.mu.Unlock()
		return &Claims{
			Subject:   resp.GetSubject(),
			Tid:       resp.GetTenantId(),
			ActorKind: resp.GetActorKind(),
			Scopes:    resp.GetScopes(),
			ExpiresAt: resp.GetExpiresAt().AsTime(),
		}, nil
	}

	claims, offlineErr := g.jwks.verify(token)
	if offlineErr != nil {
		return nil, fmt.Errorf("introspection thất bại (%v) và xác minh cục bộ cũng thất bại: %w", err, offlineErr)
	}
	if claims.ActorKind != "user" {
		return nil, ErrCredentialScopedOffline
	}
	claims.Offline = true
	return claims, nil
}

// Healthy phục vụ GET /readyz: readiness của routing-service phụ thuộc vào identity-service
// theo §3.15, còn liveness thì không.
func (g *GRPCIntrospector) Healthy(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	_, err := g.client.Introspect(ctx, &identityv1.IntrospectRequest{Token: "readyz-probe"})
	// Token rác trả về active=false chứ không trả lỗi truyền tải; chỉ lỗi truyền tải mới tính là sập.
	if isTransport(err) {
		return fmt.Errorf("identity-service không phản hồi: %w", err)
	}
	return nil
}

// jwksCache giữ khoá công khai lấy từ GET /.well-known/jwks.json của identity-service. Nó
// không tự làm mới theo lịch: khoá được nạp khi introspection thành công lần đầu và chỉ được
// dùng khi introspection hỏng, đúng cửa sổ ân hạn ở §1.2.
type jwksCache struct {
	url     string
	grace   time.Duration
	mu      sync.RWMutex
	fetched time.Time
	keys    map[string][]byte // kid -> DER của khoá công khai
}

func newJWKSCache(url string, grace time.Duration) *jwksCache {
	return &jwksCache{url: url, grace: grace, keys: map[string][]byte{}}
}

func (j *jwksCache) verify(token string) (*Claims, error) {
	j.mu.RLock()
	age := time.Since(j.fetched)
	empty := len(j.keys) == 0
	j.mu.RUnlock()

	switch {
	case empty:
		return nil, errors.New("chưa có JWKS nào được cache")
	case age > j.grace:
		return nil, fmt.Errorf("JWKS đã cache quá hạn ân hạn (%s > %s)", age.Truncate(time.Second), j.grace)
	}
	return parseAndVerifyRS256(token, j.snapshot())
}

func (j *jwksCache) snapshot() map[string][]byte {
	j.mu.RLock()
	defer j.mu.RUnlock()
	out := make(map[string][]byte, len(j.keys))
	for k, v := range j.keys {
		out[k] = v
	}
	return out
}
