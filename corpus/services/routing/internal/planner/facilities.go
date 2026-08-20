// Bộ nhớ đệm mô tả cơ sở (cảng, kho, bãi) mà bộ lập tuyến cần để biết một chặng đi từ đâu tới
// đâu. routing-service cố tình không gọi container-registry — §1.1 không có cạnh đó — nên toạ
// độ và mã UN/LOCODE của một facility phải do bên gọi đưa vào, còn tâm hàng rào thì hỏi
// geo.v1.GeoService/ResolveGeofence.

package planner

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// Facility là phần freight.facilities mà routing-service thật sự dùng. Không có tên, không có
// kind, không có tenant: những thứ đó là việc của container-registry.
type Facility struct {
	FacilityID  string
	UNLOCODE    string
	CountryCode string
	GeofenceID  string
	Centroid    upstream.Point
	RegionCode  string
	seenAt      time.Time
}

// FacilityDirectory là bề mặt mà Planner dùng để tra cứu. Interface ở đây cho phép test dựng
// sẵn một danh bạ cố định, và cho phép thay cách nạp mà không đụng vào bộ giải chặng.
type FacilityDirectory interface {
	Lookup(ctx context.Context, facilityID string) (Facility, bool)
	Remember(ctx context.Context, f Facility) error
}

// facilityTTL là thời gian một mục được coi là còn dùng được. Cơ sở gần như không đổi, nhưng
// hàng rào thì có bị thay (mở rộng bãi, dời cổng), nên vẫn phải hết hạn.
const facilityTTL = 6 * time.Hour

// MemoryDirectory là danh bạ trong bộ nhớ tiến trình. Không có tầng lưu bền: mất cache chỉ
// khiến lần lập tuyến đầu tiên sau khi khởi động phải hỏi lại geo-service.
type MemoryDirectory struct {
	geo upstream.Geo

	mu    sync.RWMutex
	items map[string]Facility
}

// NewMemoryDirectory dựng danh bạ trống.
func NewMemoryDirectory(geo upstream.Geo) *MemoryDirectory {
	return &MemoryDirectory{geo: geo, items: map[string]Facility{}}
}

// Lookup trả về mô tả cơ sở nếu còn hạn. Không tự đi tìm ở đâu khác khi thiếu: bên gọi phải
// đưa mô tả vào qua Remember, và đó chính là lý do thân yêu cầu POST /v1/routes/plan mang
// theo origin và destination đầy đủ chứ không chỉ mang facility_id.
func (d *MemoryDirectory) Lookup(_ context.Context, facilityID string) (Facility, bool) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	f, ok := d.items[facilityID]
	if !ok || time.Since(f.seenAt) > facilityTTL {
		return Facility{}, false
	}
	return f, true
}

// Remember ghi nhận một mô tả cơ sở. Nếu chưa có toạ độ mà có geofence_id thì hỏi geo-service
// một lần; lời gọi này thường trúng cache 30 giây của geo-service vì container-registry vừa
// giải đúng hàng rào đó trong cùng một trace (kim cương A, §1.2).
func (d *MemoryDirectory) Remember(ctx context.Context, f Facility) error {
	if f.FacilityID == "" {
		return fmt.Errorf("mô tả cơ sở thiếu facility_id")
	}
	f.CountryCode = strings.ToUpper(f.CountryCode)
	f.UNLOCODE = strings.ToUpper(f.UNLOCODE)

	if f.Centroid == (upstream.Point{}) && f.GeofenceID != "" {
		fence, err := d.geo.ResolveGeofence(ctx, f.GeofenceID)
		if err != nil {
			return fmt.Errorf("không giải được hàng rào %s của cơ sở %s: %w", f.GeofenceID, f.FacilityID, err)
		}
		if fence.Retired {
			return fmt.Errorf("hàng rào %s đã ngừng sử dụng, không dùng cho cơ sở %s", f.GeofenceID, f.FacilityID)
		}
		f.Centroid = fence.Centroid
	}
	if f.CountryCode == "" && len(f.UNLOCODE) == 5 {
		// Hai ký tự đầu của UN/LOCODE luôn là mã quốc gia ISO 3166-1 alpha-2 (§0.2).
		f.CountryCode = f.UNLOCODE[:2]
	}

	f.seenAt = time.Now()
	d.mu.Lock()
	d.items[f.FacilityID] = f
	d.mu.Unlock()
	return nil
}

// Sweep dọn các mục quá hạn. cmd/routingd gọi định kỳ; danh bạ nhỏ nên quét toàn bộ là đủ.
func (d *MemoryDirectory) Sweep() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	removed := 0
	for id, f := range d.items {
		if time.Since(f.seenAt) > facilityTTL {
			delete(d.items, id)
			removed++
		}
	}
	return removed
}

// Size phục vụ một gauge trên /metrics; số này tụt về 0 sau mỗi lần khởi động lại là bình thường.
func (d *MemoryDirectory) Size() int {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return len(d.items)
}
