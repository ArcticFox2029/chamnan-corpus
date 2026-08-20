// GET /v1/crossings/recommend — bảng xếp hạng cửa khẩu cho một cặp điểm đi/điểm đến. Người
// điều độ ở web console gọi endpoint này trước khi chốt tuyến bằng tay, và bộ lập tuyến dùng
// đúng cùng bộ chấm điểm ấy khi tự chọn, nên hai bên không bao giờ cho ra thứ tự khác nhau.

package httpapi

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/planner"
)

type crossingsResponse struct {
	Strategy string                    `json:"strategy"`
	Mode     string                    `json:"mode"`
	Items    []planner.CrossingOption  `json:"items"`
	// Cửa khẩu không tra được thuế vẫn nằm trong danh sách, chỉ là trục thuế bị bỏ qua. Cờ này
	// cho người điều độ biết vì sao hai cột thuế trống chứ không phải bằng 0.
	TariffLookupDegraded bool `json:"tariff_lookup_degraded"`
}

// handleRecommendCrossings đọc tham số truy vấn, tra mô tả hai cơ sở trong danh bạ rồi giao cho
// bộ xếp hạng. Nó không nhận toạ độ trực tiếp: cơ sở phải đã đi qua POST /v1/routes/plan ít
// nhất một lần, vì routing-service không có đường nào khác để biết một facility_id nằm ở đâu.
func (s *Server) handleRecommendCrossings(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	originID := q.Get("origin_facility_id")
	destinationID := q.Get("destination_facility_id")
	if originID == "" || destinationID == "" {
		writeError(w, r, s.deps.Log, badRequest("missing_endpoints",
			"cần cả origin_facility_id lẫn destination_facility_id",
			fieldFault{Path: "origin_facility_id", Reason: "bắt buộc"},
			fieldFault{Path: "destination_facility_id", Reason: "bắt buộc"}))
		return
	}

	origin, ok := s.deps.Directory.Lookup(r.Context(), originID)
	if !ok {
		writeError(w, r, s.deps.Log, planner.ErrFacilityUnknown)
		return
	}
	destination, ok := s.deps.Directory.Lookup(r.Context(), destinationID)
	if !ok {
		writeError(w, r, s.deps.Log, planner.ErrFacilityUnknown)
		return
	}

	strategy := domain.Strategy(orDefault(q.Get("strategy"), string(domain.StrategyCheapest)))
	if !domain.IsKnownStrategy(strategy) {
		writeError(w, r, s.deps.Log, badRequest("invalid_strategy",
			"strategy phải là một trong cheapest, fastest, lowest_carbon, customs_optimised, manual",
			fieldFault{Path: "strategy", Reason: "giá trị không nằm trong ràng buộc CHECK của routing.routes"}))
		return
	}
	mode := domain.Mode(orDefault(q.Get("mode"), string(domain.ModeRoad)))
	if !domain.IsKnownMode(mode) {
		writeError(w, r, s.deps.Log, badRequest("invalid_mode",
			"mode phải là road, rail, sea, air hoặc barge",
			fieldFault{Path: "mode", Reason: "giá trị không nằm trong ràng buộc CHECK của routing.route_legs"}))
		return
	}

	req := planner.CrossingRequest{
		Origin:      origin,
		Destination: destination,
		Mode:        mode,
		Strategy:    strategy,
		HSCode:      strings.TrimSpace(q.Get("hs_code")),
		Currency:    strings.ToUpper(q.Get("currency")),
		DepartAt:    parseTime(q.Get("depart_at")),
		Limit:       parseLimit(q.Get("limit")),
	}
	// Giá trị khai báo đi cùng đơn vị tiền nhỏ nhất và luôn phải có mã tiền tệ kèm theo
	// (§0.2, §7 quy tắc 4) — thiếu một trong hai thì bỏ qua cả trục thuế.
	if v := q.Get("declared_value_minor"); v != "" && req.Currency != "" {
		if parsed, err := strconv.ParseInt(v, 10, 64); err == nil {
			req.DeclaredValue = parsed
		}
	}
	if v := q.Get("gross_kg"); v != "" {
		if parsed, err := strconv.ParseInt(v, 10, 64); err == nil {
			req.GrossKg = parsed
		}
	}

	options, err := s.deps.Ranker.Rank(r.Context(), req)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}

	resp := crossingsResponse{Strategy: string(strategy), Mode: string(mode), Items: options}
	for _, o := range options {
		if o.TariffMissing {
			resp.TariffLookupDegraded = true
			break
		}
	}
	// Danh sách này không phân trang: nhiều nhất là mười lăm cửa khẩu cho một cặp quốc gia, và
	// §0.5 nói về danh sách có thể dài, không phải về mọi mảng JSON.
	writeJSON(w, http.StatusOK, resp)
}

func orDefault(v, fallback string) string {
	if strings.TrimSpace(v) == "" {
		return fallback
	}
	return v
}

func parseLimit(v string) int {
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0
	}
	if n > 200 {
		// Trần 200 của §0.5 áp cho mọi endpoint trả danh sách, kể cả endpoint không phân trang.
		return 200
	}
	return n
}

func parseTime(v string) time.Time {
	if v == "" {
		return time.Now().UTC()
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return time.Now().UTC()
	}
	return t.UTC()
}
