// Xếp hạng cửa khẩu cho một cặp điểm đi/điểm đến. Đây là phần trả lời trực tiếp cho
// GET /v1/crossings/recommend, và cũng là bước đầu tiên của mọi lần lập tuyến xuyên biên giới:
// chọn xong cửa khẩu rồi mới có chặng để tính. Thuế lấy từ customs-service, quãng đường vòng
// lấy từ geo.v1.GeoService/DistanceMatrix, thời gian chờ lấy từ danh mục hành lang.

package planner

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/corridor"
	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// CrossingRequest là đầu vào của việc xếp hạng.
type CrossingRequest struct {
	Origin           Facility
	Destination      Facility
	Mode             domain.Mode
	Strategy         domain.Strategy
	HSCode           string    // mã HS chính của lô hàng; rỗng thì bỏ qua trục thuế
	DeclaredValue    int64     // đơn vị tiền nhỏ nhất
	Currency         string
	GrossKg          int64
	DepartAt         time.Time
	Limit            int
}

// CrossingOption là một cửa khẩu đã được chấm điểm, kèm đủ lý do để người điều độ hiểu vì sao
// nó đứng ở vị trí đó. Web console hiển thị nguyên các trường này trong bảng gợi ý.
type CrossingOption struct {
	Crossing        corridor.Crossing `json:"-"`
	CrossingID      string            `json:"crossing_id"`
	UNLOCODE        string            `json:"unlocode"`
	CustomsOffice   string            `json:"customs_office_code"`
	DetourM         int64             `json:"detour_m"`
	ExpectedDwellS  int32             `json:"expected_dwell_s"`
	EstimatedDuty   int64             `json:"estimated_duty_minor"`
	Currency        string            `json:"currency,omitempty"`
	CarbonG         float64           `json:"carbon_g"`
	Score           float64           `json:"score"`
	TariffMissing   bool              `json:"tariff_missing"`
}

// CrossingRanker gom ba nguồn dữ liệu lại. Giữ ở dạng struct với các interface bên trong để
// test chấm điểm chạy được mà không cần geo-service lẫn customs-service.
type CrossingRanker struct {
	geo     upstream.Geo
	customs upstream.Customs
}

// NewCrossingRanker dựng bộ xếp hạng.
func NewCrossingRanker(geo upstream.Geo, customs upstream.Customs) *CrossingRanker {
	return &CrossingRanker{geo: geo, customs: customs}
}

// defaultLimit là số cửa khẩu trả về khi bên gọi không nói gì. Người điều độ không bao giờ xem
// quá năm dòng đầu, còn bộ lập tuyến chỉ cần dòng đầu tiên.
const defaultLimit = 5

