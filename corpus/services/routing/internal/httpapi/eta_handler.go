// POST /v1/eta/batch — giờ đến dự kiến cho tối đa 500 lô hàng trong một lời gọi. Đây là
// endpoint bận nhất của routing-service: web console gọi nó mỗi khi làm mới bảng điều độ, và
// notification-service dựa vào chênh lệch giữa ETA và freight.shipments.sla_deadline_at để
// quyết định có gửi cảnh báo trễ hay không.

package httpapi

import (
	"net/http"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/eta"
	"github.com/orbitalfreight/platform/services/routing/internal/ids"
)

// maxBatch là giới hạn cứng ở §3.5. Vượt quá là 400 chứ không phải cắt bớt im lặng: bên gọi
// nhận đủ 500 dòng nhưng thiếu mất phần đuôi là kiểu lỗi không ai phát hiện ra.
const maxBatch = 500

type etaBatchRequest struct {
	ShipmentIDs []string   `json:"shipment_ids"`
	DepartAt    *time.Time `json:"depart_at"`
}

type etaLegView struct {
	LegID       string    `json:"leg_id"`
	SeqNo       int16     `json:"seq_no"`
	Mode        string    `json:"mode"`
	ArriveAt    time.Time `json:"arrive_at"`
	P95ArriveAt time.Time `json:"p95_arrive_at"`
	DwellS      int32     `json:"dwell_s"`
	Source      string    `json:"source"`
	Confidence  float64   `json:"confidence"`
}

type etaShipmentView struct {
	ShipmentID     string       `json:"shipment_id"`
	RouteID        string       `json:"route_id"`
	Version        int          `json:"version"`
	FinalArriveAt  time.Time    `json:"final_arrive_at"`
	Legs           []etaLegView `json:"legs"`
	ModelStale     bool         `json:"model_stale"`
}

type etaBatchResponse struct {
	Items   []etaShipmentView `json:"items"`
	Missing []string          `json:"missing"`
}

// handleETABatch tra tuyến của tất cả lô hàng trong một truy vấn rồi ước lượng từng tuyến. Lô
// hàng chưa có tuyến đi vào mảng missing chứ không làm hỏng cả lời gọi — trong một bảng điều độ
// có vài lô hàng vừa tạo là chuyện bình thường.
func (s *Server) handleETABatch(w http.ResponseWriter, r *http.Request) {
	var req etaBatchRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	switch {
	case len(req.ShipmentIDs) == 0:
		writeError(w, r, s.deps.Log, badRequest("empty_batch", "shipment_ids không được rỗng",
			fieldFault{Path: "shipment_ids", Reason: "bắt buộc"}))
		return
	case len(req.ShipmentIDs) > maxBatch:
		writeError(w, r, s.deps.Log, badRequest("batch_too_large",
			"tối đa 500 lô hàng cho mỗi lời gọi",
			fieldFault{Path: "shipment_ids", Reason: "vượt quá 500"}))
		return
	}
	for i, id := range req.ShipmentIDs {
		if err := ids.Validate(id, "shp_"); err != nil {
			writeError(w, r, s.deps.Log, badRequest("invalid_shipment_id", err.Error(),
				fieldFault{Path: "shipment_ids[" + itoa(i) + "]", Reason: "phải là định danh shp_"}))
			return
		}
	}

	routes, err := s.deps.Routes.LegsForShipments(r.Context(), req.ShipmentIDs)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}

	depart := time.Time{}
	if req.DepartAt != nil {
		depart = req.DepartAt.UTC()
	}

	resp := etaBatchResponse{Items: make([]etaShipmentView, 0, len(routes))}
	for _, shipmentID := range req.ShipmentIDs {
		route, ok := routes[shipmentID]
		if !ok {
			resp.Missing = append(resp.Missing, shipmentID)
			continue
		}
		resp.Items = append(resp.Items, s.estimateOne(r, route, depart))
	}
	writeJSON(w, http.StatusOK, resp)
}

// estimateOne chạy bộ ước lượng cho một tuyến. Bảng ánh xạ facility_id → UN/LOCODE lấy từ danh
// bạ trong bộ nhớ; cơ sở nào chưa từng đi qua đây thì tiền nghiệm lịch sử không dùng được và
// ước lượng rơi về thuần hình học — trường source trong kết quả nói rõ điều đó.
func (s *Server) estimateOne(r *http.Request, route *domain.Route, depart time.Time) etaShipmentView {
	unlocodes := make(map[string]string, len(route.Legs)+1)
	geometric := make(map[string]int32, len(route.Legs))
	for _, l := range route.Legs {
		if f, ok := s.deps.Directory.Lookup(r.Context(), l.FromFacilityID); ok {
			unlocodes[l.FromFacilityID] = f.UNLOCODE
		}
		if f, ok := s.deps.Directory.Lookup(r.Context(), l.ToFacilityID); ok {
			unlocodes[l.ToFacilityID] = f.UNLOCODE
		}
		// Thời gian chạy hình học đã nằm sẵn trong kế hoạch; không gọi lại
		// geo.v1.GeoService/DistanceMatrix ở đây, vì 500 lô hàng sẽ thành hàng nghìn lời gọi
		// cho một endpoint chỉ để hiển thị.
		geometric[l.LegID] = int32(l.Duration().Seconds())
	}

	estimates := s.deps.Estimator.EstimateRoute(r.Context(), *route, eta.RouteInput{
		FacilityUNLOCODE: unlocodes,
		GeometricPerLeg:  geometric,
		DepartAt:         depart,
	})

	view := etaShipmentView{
		ShipmentID: route.ShipmentID,
		RouteID:    route.RouteID,
		Version:    route.Version,
		Legs:       make([]etaLegView, 0, len(estimates)),
	}
	if s.deps.Model != nil {
		view.ModelStale = s.deps.Model.Stale()
	}
	for i, est := range estimates {
		view.Legs = append(view.Legs, etaLegView{
			LegID:       est.LegID,
			SeqNo:       route.Legs[i].SeqNo,
			Mode:        string(route.Legs[i].Mode),
			ArriveAt:    est.ArriveAt,
			P95ArriveAt: est.P95ArriveAt,
			DwellS:      est.DwellS,
			Source:      est.Source,
			Confidence:  est.Confidence,
		})
		view.FinalArriveAt = est.ArriveAt
	}
	return view
}

// itoa nhỏ gọn cho thông báo lỗi; strconv chỉ dùng cho một chỗ này thì không đáng import.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [8]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
