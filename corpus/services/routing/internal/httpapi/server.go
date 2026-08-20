// Package httpapi là bề mặt HTTP duy nhất của routing-service: sáu endpoint nghiệp vụ ở §3.5
// cộng bốn endpoint bắt buộc ở §3.15. Dịch vụ này không có mặt gRPC — cột gRPC của nó ở §1 để
// trống — nên đây là toàn bộ cách gọi vào từ fleet-service và từ web console.
package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/orbitalfreight/platform/services/routing/internal/eta"
	"github.com/orbitalfreight/platform/services/routing/internal/planner"
	"github.com/orbitalfreight/platform/services/routing/internal/store"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// BuildInfo là thứ GET /version trả về: SHA của bản dựng, phiên bản semver và số migration mà
// bản này mong đợi. reconciliation-service so số migration khi nó gặp dữ liệu lạ.
type BuildInfo struct {
	Commit          string `json:"commit"`
	Version         string `json:"version"`
	SchemaMigration int    `json:"schema_migration"`
}

// Deps là toàn bộ phụ thuộc của tầng HTTP, truyền vào một lần lúc dựng server.
type Deps struct {
	Planner     *planner.Planner
	Ranker      *planner.CrossingRanker
	Directory   planner.FacilityDirectory
	Routes      *store.Routes
	Estimator   eta.Estimator
	Model       *eta.LaneModel
	Introspect  upstream.Introspector
	Ready       ReadinessProbe
	Build       BuildInfo
	// RegionCode là OF_REGION_CODE của chính pod này. Nó được đóng dấu lên tuyến khi bên gọi
	// không nói rõ vùng, và §7 quy tắc 7 nói rằng không có vùng nào khác được phép xuất hiện ở đây.
	RegionCode  string
	Log         *slog.Logger
}

// ReadinessProbe là những gì /readyz phải kiểm: cơ sở dữ liệu, Kafka và identity-service (§3.15).
// Interface để cmd/routingd quyết định cách kiểm, còn tầng HTTP chỉ lo mã trạng thái.
type ReadinessProbe interface {
	Check(ctx context.Context) error
}

// Server gói mux và các phụ thuộc.
type Server struct {
	deps Deps
	mux  *http.ServeMux
	keys *idempotencyCache
}

// New dựng server và gắn tất cả tuyến. Dùng ServeMux của thư viện chuẩn Go 1.22 với mẫu đường
// dẫn có biến — không cần router ngoài cho sáu endpoint.
func New(d Deps) *Server {
	s := &Server{deps: d, mux: http.NewServeMux(), keys: newIdempotencyCache()}

	// Bốn endpoint bắt buộc, đặt ngoài chuỗi xác thực: probe của Kubernetes không mang token,
	// và /metrics được Prometheus quét trong mạng nội bộ.
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("GET /readyz", s.handleReadyz)
	s.mux.HandleFunc("GET /version", s.handleVersion)
	s.mux.Handle("GET /metrics", promhttp.Handler())

	protected := http.NewServeMux()
	protected.HandleFunc("POST /v1/routes/plan", s.handlePlan)
	protected.HandleFunc("POST /v1/routes/{route_id}/replan", s.handleReplan)
	protected.HandleFunc("GET /v1/routes/{route_id}", s.handleGetRoute)
	protected.HandleFunc("GET /v1/shipments/{shipment_id}/route", s.handleCurrentRoute)
	protected.HandleFunc("POST /v1/eta/batch", s.handleETABatch)
	protected.HandleFunc("GET /v1/crossings/recommend", s.handleRecommendCrossings)

	chain := withIdempotency(s.keys, d.Log)(protected)
	chain = withAuth(d.Introspect, d.Log)(chain)
	s.mux.Handle("/v1/", chain)

	return s
}

// Handler trả về handler đã bọc trace và access log. Hai lớp này nằm ngoài cùng vì cả probe
// lẫn endpoint nghiệp vụ đều cần chúng.
func (s *Server) Handler() http.Handler {
	return withTrace(withAccessLog(s.deps.Log)(s.mux))
}

// Sweep dọn cache khoá bất biến và danh bạ cơ sở. cmd/routingd gọi mỗi giờ.
func (s *Server) Sweep() {
	if n := s.keys.sweep(); n > 0 {
		s.deps.Log.Debug("dọn khoá idempotency quá hạn", "removed", n)
	}
}

// handleHealthz chỉ trả lời rằng tiến trình còn sống. Tuyệt đối không chạm cơ sở dữ liệu (§3.15):
// một Postgres chậm không được phép làm Kubernetes giết pod đang chạy tốt.
func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz kiểm cơ sở dữ liệu, Kafka và identity-service. Mô hình ETA cũ chỉ là cảnh báo:
// chạy với tiền nghiệm cũ vẫn tốt hơn rút pod khỏi service.
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	body := map[string]any{"status": "ready"}
	if s.deps.Model != nil {
		body["eta_model_age_s"] = int(s.deps.Model.Age().Seconds())
		body["eta_model_lanes"] = s.deps.Model.Size()
		if s.deps.Model.Stale() {
			body["warnings"] = []string{"mô hình ETA cũ hơn 72 giờ"}
		}
	}
	if err := s.deps.Ready.Check(ctx); err != nil {
		body["status"] = "not_ready"
		body["reason"] = err.Error()
		writeJSON(w, http.StatusServiceUnavailable, body)
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.deps.Build)
}

// decodeJSON đọc thân yêu cầu với giới hạn kích thước. Không có endpoint nào của
// routing-service nhận quá một mebibyte; POST /v1/eta/batch với 500 lô hàng vẫn dưới 40 KB.
func decodeJSON(r *http.Request, dst any) error {
	const maxBody = 1 << 20
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return badRequest("malformed_body", fmt.Sprintf("thân yêu cầu không đọc được: %v", err))
	}
	return nil
}