// Rank xếp hạng cửa khẩu giữa hai quốc gia. Cùng quốc gia thì trả về lát cắt rỗng chứ không
// phải lỗi: một lô hàng nội địa hoàn toàn hợp lệ, nó chỉ không có cửa khẩu nào.
func (r *CrossingRanker) Rank(ctx context.Context, req CrossingRequest) ([]CrossingOption, error) {
	if req.Origin.CountryCode == "" || req.Destination.CountryCode == "" {
		return nil, fmt.Errorf("thiếu mã quốc gia của điểm đi hoặc điểm đến")
	}
	if req.Origin.CountryCode == req.Destination.CountryCode {
		return nil, nil
	}

	candidates := corridor.Candidates(req.Origin.CountryCode, req.Destination.CountryCode, string(req.Mode))
	if len(candidates) == 0 {
		return nil, fmt.Errorf("không có cửa khẩu %s→%s cho phương thức %q trong danh mục hành lang",
			req.Origin.CountryCode, req.Destination.CountryCode, req.Mode)
	}

	// Một lời gọi DistanceMatrix duy nhất cho tất cả ứng viên. Gọi từng cửa khẩu một là mười lăm
	// vòng mạng cho một việc mà geo-service làm gọn trong một lần, và giới hạn 64 điểm
	// (OF_GEO_MATRIX_MAX_POINTS) thì danh sách ứng viên không bao giờ chạm tới.
	points := make([]upstream.Point, 0, len(candidates))
	for _, c := range candidates {
		fence, err := r.geo.ResolveGeofence(ctx, c.GeofenceID)
		if err != nil {
			return nil, fmt.Errorf("cửa khẩu %s: %w", c.CrossingID, err)
		}
		points = append(points, fence.Centroid)
	}

	toCrossing, err := r.geo.DistanceMatrix(ctx, []upstream.Point{req.Origin.Centroid}, points, string(req.Mode))
	if err != nil {
		return nil, err
	}
	fromCrossing, err := r.geo.DistanceMatrix(ctx, points, []upstream.Point{req.Destination.Centroid}, string(req.Mode))
	if err != nil {
		return nil, err
	}

	direct, err := r.geo.DistanceMatrix(ctx,
		[]upstream.Point{req.Origin.Centroid}, []upstream.Point{req.Destination.Centroid}, string(req.Mode))
	if err != nil {
		return nil, err
	}
	directM := direct.DistanceM[0][0]

	opts := make([]CrossingOption, 0, len(candidates))
	scores := make([]candidateScore, 0, len(candidates))

	for i, c := range candidates {
		totalM := toCrossing.DistanceM[0][i] + fromCrossing.DistanceM[i][0]
		totalS := int64(toCrossing.DurationS[0][i] + fromCrossing.DurationS[i][0])

		arrival := req.DepartAt.Add(time.Duration(toCrossing.DurationS[0][i]) * time.Second)
		dwell := corridor.ExpectedDwell(c, arrival)

		duty, missing := r.duty(ctx, req, c)
		carbon := CarbonForLeg(req.Mode, totalM, req.GrossKg)

		opts = append(opts, CrossingOption{
			Crossing:       c,
			CrossingID:     c.CrossingID,
			UNLOCODE:       c.UNLOCODE,
			CustomsOffice:  c.CustomsOfficeCode,
			DetourM:        totalM - directM,
			ExpectedDwellS: int32(dwell.Seconds()),
			EstimatedDuty:  duty,
			Currency:       req.Currency,
			CarbonG:        carbon,
			TariffMissing:  missing,
		})
		scores = append(scores, candidateScore{
			DistanceM: totalM,
			DurationS: totalS + int64(dwell.Seconds()),
			DutyMinor: duty,
			CarbonG:   carbon,
			Currency:  req.Currency,
		})
	}

	b := boundsOf(scores)
	for i := range opts {
		opts[i].Score = Score(req.Strategy, scores[i], b)
	}

	sort.SliceStable(opts, func(i, j int) bool {
		if opts[i].Score != opts[j].Score {
			return opts[i].Score < opts[j].Score
		}
		// Hoà điểm thì lấy cửa khẩu ít chờ hơn; hoà tiếp thì lấy theo id để kết quả ổn định
		// qua các lần gọi, vì web console có so sánh hai lần gợi ý liền nhau.
		if opts[i].ExpectedDwellS != opts[j].ExpectedDwellS {
			return opts[i].ExpectedDwellS < opts[j].ExpectedDwellS
		}
		return opts[i].CrossingID < opts[j].CrossingID
	})

	// min là hàm dựng sẵn của Go 1.22; không tự định nghĩa lại để khỏi che mất bản gốc.
	limit := req.Limit
	if limit <= 0 || limit > len(opts) {
		limit = min(defaultLimit, len(opts))
	}
	return opts[:limit], nil
}

// duty hỏi customs-service thuế suất của hành lang này. Không có mã HS thì bỏ qua — trục thuế
// nhận điểm 0 và các trục còn lại vẫn xếp hạng bình thường. customs-service hỏng cũng vậy: lập
// được tuyến kém tối ưu vẫn hơn không lập được tuyến nào.
func (r *CrossingRanker) duty(ctx context.Context, req CrossingRequest, c corridor.Crossing) (int64, bool) {
	if req.HSCode == "" || req.DeclaredValue == 0 {
		return 0, true
	}
	on := req.DepartAt
	if on.IsZero() {
		on = time.Now().UTC()
	}
	tariff, err := r.customs.LookupTariff(ctx, upstream.TariffQuery{
		HSCode:             req.HSCode,
		DestinationCountry: c.ToCountry,
		OriginCountry:      req.Origin.CountryCode,
		OnDate:             on,
	})
	if err != nil {
		return 0, true
	}
	return DutyOnValue(req.DeclaredValue, tariff.DutyRateBP) +
		DutyOnValue(req.DeclaredValue, tariff.VATRateBP), false
}
