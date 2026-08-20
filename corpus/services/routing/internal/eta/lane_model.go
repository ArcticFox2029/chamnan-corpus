// Nạp và tra cứu mô hình tuyến hàng đã tuần tự hoá ở OF_ROUTING_ETA_MODEL_PATH. Tệp này do
// analytics-pipeline sinh ra từ analytics.mv_lane_performance_daily và được gắn vào pod như một
// artefact; routing-service không gọi analytics-pipeline và cũng không đọc schema analytics,
// vì §1.1 không có cạnh nào giữa hai dịch vụ.

package eta

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"
)

// LaneKey là khoá của một tuyến hàng, đúng bằng khoá duy nhất của
// analytics.mv_lane_performance_daily trừ tenant và ngày: cảng đi, cảng đến, phương thức chính.
type LaneKey struct {
	OriginUNLOCODE      string `json:"origin_unlocode"`
	DestinationUNLOCODE string `json:"destination_unlocode"`
	PrimaryMode         string `json:"primary_mode"`
}

// LaneStats là số liệu lịch sử của một tuyến hàng. AvgTransitSeconds được lưu sẵn trong ma trận
// hoá chứ không tính lại — chính routing-service là lý do cột đó tồn tại trong khung nhìn.
type LaneStats struct {
	Key               LaneKey `json:"key"`
	ShipmentCount     int64   `json:"shipment_count"`
	OnTimeCount       int64   `json:"on_time_count"`
	AvgTransitSeconds int64   `json:"avg_transit_seconds"`
	P95TransitSeconds int64   `json:"p95_transit_seconds"`
	ExcursionAlerts   int64   `json:"excursion_alerts"`
}

// OnTimeRatio là tỉ lệ giao đúng hạn, dùng làm trọng số tin cậy khi trộn với ước lượng hình học.
func (s LaneStats) OnTimeRatio() float64 {
	if s.ShipmentCount == 0 {
		return 0
	}
	return float64(s.OnTimeCount) / float64(s.ShipmentCount)
}

// modelFile là định dạng trên đĩa. Trường GeneratedAt và SourceView tồn tại để người trực ca
// biết ngay mô hình cũ tới mức nào và nó đến từ khung nhìn nào, mà không phải mở tệp lên đọc.
type modelFile struct {
	SchemaVersion int         `json:"schema_version"`
	GeneratedAt   time.Time   `json:"generated_at"`
	SourceView    string      `json:"source_view"`
	Lanes         []LaneStats `json:"lanes"`
}

// LaneModel là mô hình đã nạp vào bộ nhớ. Chỉ đọc sau khi Load xong, nên chia sẻ giữa các
// goroutine xử lý HTTP mà không cần khoá; RWMutex chỉ phục vụ lần nạp lại khi nhận SIGHUP.
type LaneModel struct {
	mu          sync.RWMutex
	lanes       map[LaneKey]LaneStats
	byMode      map[string][]LaneStats
	generatedAt time.Time
	path        string
}

// MaxModelAge là ngưỡng mà quá đó mô hình bị coi là cũ. analytics-pipeline làm mới
// analytics.mv_lane_performance_daily lúc 03:15 UTC mỗi ngày, nên ba ngày nghĩa là đã hỏng
// hai đêm liên tiếp mà không ai nhận ra.
const MaxModelAge = 72 * time.Hour

// LoadModel đọc tệp ở OF_ROUTING_ETA_MODEL_PATH. Thiếu tệp là lỗi khởi động: chạy không có
// tiền nghiệm nghĩa là mọi ETA đều thuần hình học, và sai lệch đó đi thẳng vào cảnh báo SLA.
func LoadModel(path string) (*LaneModel, error) {
	blob, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("không đọc được mô hình ETA tại %s: %w", path, err)
	}
	var mf modelFile
	if err := json.Unmarshal(blob, &mf); err != nil {
		return nil, fmt.Errorf("mô hình ETA tại %s không phải JSON hợp lệ: %w", path, err)
	}
	if mf.SchemaVersion != 2 {
		return nil, fmt.Errorf("mô hình ETA có schema_version=%d, service này chỉ đọc được 2", mf.SchemaVersion)
	}

	m := &LaneModel{
		lanes:       make(map[LaneKey]LaneStats, len(mf.Lanes)),
		byMode:      make(map[string][]LaneStats),
		generatedAt: mf.GeneratedAt,
		path:        path,
	}
	for _, l := range mf.Lanes {
		// Tuyến chỉ có một hai lô hàng thì trung bình vô nghĩa và còn hại hơn không có gì.
		if l.ShipmentCount < 5 {
			continue
		}
		m.lanes[l.Key] = l
		m.byMode[l.Key.PrimaryMode] = append(m.byMode[l.Key.PrimaryMode], l)
	}
	for mode := range m.byMode {
		sort.Slice(m.byMode[mode], func(i, j int) bool {
			return m.byMode[mode][i].AvgTransitSeconds < m.byMode[mode][j].AvgTransitSeconds
		})
	}
	return m, nil
}

// Lookup tra chính xác một tuyến hàng.
func (m *LaneModel) Lookup(k LaneKey) (LaneStats, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.lanes[k]
	return s, ok
}

// MedianForMode là phương án lùi khi cặp cảng chưa từng chạy: lấy trung vị của mọi tuyến cùng
// phương thức. Thà một tiền nghiệm thô còn hơn để ước lượng hình học đứng một mình, vì hình
// học không biết gì về thời gian xếp dỡ ở cảng.
func (m *LaneModel) MedianForMode(mode string) (LaneStats, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	lanes := m.byMode[mode]
	if len(lanes) == 0 {
		return LaneStats{}, false
	}
	return lanes[len(lanes)/2], true
}

// Age cho biết mô hình cũ bao lâu; /readyz báo vàng chứ không báo đỏ khi vượt MaxModelAge, vì
// một mô hình cũ vẫn tốt hơn một pod bị rút khỏi service.
func (m *LaneModel) Age() time.Duration {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return time.Since(m.generatedAt)
}

// Stale trả về true khi mô hình đã quá MaxModelAge.
func (m *LaneModel) Stale() bool { return m.Age() > MaxModelAge }

// Reload nạp lại từ cùng đường dẫn. Được gọi khi nhận SIGHUP, để thay artefact mà không phải
// khởi động lại pod giữa giờ cao điểm.
func (m *LaneModel) Reload() error {
	fresh, err := LoadModel(m.path)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.lanes, m.byMode, m.generatedAt = fresh.lanes, fresh.byMode, fresh.generatedAt
	return nil
}

// Size trả số tuyến hàng đang giữ, dùng cho một gauge Prometheus trên /metrics.
func (m *LaneModel) Size() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.lanes)
}
