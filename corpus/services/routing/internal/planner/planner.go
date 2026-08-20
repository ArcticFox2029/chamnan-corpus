// Package planner là ruột của routing-service: nó biến một lô hàng thành một chuỗi chặng có
// cửa khẩu và giờ giấc, rồi lập lại chuỗi đó khi thực tế lệch khỏi kế hoạch. Mọi thứ ở ngoài —
// geo-service, customs-service, Postgres — đều vào qua interface khai báo ngay trong package
// này, nên bộ lập tuyến kiểm thử được mà không cần dựng cả nền tảng.
package planner

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/corridor"
	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/eta"
	"github.com/orbitalfreight/platform/services/routing/internal/ids"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// Store là phần lưu trữ mà bộ lập tuyến cần. Hiện thực nằm ở internal/store và ghi vào
// routing.routes, routing.route_legs cùng platform.outbox_messages trong **một** giao dịch,
// đúng §7 quy tắc 3 — không có đường nào vừa ghi Postgres vừa đẩy Kafka riêng lẻ.
type Store interface {
	CurrentRoute(ctx context.Context, shipmentID string) (*domain.Route, error)
	RouteByID(ctx context.Context, routeID string) (*domain.Route, error)
	InsertFirstVersion(ctx context.Context, r *domain.Route) error
	SupersedeAndInsert(ctx context.Context, next *domain.Route, ev domain.RouteReplanned) error
	CloseRoute(ctx context.Context, shipmentID, reason string) error
}

// Lỗi mà tầng HTTP ánh xạ thẳng sang mã trong phong bì lỗi §0.4.
var (
	ErrRouteNotFound   = errors.New("không tìm thấy tuyến")
	ErrCooldownActive  = errors.New("chưa hết thời gian chờ giữa hai lần lập lại tuyến")
	ErrTooManyLegs     = errors.New("số chặng vượt OF_ROUTING_MAX_LEGS")
	ErrFacilityUnknown = errors.New("chưa biết mô tả của cơ sở")
	ErrNoCorridor      = errors.New("không có hành lang nối hai quốc gia")
)

// Options gom các tham số vận hành lấy từ môi trường.
type Options struct {
	MaxLegs        int           // OF_ROUTING_MAX_LEGS
	ReplanCooldown time.Duration // OF_ROUTING_REPLAN_COOLDOWN_SECONDS
	SolverThreads  int           // OF_ROUTING_SOLVER_THREADS
	RegionCode     string        // OF_REGION_CODE
}

// Planner giữ mọi phụ thuộc và không giữ trạng thái nào của riêng một yêu cầu, nên dùng chung
// được cho tất cả goroutine xử lý HTTP lẫn goroutine đọc Kafka.
type Planner struct {
	store       Store
	ranker      *CrossingRanker
	directory   FacilityDirectory
	geo         upstream.Geo
	estimator   eta.Estimator
	opts        Options
}

// New dựng Planner.
func New(store Store, ranker *CrossingRanker, dir FacilityDirectory, geo upstream.Geo, est eta.Estimator, opts Options) *Planner {
	return &Planner{store: store, ranker: ranker, directory: dir, geo: geo, estimator: est, opts: opts}
}

// Plan lập tuyến phiên bản 1 cho một lô hàng. Trả về tuyến đã có sẵn nếu lô hàng đã được lập
// tuyến: cả POST /v1/routes/plan lẫn consumer shipment.created đều gọi vào đây, và §4.19 quy
// tắc 1 buộc nhánh sự kiện phải bất biến theo event_id — cách rẻ nhất để bất biến là làm cho
// chính thao tác này bất biến.
func (p *Planner) Plan(ctx context.Context, intent domain.PlanIntent) (*domain.Route, error) {
	if err := intent.Validate(); err != nil {
		return nil, err
	}
	if existing, err := p.store.CurrentRoute(ctx, intent.ShipmentID); err != nil {
		return nil, err
	} else if existing != nil {
		return existing, nil
	}

	route, err := p.build(ctx, intent, nil)
	if err != nil {
		return nil, err
	}
	route.Version = 1
	route.IsCurrent = true

	if err := p.store.InsertFirstVersion(ctx, route); err != nil {
		return nil, err
	}
	return route, nil
}

