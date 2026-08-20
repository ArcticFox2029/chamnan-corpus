// Package eta tính giờ đến dự kiến cho từng chặng của một tuyến. Ước lượng luôn là sự pha trộn
// của ba nguồn: thời gian chạy hình học do geo-service trả về, tiền nghiệm lịch sử lấy từ mô
// hình tuyến hàng, và thời gian chờ ở cửa khẩu. Đây là thứ mà POST /v1/eta/batch trả ra và cũng
// là thứ quyết định một tuyến có bị coi là trễ SLA hay không.
package eta

import (
	"context"
	"math"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/corridor"
	"github.com/orbitalfreight/platform/services/routing/internal/domain"
)

// Estimator là bề mặt mà bộ lập tuyến và tầng HTTP dùng. Có interface vì phần chấm điểm chiến
// lược phải chạy được với một ước lượng cố định trong test, và vì bản "chỉ hình học" thật sự
// được dùng khi mô hình tuyến hàng chưa nạp được.
type Estimator interface {
	EstimateLeg(ctx context.Context, in LegInput) Estimate
	EstimateRoute(ctx context.Context, r domain.Route, in RouteInput) []Estimate
}

// LegInput là mọi thứ cần để ước lượng một chặng. GeometricDurationS đến từ
// geo.v1.GeoService/DistanceMatrix; nếu bằng 0 thì ước lượng rơi hoàn toàn về tiền nghiệm.
type LegInput struct {
	Leg                 domain.Leg
	OriginUNLOCODE      string
	DestinationUNLOCODE string
	GeometricDurationS  int32
	DepartAt            time.Time
	Crossing            *corridor.Crossing
}

// RouteInput mang phần dùng chung cho cả tuyến để không phải lặp lại ở từng chặng.
type RouteInput struct {
	FacilityUNLOCODE map[string]string // facility_id -> unlocode
	GeometricPerLeg  map[string]int32  // leg_id -> giây
	DepartAt         time.Time
}

// Estimate là kết quả cho một chặng. P95ArriveAt được trả kèm vì web console vẽ dải tin cậy,
// và vì reconciliation-service so giờ đến thực với dải này khi mở chênh lệch.
type Estimate struct {
	LegID       string    `json:"leg_id"`
	ArriveAt    time.Time `json:"arrive_at"`
	P95ArriveAt time.Time `json:"p95_arrive_at"`
	DwellS      int32     `json:"dwell_s"`
	Source      string    `json:"source"` // lane_model | mode_median | geometry_only
	Confidence  float64   `json:"confidence"`
}

// BlendedEstimator trộn tiền nghiệm với hình học. Trọng số không phải hằng số: tuyến chạy càng
// nhiều lô hàng thì lịch sử càng đáng tin, tuyến mới thì hình học nói to hơn.
type BlendedEstimator struct {
	model *LaneModel
}

// New dựng một BlendedEstimator. model có thể nil — khi đó mọi ước lượng đều thuần hình học và
// trường Source ghi rõ điều đó, để không ai nhìn con số mà tưởng nó có lịch sử đứng sau.
func New(model *LaneModel) *BlendedEstimator {
	return &BlendedEstimator{model: model}
}

// confidenceTable ánh xạ số lô hàng lịch sử sang trọng số dành cho tiền nghiệm. Bảng thay cho
// một công thức mượt vì các ngưỡng này được chọn từ số liệu thật và cần đọc được bằng mắt.
var confidenceTable = []struct {
	minShipments int64
	priorWeight  float64
}{
	{500, 0.80},
	{200, 0.70},
	{80, 0.55},
	{30, 0.40},
	{5, 0.25},
	{0, 0.00},
}

func priorWeightFor(shipments int64) float64 {
	for _, row := range confidenceTable {
		if shipments >= row.minShipments {
			return row.priorWeight
		}
	}
	return 0
}

// EstimateLeg tính giờ đến của một chặng.
func (b *BlendedEstimator) EstimateLeg(_ context.Context, in LegInput) Estimate {
	depart := in.DepartAt
	if depart.IsZero() {
		depart = in.Leg.PlannedDepartAt
	}

	geometric := time.Duration(in.GeometricDurationS) * time.Second
	prior, source, weight := b.prior(in)

	transit := geometric
	switch {
	case weight == 0 || prior == 0:
		source = "geometry_only"
	case geometric == 0:
		transit = prior
	default:
		transit = time.Duration(float64(prior)*weight + float64(geometric)*(1-weight))
	}

	// Chờ ở cửa khẩu cộng vào sau khi đã trộn: nó là thời gian đứng yên, không phải thời gian
	// chạy, nên không được để lịch sử làm loãng đi.
	var dwell time.Duration
	if in.Crossing != nil {
		dwell = corridor.ExpectedDwell(*in.Crossing, depart.Add(transit))
	}

	arrive := depart.Add(transit + dwell)
	return Estimate{
		LegID:       in.Leg.LegID,
		ArriveAt:    arrive.UTC(),
		P95ArriveAt: depart.Add(b.p95(in, transit) + dwell).UTC(),
		DwellS:      int32(dwell.Seconds()),
		Source:      source,
		Confidence:  weight,
	}
}

