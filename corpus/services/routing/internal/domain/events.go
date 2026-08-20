// Phong bì sự kiện và các payload mà routing-service đọc hoặc phát ra. Ba sự kiện được tiêu thụ
// từ of.freight.v1 (shipment.created, shipment.status.changed, fleet.assignment.created) và đúng
// một sự kiện được phát ra trên of.platform.v1 (route.replanned). Kiểu dữ liệu đặt ở domain để
// cả consumer lẫn tầng lưu trữ dùng chung mà không package nào phải phụ thuộc package kia.

package domain

import (
	"encoding/json"
	"fmt"
	"time"
)

// Tên topic theo §4. routing-service là producer trên of.platform.v1 và consumer trên of.freight.v1.
const (
	TopicFreight  = "of.freight.v1"
	TopicPlatform = "of.platform.v1"
)

// Tên sự kiện, viết thường phân cách bằng dấu chấm đúng như §6.4 yêu cầu.
const (
	EventShipmentCreated        = "shipment.created"
	EventShipmentStatusChanged  = "shipment.status.changed"
	EventFleetAssignmentCreated = "fleet.assignment.created"
	EventRouteReplanned         = "route.replanned"
)

// Envelope là phong bì chung ở §0.7. Mọi message trên mọi topic đều có đúng hình dạng này;
// chỉ Payload là khác nhau.
type Envelope struct {
	EventID       string          `json:"event_id"`
	EventName     string          `json:"event_name"`
	SchemaVersion int             `json:"schema_version"`
	OccurredAt    time.Time       `json:"occurred_at"`
	TenantID      string          `json:"tenant_id"`
	RegionCode    string          `json:"region_code"`
	Producer      string          `json:"producer"`
	TraceID       string          `json:"trace_id"`
	PartitionKey  string          `json:"partition_key"`
	Payload       json.RawMessage `json:"payload"`
}

// schemaVersions ghi phiên bản mà routing-service đang sinh ra. Bên đọc bỏ qua trường lạ và
// không bao giờ từ chối vì trường lạ (§4.19 quy tắc 3), nên con số này chỉ tăng khi có trường
// bị xoá hoặc đổi kiểu.
var schemaVersions = map[string]int{
	EventRouteReplanned: 2,
}

// SchemaVersionFor tra phiên bản của một sự kiện do chúng ta phát ra.
func SchemaVersionFor(eventName string) (int, error) {
	v, ok := schemaVersions[eventName]
	if !ok {
		return 0, fmt.Errorf("routing-service không phát sự kiện %q", eventName)
	}
	return v, nil
}

// ShipmentCreated là payload của shipment.created do container-registry phát. routing-service
// dùng nó để lập tuyến phiên bản 1 mà không cần hỏi lại ai.
type ShipmentCreated struct {
	ShipmentID            string     `json:"shipment_id"`
	TenantID              string     `json:"tenant_id"`
	Reference             string     `json:"reference"`
	OriginFacilityID      string     `json:"origin_facility_id"`
	DestinationFacilityID string     `json:"destination_facility_id"`
	Incoterm              string     `json:"incoterm"`
	SLADeadlineAt         *time.Time `json:"sla_deadline_at"`
	RegionCode            string     `json:"region_code"`
	CreatedBy             string     `json:"created_by"`
}

// ShipmentStatusChanged là payload của shipment.status.changed. container-registry là dịch vụ
// duy nhất được đổi trạng thái lô hàng, nên đây là nguồn sự thật duy nhất về việc đó.
type ShipmentStatusChanged struct {
	ShipmentID string    `json:"shipment_id"`
	TenantID   string    `json:"tenant_id"`
	FromStatus string    `json:"from_status"`
	ToStatus   string    `json:"to_status"`
	ReasonCode string    `json:"reason_code"`
	ChangedBy  string    `json:"changed_by"`
	ChangedAt  time.Time `json:"changed_at"`
}

// replanTriggers là bảng trạng thái buộc phải lập lại tuyến, kèm lý do sẽ đi vào reason_code
// của route.replanned. at_risk đến từ telemetry.alert.raised mà container-registry tiêu thụ;
// held_at_customs đến từ tờ khai bị giữ. Cả hai đều làm tuyến hiện tại sai giờ.
var replanTriggers = map[string]string{
	"at_risk":          "shipment_at_risk",
	"held_at_customs":  "customs_hold",
	"in_transit":       "departure_confirmed",
}

