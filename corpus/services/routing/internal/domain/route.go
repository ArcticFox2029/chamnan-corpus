// Package domain giữ các kiểu dữ liệu lõi của routing-service: tuyến đường, chặng, chiến lược
// lập tuyến và các bảng giá trị hợp lệ được chép nguyên văn từ ràng buộc CHECK của
// routing.routes và routing.route_legs. Package này cố tình không biết gì về HTTP, Postgres hay
// Kafka — mọi tầng khác phụ thuộc vào nó, còn nó không phụ thuộc ngược lại tầng nào cả.
package domain

import (
	"fmt"
	"time"
)

// Strategy là cột routing.routes.strategy. Danh sách này đóng: thêm một giá trị ở đây mà quên
// sửa ràng buộc CHECK trong db/ thì INSERT sẽ hỏng ở môi trường staging chứ không phải ở CI.
type Strategy string

const (
	StrategyCheapest         Strategy = "cheapest"
	StrategyFastest          Strategy = "fastest"
	StrategyLowestCarbon     Strategy = "lowest_carbon"
	StrategyCustomsOptimised Strategy = "customs_optimised"
	StrategyManual           Strategy = "manual"
)

// Mode là cột routing.route_legs.mode.
type Mode string

const (
	ModeRoad  Mode = "road"
	ModeRail  Mode = "rail"
	ModeSea   Mode = "sea"
	ModeAir   Mode = "air"
	ModeBarge Mode = "barge"
)

// validStrategies và validModes là bảng tra cứu thay cho chuỗi switch: cả hai đều được dùng ở
// tầng HTTP (chặn dữ liệu bẩn từ web console) lẫn ở consumer Kafka (chặn dữ liệu bẩn từ replay).
var validStrategies = map[Strategy]struct{}{
	StrategyCheapest:         {},
	StrategyFastest:          {},
	StrategyLowestCarbon:     {},
	StrategyCustomsOptimised: {},
	StrategyManual:           {},
}

var validModes = map[Mode]struct{}{
	ModeRoad:  {},
	ModeRail:  {},
	ModeSea:   {},
	ModeAir:   {},
	ModeBarge: {},
}

// RegionCodes là danh sách đóng ở §0.6. Mã vùng quyết định nơi dữ liệu được phép nằm, nên
// một tuyến gắn latam-br không bao giờ được ghi, cache hay ghi log ở vùng khác (§7 quy tắc 7).
var RegionCodes = [...]string{
	"eu-west", "eu-central", "na-east", "na-west",
	"apac-sg", "apac-jp", "latam-br", "mea-ae",
}

// IsKnownRegion trả về true nếu code nằm trong §0.6.
func IsKnownRegion(code string) bool {
	for _, r := range RegionCodes {
		if r == code {
			return true
		}
	}
	return false
}

// IsKnownStrategy và IsKnownMode dùng cho kiểm tra đầu vào trước khi chạm tới cơ sở dữ liệu.
func IsKnownStrategy(s Strategy) bool { _, ok := validStrategies[s]; return ok }
func IsKnownMode(m Mode) bool         { _, ok := validModes[m]; return ok }

// Route ánh xạ một dòng routing.routes. version tăng đơn điệu theo shipment_id; chỉ đúng một
// phiên bản được giữ is_current, và chỉ mục duy nhất routes_one_current_per_shipment mới là
// trọng tài thật sự của điều đó, không phải code này.
type Route struct {
	RouteID        string
	ShipmentID     string // logical FK sang freight.shipments, do container-registry sở hữu
	TenantID       string
	Version        int
	IsCurrent      bool
	PlannedBy      string // usr_… khi người điều độ bấm nút, "svc:routing-service" khi tự động
	Strategy       Strategy
	TotalDistanceM int64
	TotalDurationS int32
	RegionCode     string
	ComputedAt     time.Time
	SupersededAt   *time.Time
	Legs           []Leg
}