// Replan sinh phiên bản mới cho một lô hàng đang chạy. Ba cửa chặn theo đúng thứ tự: thời gian
// chờ, mức cải thiện tối thiểu, rồi mới tới việc ghi. Bỏ cửa thứ nhất thì một tuyến chập chờn
// sinh hàng chục phiên bản mỗi phút; bỏ cửa thứ hai thì fleet-service phải huỷ phân công theo
// từng lần vì nó tiêu thụ route.replanned.
func (p *Planner) Replan(ctx context.Context, shipmentID, reasonCode string, intent domain.PlanIntent) (*domain.Route, error) {
	current, err := p.store.CurrentRoute(ctx, shipmentID)
	if err != nil {
		return nil, err
	}
	if current == nil {
		return nil, fmt.Errorf("%w: lô hàng %s chưa có tuyến nào", ErrRouteNotFound, shipmentID)
	}
	if remaining := CooldownRemaining(current.ComputedAt, p.opts.ReplanCooldown); remaining > 0 {
		return nil, fmt.Errorf("%w: còn %s", ErrCooldownActive, remaining.Truncate(time.Second))
	}

	// Những chặng đã có xe được giữ nguyên nếu còn hợp lệ: huỷ một phân công đang chạy tốn kém
	// hơn nhiều so với việc đi thêm vài chục cây số.
	pinned := pinnedLegs(current)

	next, err := p.build(ctx, intent, pinned)
	if err != nil {
		return nil, err
	}
	next.Version = current.Version + 1
	next.IsCurrent = true

	if reasonCode != "manual" && !WorthReplanning(routeScore(*current), routeScore(*next)) {
		// Không đủ tốt hơn thì giữ nguyên và nói thẳng ra; tầng HTTP trả 200 với tuyến cũ.
		return current, nil
	}

	ev := domain.RouteReplanned{
		RouteID:         next.RouteID,
		ShipmentID:      shipmentID,
		PreviousVersion: current.Version,
		Version:         next.Version,
		Strategy:        next.Strategy,
		ReasonCode:      reasonCode,
		TotalDistanceM:  next.TotalDistanceM,
		TotalDurationS:  next.TotalDurationS,
		LegsChanged:     domain.DiffLegs(current.Legs, next.Legs),
		ComputedAt:      next.ComputedAt,
	}
	if err := ev.Validate(); err != nil {
		return nil, err
	}
	if err := p.store.SupersedeAndInsert(ctx, next, ev); err != nil {
		return nil, err
	}
	return next, nil
}

// build dựng chuỗi chặng nhưng không ghi gì cả. Tách khỏi Plan/Replan để hai đường đó chỉ còn
// lo phần phiên bản và phần giao dịch.
func (p *Planner) build(ctx context.Context, intent domain.PlanIntent, pinned map[string]domain.Leg) (*domain.Route, error) {
	origin, ok := p.directory.Lookup(ctx, intent.OriginFacilityID)
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrFacilityUnknown, intent.OriginFacilityID)
	}
	destination, ok := p.directory.Lookup(ctx, intent.DestinationFacilityID)
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrFacilityUnknown, intent.DestinationFacilityID)
	}

	mode := primaryMode(intent.AllowedModes)
	route := &domain.Route{
		RouteID:    ids.NewRoute(),
		ShipmentID: intent.ShipmentID,
		TenantID:   intent.TenantID,
		PlannedBy:  intent.RequestedBy,
		Strategy:   intent.Strategy,
		RegionCode: intent.RegionCode,
		ComputedAt: time.Now().UTC(),
	}

	waypoints, err := p.waypoints(ctx, intent, origin, destination, mode)
	if err != nil {
		return nil, err
	}
	if len(waypoints)-1 > p.opts.MaxLegs {
		return nil, fmt.Errorf("%w: cần %d chặng, tối đa %d", ErrTooManyLegs, len(waypoints)-1, p.opts.MaxLegs)
	}

	depart := intent.EarliestDepartAt
	if depart.IsZero() {
		depart = time.Now().UTC()
	}

	for i := 0; i < len(waypoints)-1; i++ {
		from, to := waypoints[i], waypoints[i+1]
		matrix, err := p.geo.DistanceMatrix(ctx,
			[]upstream.Point{from.point}, []upstream.Point{to.point}, string(mode))
		if err != nil {
			return nil, err
		}

		leg := domain.Leg{
			LegID:           ids.NewLeg(),
			RouteID:         route.RouteID,
			SeqNo:           int16(i + 1),
			Mode:            mode,
			FromFacilityID:  from.facilityID,
			ToFacilityID:    to.facilityID,
			CrossingID:      to.crossingID,
			DistanceM:       matrix.DistanceM[0][0],
			PlannedDepartAt: depart,
		}

		// Chặng nào đang có xe thì giữ nguyên id để fleet-service không phải giải phóng phân công.
		if prev, ok := pinned[legKey(leg)]; ok {
			leg.LegID = prev.LegID
			leg.CarrierID = prev.CarrierID
		}

		est := p.estimator.EstimateLeg(ctx, eta.LegInput{
			Leg:                 leg,
			OriginUNLOCODE:      from.unlocode,
			DestinationUNLOCODE: to.unlocode,
			GeometricDurationS:  matrix.DurationS[0][0],
			DepartAt:            depart,
			// Thời gian chờ tính vào chặng ĐẾN cửa khẩu, không phải chặng rời khỏi nó: xe đứng ở
			// bãi kiểm hoá trước khi qua vạch, nên giờ đến của chặng này mới là thứ bị đẩy lùi.
			Crossing:            to.crossing,
		})
		leg.PlannedArriveAt = est.ArriveAt
		depart = est.ArriveAt

		route.Legs = append(route.Legs, leg)
	}

	route.Recompute()
	return route, nil
}

