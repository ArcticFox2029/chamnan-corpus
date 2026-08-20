// Package ids sinh và kiểm tra định danh có tiền tố theo §0.1 của SPEC. Tiền tố là một phần
// của giá trị và không bao giờ bị cắt bỏ khi truyền đi, kể cả trong payload sự kiện; nhờ vậy
// một id lạc chỗ (ví dụ leg_ nằm trong trường route_id) lộ ra ngay ở log chứ không phải đợi
// tới lúc INSERT hỏng.
package ids

import (
	"crypto/rand"
	"fmt"
	"strings"
	"time"

	"github.com/oklog/ulid/v2"
)

// Tiền tố mà routing-service tự sinh. Các tiền tố khác trong bảng ở §0.1 chỉ được đọc,
// không bao giờ được sinh ở đây — shp_ là của container-registry, asg_ là của fleet-service.
const (
	PrefixRoute = "rte_"
	PrefixLeg   = "leg_"
	PrefixEvent = "evt_"
)

// readable là bảng các tiền tố mà routing-service có quyền nhận vào. Dùng bảng thay vì hàm
// switch vì cùng bảng này phục vụ cả kiểm tra tham số HTTP lẫn kiểm tra payload Kafka.
var readable = map[string]string{
	PrefixRoute: "routing.routes.route_id",
	PrefixLeg:   "routing.route_legs.leg_id",
	PrefixEvent: "platform.outbox_messages.message_id",
	"shp_":      "freight.shipments.shipment_id",
	"cnt_":      "freight.containers.container_id",
	"fac_":      "freight.facilities.facility_id",
	"tnt_":      "identity.tenants.tenant_id",
	"usr_":      "identity.users.user_id",
	"bxg_":      "geo.border_crossings.crossing_id",
	"gfn_":      "geo.geofences.geofence_id",
	"car_":      "fleet.carriers.carrier_id",
	"asg_":      "fleet.vehicle_assignments.assignment_id",
	"dcl_":      "customs.customs_declarations.declaration_id",
}

// entropy dùng chung; ulid.Monotonic bảo đảm hai id sinh trong cùng một mili giây vẫn giữ
// thứ tự tăng dần, điều mà routing-service dựa vào khi sinh leg_ theo đúng thứ tự seq_no.
var entropy = ulid.Monotonic(rand.Reader, 0)

// New sinh một định danh mới với tiền tố cho trước, ví dụ New(PrefixRoute) -> "rte_01J8ZK…".
func New(prefix string) string {
	id := ulid.MustNew(ulid.Timestamp(time.Now().UTC()), entropy)
	return prefix + id.String()
}

// NewRoute, NewLeg và NewEvent là ba lối gọi duy nhất được dùng trong service; chúng tồn tại
// để không ai phải nhớ chuỗi tiền tố khi viết code mới.
func NewRoute() string { return New(PrefixRoute) }
func NewLeg() string   { return New(PrefixLeg) }
func NewEvent() string { return New(PrefixEvent) }

// Validate kiểm tra một id nhận từ bên ngoài: đúng tiền tố mong đợi và phần ULID phía sau
// đúng 26 ký tự base32 hợp lệ.
func Validate(id, wantPrefix string) error {
	if !strings.HasPrefix(id, wantPrefix) {
		return fmt.Errorf("định danh %q không mang tiền tố %q", redact(id), wantPrefix)
	}
	body := strings.TrimPrefix(id, wantPrefix)
	if len(body) != ulid.EncodedSize {
		return fmt.Errorf("định danh %q dài %d ký tự sau tiền tố, phải là %d",
			redact(id), len(body), ulid.EncodedSize)
	}
	if _, err := ulid.ParseStrict(body); err != nil {
		return fmt.Errorf("phần ULID của %q không hợp lệ: %w", redact(id), err)
	}
	return nil
}

// Describe trả về tên cột mà tiền tố này thuộc về, dùng trong thông báo lỗi để người trực ca
// biết ngay id sai đến từ dịch vụ nào.
func Describe(id string) (string, bool) {
	if len(id) < 4 {
		return "", false
	}
	col, ok := readable[id[:4]]
	return col, ok
}

// TimestampOf lấy lại mốc thời gian nhúng trong ULID. routing-service dùng nó để lọc nhanh
// những message outbox quá cũ mà không phải chạm vào cột created_at.
func TimestampOf(id string) (time.Time, error) {
	if len(id) < 5 {
		return time.Time{}, fmt.Errorf("định danh quá ngắn: %q", redact(id))
	}
	parsed, err := ulid.ParseStrict(id[4:])
	if err != nil {
		return time.Time{}, err
	}
	return ulid.Time(parsed.Time()).UTC(), nil
}

// redact giữ tiền tố và bốn ký tự đầu, phần còn lại bị cắt. Log của chúng ta chảy sang một
// vùng khác, và §7 quy tắc 7 cấm mang dữ liệu định danh đầy đủ ra khỏi vùng của nó.
func redact(id string) string {
	if len(id) <= 8 {
		return id
	}
	return id[:8] + "…"
}