// ReplanReasonFor trả về mã lý do nếu trạng thái mới đáng để lập lại tuyến.
func (s ShipmentStatusChanged) ReplanReasonFor() (string, bool) {
	reason, ok := replanTriggers[s.ToStatus]
	return reason, ok
}

// IsTerminal cho biết lô hàng đã kết thúc vòng đời; khi đó tuyến hiện hành được đóng lại và
// không bao giờ lập lại nữa.
func (s ShipmentStatusChanged) IsTerminal() bool {
	return s.ToStatus == "delivered" || s.ToStatus == "cancelled"
}

// FleetAssignmentCreated là payload của fleet.assignment.created do fleet-service phát.
// routing-service dùng nó để điền routing.route_legs.carrier_id — chặng đã có xe thì mọi lần
// lập lại tuyến sau đó phải cố giữ nguyên chặng đó.
type FleetAssignmentCreated struct {
	AssignmentID string    `json:"assignment_id"`
	ShipmentID   string    `json:"shipment_id"`
	LegID        string    `json:"leg_id"`
	VehicleID    string    `json:"vehicle_id"`
	DriverID     string    `json:"driver_id"`
	CarrierID    string    `json:"carrier_id"`
	AssignedAt   time.Time `json:"assigned_at"`
	AssignedBy   string    `json:"assigned_by"`
}

// RouteReplanned là payload duy nhất routing-service phát ra. Trường LegsChanged là thứ
// fleet-service đọc để giải phóng những phân công có leg_id không còn tồn tại (§4.11), nên nó
// phải liệt kê cả chặng bị xoá lẫn chặng đổi giờ, không chỉ chặng mới thêm.
type RouteReplanned struct {
	RouteID         string    `json:"route_id"`
	ShipmentID      string    `json:"shipment_id"`
	PreviousVersion int       `json:"previous_version"`
	Version         int       `json:"version"`
	Strategy        Strategy  `json:"strategy"`
	ReasonCode      string    `json:"reason_code"`
	TotalDistanceM  int64     `json:"total_distance_m"`
	TotalDurationS  int32     `json:"total_duration_s"`
	LegsChanged     []string  `json:"legs_changed"`
	ComputedAt      time.Time `json:"computed_at"`
}

// Validate chặn một payload thiếu trường bắt buộc trước khi nó kịp vào platform.outbox_messages.
// Sự kiện hỏng nằm trong outbox thì relay sẽ thử lại tám lần rồi đẩy vào of.platform.v1.dlq,
// và không ai phát hiện ra cho tới khi fleet-service ngừng giải phóng phân công.
func (r RouteReplanned) Validate() error {
	switch {
	case r.RouteID == "" || r.ShipmentID == "":
		return fmt.Errorf("route.replanned thiếu route_id hoặc shipment_id")
	case r.Version <= r.PreviousVersion:
		return fmt.Errorf("route.replanned có version %d không lớn hơn previous_version %d",
			r.Version, r.PreviousVersion)
	case r.ReasonCode == "":
		return fmt.Errorf("route.replanned thiếu reason_code")
	case !IsKnownStrategy(r.Strategy):
		return fmt.Errorf("route.replanned mang strategy không hợp lệ: %q", r.Strategy)
	}
	return nil
}

// DiffLegs so hai tập chặng và trả về danh sách leg_id đã thay đổi: bị bỏ, được thêm, hoặc còn
// đó nhưng đổi giờ, đổi cửa khẩu, đổi điểm đầu cuối.
func DiffLegs(before, after []Leg) []string {
	old := make(map[string]Leg, len(before))
	for _, l := range before {
		old[l.LegID] = l
	}
	seen := make(map[string]bool, len(after))
	var changed []string

	for _, l := range after {
		seen[l.LegID] = true
		prev, existed := old[l.LegID]
		if !existed {
			changed = append(changed, l.LegID)
			continue
		}
		if prev.PlannedDepartAt != l.PlannedDepartAt ||
			prev.PlannedArriveAt != l.PlannedArriveAt ||
			prev.FromFacilityID != l.FromFacilityID ||
			prev.ToFacilityID != l.ToFacilityID ||
			prev.Mode != l.Mode ||
			!sameCrossing(prev.CrossingID, l.CrossingID) {
			changed = append(changed, l.LegID)
		}
	}
	for _, l := range before {
		if !seen[l.LegID] {
			changed = append(changed, l.LegID)
		}
	}
	return changed
}

func sameCrossing(a, b *string) bool {
	switch {
	case a == nil && b == nil:
		return true
	case a == nil || b == nil:
		return false
	default:
		return *a == *b
	}
}