// waypoint là một điểm trên tuyến: hoặc một cơ sở, hoặc một cửa khẩu.
type waypoint struct {
	facilityID string
	unlocode   string
	point      upstream.Point
	crossingID *string
	crossing   *corridor.Crossing
}

// waypoints dựng chuỗi điểm từ điểm đi tới điểm đến. Cùng quốc gia thì đúng hai điểm; khác
// quốc gia thì chèn cửa khẩu tốt nhất vào giữa; không có cửa khẩu trực tiếp thì thử một nước
// trung chuyển từ danh mục hành lang trước khi bỏ cuộc.
func (p *Planner) waypoints(ctx context.Context, intent domain.PlanIntent, origin, destination Facility, mode domain.Mode) ([]waypoint, error) {
	start := waypoint{facilityID: origin.FacilityID, unlocode: origin.UNLOCODE, point: origin.Centroid}
	end := waypoint{facilityID: destination.FacilityID, unlocode: destination.UNLOCODE, point: destination.Centroid}

	if origin.CountryCode == destination.CountryCode {
		return []waypoint{start, end}, nil
	}

	req := CrossingRequest{
		Origin:      origin,
		Destination: destination,
		Mode:        mode,
		Strategy:    intent.Strategy,
		DepartAt:    intent.EarliestDepartAt,
		Limit:       1,
	}
	options, err := p.ranker.Rank(ctx, req)
	if err == nil && len(options) > 0 {
		return []waypoint{start, crossingWaypoint(options[0]), end}, nil
	}

	for _, mid := range corridor.Transits(origin.CountryCode, destination.CountryCode) {
		first := corridor.Candidates(origin.CountryCode, mid, string(mode))
		second := corridor.Candidates(mid, destination.CountryCode, string(mode))
		if len(first) == 0 || len(second) == 0 {
			continue
		}
		return []waypoint{
			start,
			crossingWaypointFrom(first[0]),
			crossingWaypointFrom(second[0]),
			end,
		}, nil
	}
	return nil, fmt.Errorf("%w: %s→%s", ErrNoCorridor, origin.CountryCode, destination.CountryCode)
}

func crossingWaypoint(o CrossingOption) waypoint {
	c := o.Crossing
	return crossingWaypointFrom(c)
}

func crossingWaypointFrom(c corridor.Crossing) waypoint {
	id := c.CrossingID
	cc := c
	return waypoint{
		// Cửa khẩu không phải là một facility, nên facility_id mượn chính hàng rào của nó —
		// routing.route_legs.from_facility_id là logical FK, không phải khoá ngoại thật, và
		// container-registry không bao giờ đọc ngược lại cột này.
		facilityID: c.GeofenceID,
		unlocode:   c.UNLOCODE,
		crossingID: &id,
		crossing:   &cc,
	}
}

// pinnedLegs lập chỉ mục những chặng đã có carrier_id, tức đã được fleet-service phân công qua
// fleet.v1.FleetService/Assign.
func pinnedLegs(r *domain.Route) map[string]domain.Leg {
	out := map[string]domain.Leg{}
	for _, l := range r.Legs {
		if l.CarrierID != nil {
			out[legKey(l)] = l
		}
	}
	return out
}

// legKey nhận diện một chặng theo hình dạng chứ không theo id: cùng điểm đầu, điểm cuối và
// phương thức thì coi là cùng một chặng qua các lần lập lại tuyến.
func legKey(l domain.Leg) string {
	return l.FromFacilityID + ">" + l.ToFacilityID + ">" + string(l.Mode)
}

// primaryMode chọn phương thức chính. Danh sách rỗng nghĩa là đường bộ: phần lớn lô hàng
// xuyên biên giới của chúng ta là đường bộ, và mọi cửa khẩu trong danh mục đều nhận đường bộ
// hoặc đường sắt.
func primaryMode(allowed []domain.Mode) domain.Mode {
	if len(allowed) == 0 {
		return domain.ModeRoad
	}
	return allowed[0]
}

// routeScore quy một tuyến đã dựng về một con số để so hai phiên bản với nhau. Dùng đúng
// bảng trọng số của chiến lược đang áp dụng, nên "tốt hơn" luôn có nghĩa theo chiến lược đó
// chứ không theo cảm tính của người viết code.
func routeScore(r domain.Route) float64 {
	c := candidateScore{DistanceM: r.TotalDistanceM, DurationS: int64(r.TotalDurationS)}
	for _, l := range r.Legs {
		c.CarbonG += CarbonForLeg(l.Mode, l.DistanceM, 0)
	}
	b := boundsOf([]candidateScore{c})
	return Score(r.Strategy, c, b)
}
