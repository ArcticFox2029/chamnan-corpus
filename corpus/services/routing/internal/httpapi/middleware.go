// Chuỗi middleware áp cho mọi yêu cầu: sinh hoặc chuyển tiếp X-OF-Trace-Id, introspect token
// với identity-service, đối chiếu X-OF-Tenant với claim tid, và bắt buộc X-OF-Idempotency-Key
// trên mọi yêu cầu làm thay đổi trạng thái. Bốn header ở §0.3 được kiểm ở đây một lần, để các
// handler bên dưới không phải nhắc lại lần nào nữa.

package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

type ctxKey int

const (
	ctxTraceID ctxKey = iota
	ctxClaims
	ctxIdempotencyKey
)

// actorKinds là danh sách đóng của header X-OF-Actor-Kind (§0.3).
var actorKinds = map[string]struct{}{
	"user": {}, "service": {}, "device": {}, "partner": {},
}

// withTrace bảo đảm mọi yêu cầu đều có trace id 32 ký tự hex. Sinh mới ở biên khi thiếu, nhưng
// tuyệt đối không sinh đè lên cái đã có: chuỗi trace là thứ duy nhất ghép được log của
// fleet-service, routing-service và geo-service trong cùng một lần điều xe.
func withTrace(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		traceID := r.Header.Get("X-OF-Trace-Id")
		if len(traceID) != 32 || !isHex(traceID) {
			buf := make([]byte, 16)
			_, _ = rand.Read(buf)
			traceID = hex.EncodeToString(buf)
		}
		ctx := context.WithValue(r.Context(), ctxTraceID, traceID)
		ctx = upstream.WithTraceID(ctx, traceID)
		w.Header().Set("X-OF-Trace-Id", traceID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// withAuth gọi identity.v1.TokenIntrospection/Introspect và đối chiếu tenant. Đây là lời gọi mà
// cả mười ba dịch vụ còn lại đều thực hiện; identity-service không gọi ngược lại ai bao giờ.
func withAuth(introspector upstream.Introspector, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if token == "" || token == r.Header.Get("Authorization") {
				writeError(w, r, log, &apiError{
					code:    "missing_bearer_token",
					status:  http.StatusUnauthorized,
					message: "thiếu header Authorization: Bearer",
				})
				return
			}

			actorKind := r.Header.Get("X-OF-Actor-Kind")
			if _, ok := actorKinds[actorKind]; !ok {
				writeError(w, r, log, badRequest("invalid_actor_kind",
					"X-OF-Actor-Kind phải là user, service, device hoặc partner"))
				return
			}

			claims, err := introspector.Introspect(r.Context(), token, traceIDFrom(r.Context()))
			if err != nil {
				status := http.StatusUnauthorized
				code := "token_invalid"
				if errors.Is(err, upstream.ErrCredentialScopedOffline) {
					// identity-service đang sập và đây là token của credential: §1.2 buộc từ chối
					// hẳn thay vì tin vào JWKS đã cache.
					status, code = http.StatusServiceUnavailable, "identity_unavailable"
				}
				writeError(w, r, log, &apiError{
					code: code, status: status, message: err.Error(), retryable: status == 503, cause: err,
				})
				return
			}

			tenant := r.Header.Get("X-OF-Tenant")
			if tenant == "" || tenant != claims.Tid {
				// §0.3: lệch giữa header và claim là 403, không phải 401 — token hợp lệ, chỉ là
				// đang chỉ vào tenant khác.
				writeError(w, r, log, &apiError{
					code:    "tenant_mismatch",
					status:  http.StatusForbidden,
					message: "X-OF-Tenant không khớp claim tid của token",
				})
				return
			}

			ctx := context.WithValue(r.Context(), ctxClaims, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// withIdempotency bắt buộc X-OF-Idempotency-Key trên mọi phương thức không phải GET, và nhớ
// khoá đó trong 24 giờ theo §7 quy tắc 5. Bộ nhớ ở đây chỉ là lớp chặn nhanh; bảo đảm thật sự
// nằm ở ràng buộc UNIQUE (shipment_id, version) trên routing.routes, thứ sống sót qua cả việc
// khởi động lại pod lẫn việc hai bản sao cùng nhận một yêu cầu.
func withIdempotency(keys *idempotencyCache, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodGet || r.Method == http.MethodHead {
				next.ServeHTTP(w, r)
				return
			}
			key := r.Header.Get("X-OF-Idempotency-Key")
			if key == "" {
				writeError(w, r, log, badRequest("idempotency_key_required",
					"mọi yêu cầu thay đổi trạng thái phải mang X-OF-Idempotency-Key"))
				return
			}
			if keys.seen(key) {
				// Lặp lại trong cửa sổ 24 giờ: trả 409 kèm retryable=false để client dừng hẳn
				// thay vì thử lại với cùng khoá.
				writeError(w, r, log, &apiError{
					code:    "duplicate_request",
					status:  http.StatusConflict,
					message: "X-OF-Idempotency-Key này đã được dùng",
				})
				return
			}
			keys.remember(key)
			ctx := context.WithValue(r.Context(), ctxIdempotencyKey, key)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// withAccessLog ghi một dòng cho mỗi yêu cầu. Không ghi thân yêu cầu và không ghi định danh
// đầy đủ: log chảy sang một vùng khác, còn §7 quy tắc 7 nói dữ liệu của một vùng ở lại vùng đó.
func withAccessLog(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			log.Info("http",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", time.Since(start).Milliseconds(),
				"trace_id", traceIDFrom(r.Context()))
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// idempotencyCache nhớ khoá đã dùng trong 24 giờ.
type idempotencyCache struct {
	mu   sync.Mutex
	ttl  time.Duration
	keys map[string]time.Time
}

func newIdempotencyCache() *idempotencyCache {
	return &idempotencyCache{ttl: 24 * time.Hour, keys: map[string]time.Time{}}
}

func (c *idempotencyCache) seen(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	at, ok := c.keys[key]
	return ok && time.Since(at) < c.ttl
}

func (c *idempotencyCache) remember(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.keys[key] = time.Now()
}

// sweep dọn khoá quá hạn; cmd/routingd gọi mỗi giờ.
func (c *idempotencyCache) sweep() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	removed := 0
	for k, at := range c.keys {
		if time.Since(at) >= c.ttl {
			delete(c.keys, k)
			removed++
		}
	}
	return removed
}

func traceIDFrom(ctx context.Context) string {
	s, _ := ctx.Value(ctxTraceID).(string)
	return s
}

func claimsFrom(ctx context.Context) *upstream.Claims {
	c, _ := ctx.Value(ctxClaims).(*upstream.Claims)
	return c
}

func isHex(s string) bool {
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f':
		default:
			return false
		}
	}
	return true
}