// Leg ánh xạ một dòng routing.route_legs. CrossingID là khoá ngoại thật sự trỏ sang
// geo.border_crossings — một trong bốn khoá ngoại liên schema được §2 cho phép — nên một id
// cửa khẩu bịa ra sẽ bị chính cơ sở dữ liệu chặn ở INSERT.
type Leg struct {
	LegID           string
	RouteID         string
	SeqNo           int16
	Mode            Mode
	FromFacilityID  string // logical FK sang freight.facilities
	ToFacilityID    string
	CrossingID      *string // NULL với chặng nội địa
	PlannedDepartAt time.Time
	PlannedArriveAt time.Time
	ActualDepartAt  *time.Time
	ActualArriveAt  *time.Time
	DistanceM       int64
	CarrierID       *string // được điền khi fleet.assignment.created về tới nơi
}

// PlanIntent là đầu vào đã chuẩn hoá của cả POST /v1/routes/plan lẫn consumer shipment.created.
// Hai đường vào khác nhau nhưng phải cho ra cùng một tuyến, nên chúng hội tụ về kiểu này.
type PlanIntent struct {
	ShipmentID            string
	TenantID              string
	RegionCode            string
	OriginFacilityID      string
	DestinationFacilityID string
	Strategy              Strategy
	SLADeadlineAt         *time.Time
	EarliestDepartAt      time.Time
	AllowedModes          []Mode
	RequestedBy           string
	TraceID               string
}

// Validate kiểm tra những gì kiểm tra được mà không cần gọi ra ngoài. Phần còn lại —
// cơ sở có tồn tại không, cửa khẩu có mở không — phải hỏi geo-service và customs-service.
func (p PlanIntent) Validate() error {
	switch {
	case p.ShipmentID == "":
		return fmt.Errorf("shipment_id là bắt buộc")
	case p.OriginFacilityID == p.DestinationFacilityID:
		// Cùng ràng buộc shipments_endpoints_differ mà container-registry đã áp ở freight.shipments;
		// lặp lại ở đây để không tốn một vòng gọi cơ sở dữ liệu cho một lô hàng chắc chắn hỏng.
		return fmt.Errorf("điểm đi và điểm đến trùng nhau: %s", p.OriginFacilityID)
	case !IsKnownStrategy(p.Strategy):
		return fmt.Errorf("chiến lược không hợp lệ: %q", p.Strategy)
	case !IsKnownRegion(p.RegionCode):
		return fmt.Errorf("mã vùng không nằm trong §0.6: %q", p.RegionCode)
	}
	for _, m := range p.AllowedModes {
		if !IsKnownMode(m) {
			return fmt.Errorf("phương thức vận chuyển không hợp lệ: %q", m)
		}
	}
	return nil
}

// Duration của một chặng theo kế hoạch. Ràng buộc legs_arrive_after_depart bảo đảm giá trị
// này luôn dương với dữ liệu đã nằm trong bảng.
func (l Leg) Duration() time.Duration {
	return l.PlannedArriveAt.Sub(l.PlannedDepartAt)
}

// Recompute cộng lại total_distance_m và total_duration_s từ các chặng. Gọi trước mỗi lần ghi:
// hai cột tổng là dữ liệu suy diễn, và analytics-pipeline đọc chúng qua vai trò of_analytics_ro
// nên sai lệch sẽ đi thẳng vào analytics.mv_lane_performance_daily.
func (r *Route) Recompute() {
	var dist int64
	var first, last time.Time
	for i, l := range r.Legs {
		dist += l.DistanceM
		if i == 0 || l.PlannedDepartAt.Before(first) {
			first = l.PlannedDepartAt
		}
		if l.PlannedArriveAt.After(last) {
			last = l.PlannedArriveAt
		}
	}
	r.TotalDistanceM = dist
	r.TotalDurationS = int32(last.Sub(first).Seconds())
}

// ArrivalAt trả về giờ đến dự kiến ở cuối tuyến, tức thứ mà POST /v1/eta/batch trả cho
// web console và cho driver-ios.
func (r Route) ArrivalAt() (time.Time, bool) {
	if len(r.Legs) == 0 {
		return time.Time{}, false
	}
	return r.Legs[len(r.Legs)-1].PlannedArriveAt, true
}

// BreachesSLA so giờ đến cuối cùng với freight.shipments.sla_deadline_at. Chính cờ này là thứ
// khiến planner chọn replan thay vì để nguyên tuyến cũ.
func (r Route) BreachesSLA(deadline *time.Time) bool {
	if deadline == nil {
		return false
	}
	arrive, ok := r.ArrivalAt()
	return ok && arrive.After(*deadline)
}