// EstimateRoute chạy EstimateLeg lần lượt theo seq_no, lấy giờ đến của chặng trước làm giờ đi
// của chặng sau. Không song song hoá: các chặng phụ thuộc nhau theo thời gian, và một tuyến
// tối đa OF_ROUTING_MAX_LEGS chặng thì vòng lặp này không bao giờ là chỗ nghẽn.
func (b *BlendedEstimator) EstimateRoute(ctx context.Context, r domain.Route, in RouteInput) []Estimate {
	out := make([]Estimate, 0, len(r.Legs))
	cursor := in.DepartAt
	if cursor.IsZero() && len(r.Legs) > 0 {
		cursor = r.Legs[0].PlannedDepartAt
	}
	for _, leg := range r.Legs {
		li := LegInput{
			Leg:                 leg,
			OriginUNLOCODE:      in.FacilityUNLOCODE[leg.FromFacilityID],
			DestinationUNLOCODE: in.FacilityUNLOCODE[leg.ToFacilityID],
			GeometricDurationS:  in.GeometricPerLeg[leg.LegID],
			DepartAt:            cursor,
		}
		if leg.CrossingID != nil {
			if c, ok := corridor.ByID(*leg.CrossingID); ok {
				li.Crossing = &c
			}
		}
		est := b.EstimateLeg(ctx, li)
		out = append(out, est)
		cursor = est.ArriveAt
	}
	return out
}

// prior chọn tiền nghiệm: khớp đúng tuyến hàng trước, không có thì trung vị theo phương thức.
func (b *BlendedEstimator) prior(in LegInput) (time.Duration, string, float64) {
	if b.model == nil || in.OriginUNLOCODE == "" || in.DestinationUNLOCODE == "" {
		return 0, "geometry_only", 0
	}
	key := LaneKey{
		OriginUNLOCODE:      in.OriginUNLOCODE,
		DestinationUNLOCODE: in.DestinationUNLOCODE,
		PrimaryMode:         string(in.Leg.Mode),
	}
	if s, ok := b.model.Lookup(key); ok {
		return time.Duration(s.AvgTransitSeconds) * time.Second, "lane_model", priorWeightFor(s.ShipmentCount)
	}
	if s, ok := b.model.MedianForMode(string(in.Leg.Mode)); ok {
		// Trung vị theo phương thức chỉ được tin một nửa so với tuyến khớp đúng.
		return time.Duration(s.AvgTransitSeconds) * time.Second, "mode_median", priorWeightFor(s.ShipmentCount) / 2
	}
	return 0, "geometry_only", 0
}

// p95 dựng biên trên. Khi có lịch sử thì dùng đúng p95_transit_seconds của tuyến; khi không thì
// nhân hệ số cố định theo phương thức, vì đường biển trễ theo kiểu khác hẳn đường bộ.
func (b *BlendedEstimator) p95(in LegInput, transit time.Duration) time.Duration {
	if b.model != nil {
		key := LaneKey{in.OriginUNLOCODE, in.DestinationUNLOCODE, string(in.Leg.Mode)}
		if s, ok := b.model.Lookup(key); ok && s.P95TransitSeconds > 0 {
			return time.Duration(s.P95TransitSeconds) * time.Second
		}
	}
	return time.Duration(float64(transit) * spreadFactor(in.Leg.Mode))
}

// spreadFactor là độ giãn p95/trung bình theo từng phương thức, lấy từ số liệu vận hành.
var spreadFactor = func(m domain.Mode) float64 {
	switch m {
	case domain.ModeSea:
		return 1.65
	case domain.ModeBarge:
		return 1.45
	case domain.ModeRail:
		return 1.30
	case domain.ModeRoad:
		return 1.25
	case domain.ModeAir:
		return 1.15
	default:
		return 1.35
	}
}

// LateBy trả về khoảng trễ so với hạn SLA, hoặc 0 nếu kịp. Dấu dương luôn nghĩa là trễ, để chỗ
// gọi không phải tự đoán chiều của phép trừ.
func LateBy(arrive time.Time, deadline *time.Time) time.Duration {
	if deadline == nil {
		return 0
	}
	d := arrive.Sub(*deadline)
	return time.Duration(math.Max(0, float64(d)))
}
