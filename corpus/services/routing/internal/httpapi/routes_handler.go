// Bốn endpoint quanh chính tuyến đường: lập tuyến, lập lại tuyến, đọc một tuyến theo rte_ id,
// và đọc tuyến đang hiệu lực của một lô hàng. fleet-service là bên gọi POST /v1/routes/plan
// nhiều nhất, và nó là bên duy nhất có sẵn mô tả cơ sở vì nó vừa gọi container-registry.

package httpapi

import (
	"net/http"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/ids"
	"github.com/orbitalfreight/platform/services/routing/internal/planner"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// facilityRef là mô tả cơ sở mà bên gọi phải gửi kèm. routing-service không gọi
// container-registry (§1.1), nên nếu thiếu khối này thì không có cách nào biết cơ sở nằm ở đâu.
type facilityRef struct {
	FacilityID  string  `json:"facility_id"`
	UNLOCODE    string  `json:"unlocode"`
	CountryCode string  `json:"country_code"`
	GeofenceID  string  `json:"geofence_id"`
	Lat         float64 `json:"lat,omitempty"`
	Lon         float64 `json:"lon,omitempty"`
}

type planRequest struct {
	ShipmentID       string      `json:"shipment_id"`
	Strategy         string      `json:"strategy"`
	Origin           facilityRef `json:"origin"`
	Destination      facilityRef `json:"destination"`
	AllowedModes     []string    `json:"allowed_modes"`
	EarliestDepartAt *time.Time  `json:"earliest_depart_at"`
	SLADeadlineAt    *time.Time  `json:"sla_deadline_at"`
	RegionCode       string      `json:"region_code"`
}

type replanRequest struct {
	ReasonCode       string     `json:"reason_code"`
	Strategy         string     `json:"strategy"`
	EarliestDepartAt *time.Time `json:"earliest_depart_at"`
}

// legView và routeView là hình dạng JSON trả ra. Tách khỏi domain.Route để đổi cột trong
// routing.route_legs không tự động đổi hợp đồng API.
type legView struct {
	LegID           string     `json:"leg_id"`
	SeqNo           int16      `json:"seq_no"`
	Mode            string     `json:"mode"`
	FromFacilityID  string     `json:"from_facility_id"`
	ToFacilityID    string     `json:"to_facility_id"`
	CrossingID      *string    `json:"crossing_id"`
	PlannedDepartAt time.Time  `json:"planned_depart_at"`
	PlannedArriveAt time.Time  `json:"planned_arrive_at"`
	ActualDepartAt  *time.Time `json:"actual_depart_at"`
	ActualArriveAt  *time.Time `json:"actual_arrive_at"`
	DistanceM       int64      `json:"distance_m"`
	CarrierID       *string    `json:"carrier_id"`
}

type routeView struct {
	RouteID        string    `json:"route_id"`
	ShipmentID     string    `json:"shipment_id"`
	Version        int       `json:"version"`
	IsCurrent      bool      `json:"is_current"`
	Strategy       string    `json:"strategy"`
	PlannedBy      string    `json:"planned_by"`
	TotalDistanceM int64     `json:"total_distance_m"`
	TotalDurationS int32     `json:"total_duration_s"`
	ComputedAt     time.Time `json:"computed_at"`
	Legs           []legView `json:"legs"`
}

func toRouteView(r *domain.Route) routeView {
	v := routeView{
		RouteID:        r.RouteID,
		ShipmentID:     r.ShipmentID,
		Version:        r.Version,
		IsCurrent:      r.IsCurrent,
		Strategy:       string(r.Strategy),
		PlannedBy:      r.PlannedBy,
		TotalDistanceM: r.TotalDistanceM,
		TotalDurationS: r.TotalDurationS,
		ComputedAt:     r.ComputedAt,
		Legs:           make([]legView, 0, len(r.Legs)),
	}
	for _, l := range r.Legs {
		v.Legs = append(v.Legs, legView{
			LegID: l.LegID, SeqNo: l.SeqNo, Mode: string(l.Mode),
			FromFacilityID: l.FromFacilityID, ToFacilityID: l.ToFacilityID, CrossingID: l.CrossingID,
			PlannedDepartAt: l.PlannedDepartAt, PlannedArriveAt: l.PlannedArriveAt,
			ActualDepartAt: l.ActualDepartAt, ActualArriveAt: l.ActualArriveAt,
			DistanceM: l.DistanceM, CarrierID: l.CarrierID,
		})
	}
	return v
}

// handlePlan phục vụ POST /v1/routes/plan. Trả 200 thay vì 201 khi lô hàng đã có tuyến: lập
// tuyến là thao tác bất biến, và bên gọi thử lại sau timeout phải nhận đúng tuyến cũ.
func (s *Server) handlePlan(w http.ResponseWriter, r *http.Request) {
	var req planRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	if err := ids.Validate(req.ShipmentID, "shp_"); err != nil {
		writeError(w, r, s.deps.Log, badRequest("invalid_shipment_id", err.Error(),
			fieldFault{Path: "shipment_id", Reason: "phải là định danh shp_"}))
		return
	}
	if faults := validateFacilityRefs(req); len(faults) > 0 {
		writeError(w, r, s.deps.Log, badRequest("facility_descriptor_required",
			"origin và destination phải có facility_id cùng toạ độ hoặc geofence_id", faults...))
		return
	}

	claims := claimsFrom(r.Context())
	for _, f := range []facilityRef{req.Origin, req.Destination} {
		if err := s.deps.Directory.Remember(r.Context(), toFacility(f)); err != nil {
			writeError(w, r, s.deps.Log, err)
			return
		}
	}

	depart := time.Now().UTC()
	if req.EarliestDepartAt != nil {
		depart = req.EarliestDepartAt.UTC()
	}
	region := req.RegionCode
	if region == "" {
		region = s.deps.RegionCode
	}

	intent := domain.PlanIntent{
		ShipmentID:            req.ShipmentID,
		TenantID:              claims.Tid,
		RegionCode:            region,
		OriginFacilityID:      req.Origin.FacilityID,
		DestinationFacilityID: req.Destination.FacilityID,
		Strategy:              domain.Strategy(req.Strategy),
		SLADeadlineAt:         req.SLADeadlineAt,
		EarliestDepartAt:      depart,
		AllowedModes:          toModes(req.AllowedModes),
		RequestedBy:           claims.Subject,
		TraceID:               traceIDFrom(r.Context()),
	}

	route, err := s.deps.Planner.Plan(r.Context(), intent)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	status := http.StatusCreated
	if route.Version > 1 || !route.ComputedAt.After(time.Now().Add(-time.Minute)) {
		status = http.StatusOK
	}
	writeJSON(w, status, toRouteView(route))
}

// handleReplan phục vụ POST /v1/routes/{route_id}/replan. Phiên bản mới lật cờ is_current và
// đẩy route.replanned vào platform.outbox_messages trong cùng giao dịch; fleet-service tiêu thụ
// sự kiện đó để giải phóng những phân công có leg_id không còn tồn tại.
func (s *Server) handleReplan(w http.ResponseWriter, r *http.Request) {
	routeID := r.PathValue("route_id")
	if err := ids.Validate(routeID, ids.PrefixRoute); err != nil {
		writeError(w, r, s.deps.Log, badRequest("invalid_route_id", err.Error()))
		return
	}
	var req replanRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	if req.ReasonCode == "" {
		writeError(w, r, s.deps.Log, badRequest("reason_code_required",
			"route.replanned mang reason_code ra ngoài, nên nó không được để trống",
			fieldFault{Path: "reason_code", Reason: "bắt buộc"}))
		return
	}

	current, err := s.deps.Routes.RouteByID(r.Context(), routeID)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	if current == nil {
		writeError(w, r, s.deps.Log, planner.ErrRouteNotFound)
		return
	}

	strategy := current.Strategy
	if req.Strategy != "" {
		strategy = domain.Strategy(req.Strategy)
	}
	depart := time.Now().UTC()
	if req.EarliestDepartAt != nil {
		depart = req.EarliestDepartAt.UTC()
	}

	claims := claimsFrom(r.Context())
	next, err := s.deps.Planner.Replan(r.Context(), current.ShipmentID, req.ReasonCode, domain.PlanIntent{
		ShipmentID:            current.ShipmentID,
		TenantID:              claims.Tid,
		RegionCode:            s.deps.RegionCode,
		OriginFacilityID:      firstLegOrigin(current),
		DestinationFacilityID: lastLegDestination(current),
		Strategy:              strategy,
		EarliestDepartAt:      depart,
		RequestedBy:           claims.Subject,
		TraceID:               traceIDFrom(r.Context()),
	})
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	writeJSON(w, http.StatusOK, toRouteView(next))
}

// handleGetRoute phục vụ GET /v1/routes/{route_id}, kể cả với phiên bản đã bị thay thế.
func (s *Server) handleGetRoute(w http.ResponseWriter, r *http.Request) {
	routeID := r.PathValue("route_id")
	if err := ids.Validate(routeID, ids.PrefixRoute); err != nil {
		writeError(w, r, s.deps.Log, badRequest("invalid_route_id", err.Error()))
		return
	}
	route, err := s.deps.Routes.RouteByID(r.Context(), routeID)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	if route == nil {
		writeError(w, r, s.deps.Log, planner.ErrRouteNotFound)
		return
	}
	writeJSON(w, http.StatusOK, toRouteView(route))
}

// handleCurrentRoute phục vụ GET /v1/shipments/{shipment_id}/route — chỉ phiên bản đang hiệu lực.
func (s *Server) handleCurrentRoute(w http.ResponseWriter, r *http.Request) {
	shipmentID := r.PathValue("shipment_id")
	if err := ids.Validate(shipmentID, "shp_"); err != nil {
		writeError(w, r, s.deps.Log, badRequest("invalid_shipment_id", err.Error()))
		return
	}
	route, err := s.deps.Routes.CurrentRoute(r.Context(), shipmentID)
	if err != nil {
		writeError(w, r, s.deps.Log, err)
		return
	}
	if route == nil {
		writeError(w, r, s.deps.Log, planner.ErrRouteNotFound)
		return
	}
	writeJSON(w, http.StatusOK, toRouteView(route))
}

func validateFacilityRefs(req planRequest) []fieldFault {
	var faults []fieldFault
	for path, f := range map[string]facilityRef{"origin": req.Origin, "destination": req.Destination} {
		switch {
		case f.FacilityID == "":
			faults = append(faults, fieldFault{Path: path + ".facility_id", Reason: "bắt buộc"})
		case f.GeofenceID == "" && f.Lat == 0 && f.Lon == 0:
			faults = append(faults, fieldFault{
				Path:   path + ".geofence_id",
				Reason: "bắt buộc khi không có lat/lon; routing-service không hỏi container-registry",
			})
		}
	}
	return faults
}

func toFacility(f facilityRef) planner.Facility {
	return planner.Facility{
		FacilityID:  f.FacilityID,
		UNLOCODE:    f.UNLOCODE,
		CountryCode: f.CountryCode,
		GeofenceID:  f.GeofenceID,
		Centroid:    upstream.Point{Lat: f.Lat, Lon: f.Lon},
	}
}

func toModes(in []string) []domain.Mode {
	out := make([]domain.Mode, 0, len(in))
	for _, m := range in {
		out = append(out, domain.Mode(m))
	}
	return out
}

// firstLegOrigin và lastLegDestination lấy lại hai đầu tuyến từ chính các chặng, vì
// routing.routes không lưu điểm đi và điểm đến — chúng nằm ở freight.shipments, thuộc
// container-registry.
func firstLegOrigin(r *domain.Route) string {
	if len(r.Legs) == 0 {
		return ""
	}
	return r.Legs[0].FromFacilityID
}

func lastLegDestination(r *domain.Route) string {
	if len(r.Legs) == 0 {
		return ""
	}
	return r.Legs[len(r.Legs)-1].ToFacilityID
}
