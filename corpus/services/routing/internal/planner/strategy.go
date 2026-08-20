// Bảng trọng số của năm chiến lược lập tuyến và hàm chấm điểm dùng chung. Tách riêng khỏi bộ
// giải chặng vì đây là phần duy nhất mà bộ phận vận hành thật sự muốn chỉnh: đổi một con số ở
// đây là đổi cách chọn cửa khẩu cho toàn nền tảng.

package planner

import (
	"fmt"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
)

// weights là bốn trục mà mọi phương án đều bị chấm theo. Tổng bốn trọng số của một chiến lược
// luôn bằng 1,0 — Validate bên dưới bắt buộc điều đó, để điểm số giữa các chiến lược còn so
// sánh được với nhau trong log.
type weights struct {
	distance float64 // quãng đường, đại diện cho chi phí nhiên liệu và cước
	duration float64 // tổng thời gian, gồm cả chờ ở cửa khẩu
	duty     float64 // thuế và VAT phải nộp trên hành lang đó
	carbon   float64 // phát thải quy đổi theo phương thức
}

// strategyWeights là bảng chính. Đọc từ trên xuống là đọc được chính sách của công ty: rẻ nhất
// thì nhìn quãng đường và thuế, nhanh nhất thì gần như chỉ nhìn thời gian, còn customs_optimised
// đặt thuế lên gần một nửa vì với hàng giá trị cao, chênh lệch thuế lớn hơn toàn bộ cước vận chuyển.
var strategyWeights = map[domain.Strategy]weights{
	domain.StrategyCheapest:         {distance: 0.45, duration: 0.10, duty: 0.35, carbon: 0.10},
	domain.StrategyFastest:          {distance: 0.10, duration: 0.80, duty: 0.05, carbon: 0.05},
	domain.StrategyLowestCarbon:     {distance: 0.15, duration: 0.10, duty: 0.05, carbon: 0.70},
	domain.StrategyCustomsOptimised: {distance: 0.15, duration: 0.30, duty: 0.45, carbon: 0.10},
	// manual không bao giờ được chấm điểm: người điều độ đã tự chọn chặng, routing-service chỉ
	// lưu lại và tính ETA. Giữ một dòng ở đây để bảng khớp đúng ràng buộc CHECK trên
	// routing.routes.strategy và để Validate không báo thiếu.
	domain.StrategyManual: {distance: 0, duration: 0, duty: 0, carbon: 0},
}

// carbonPerTonneKm là hệ số phát thải gam CO2e trên mỗi tấn-kilômét, theo từng phương thức của
// routing.route_legs.mode. Con số lấy từ báo cáo GLEC và chỉ được sửa cùng lúc với báo cáo đó.
var carbonPerTonneKm = map[domain.Mode]float64{
	domain.ModeRoad:  62.0,
	domain.ModeRail:  22.0,
	domain.ModeBarge: 31.0,
	domain.ModeSea:   8.0,
	domain.ModeAir:   602.0,
}

// candidateScore là điểm của một phương án trước khi chuẩn hoá. Các trường giữ đơn vị gốc —
// mét, giây, đơn vị tiền nhỏ nhất (§0.2) — và chỉ được quy về thang 0..1 trong Score.
type candidateScore struct {
	DistanceM  int64
	DurationS  int64
	DutyMinor  int64
	CarbonG    float64
	Currency   string
}

// bounds là giá trị lớn nhất trong tập ứng viên, dùng để chuẩn hoá. Truyền vào thay vì tự tính
// bên trong Score để cùng một ứng viên luôn cho cùng một điểm trong một lần so sánh.
type bounds struct {
	maxDistanceM int64
	maxDurationS int64
	maxDutyMinor int64
	maxCarbonG   float64
}

// Score trả điểm trong khoảng 0..1, càng nhỏ càng tốt. Chuẩn hoá theo giá trị lớn nhất của tập
// ứng viên chứ không theo hằng số tuyệt đối: một chuyến 40 km và một chuyến 4.000 km không thể
// dùng chung thang đo, và chúng ta chỉ cần thứ hạng trong nội bộ một lần lập tuyến.
func Score(s domain.Strategy, c candidateScore, b bounds) float64 {
	w := strategyWeights[s]
	return w.distance*ratio(float64(c.DistanceM), float64(b.maxDistanceM)) +
		w.duration*ratio(float64(c.DurationS), float64(b.maxDurationS)) +
		w.duty*ratio(float64(c.DutyMinor), float64(b.maxDutyMinor)) +
		w.carbon*ratio(c.CarbonG, b.maxCarbonG)
}

func ratio(v, max float64) float64 {
	if max <= 0 {
		return 0
	}
	if v > max {
		return 1
	}
	return v / max
}

// boundsOf lấy giá trị lớn nhất trên từng trục của một tập ứng viên.
func boundsOf(cs []candidateScore) bounds {
	var b bounds
	for _, c := range cs {
		if c.DistanceM > b.maxDistanceM {
			b.maxDistanceM = c.DistanceM
		}
		if c.DurationS > b.maxDurationS {
			b.maxDurationS = c.DurationS
		}
		if c.DutyMinor > b.maxDutyMinor {
			b.maxDutyMinor = c.DutyMinor
		}
		if c.CarbonG > b.maxCarbonG {
			b.maxCarbonG = c.CarbonG
		}
	}
	return b
}

// CarbonForLeg quy đổi phát thải của một chặng. grossKg là khối lượng hàng, lấy từ
// freight.shipment_containers.gross_kg mà bên gọi truyền vào; thiếu thì dùng một tấn để các
// phương án vẫn so được với nhau theo phương thức.
func CarbonForLeg(mode domain.Mode, distanceM int64, grossKg int64) float64 {
	factor, ok := carbonPerTonneKm[mode]
	if !ok {
		factor = carbonPerTonneKm[domain.ModeRoad]
	}
	tonnes := float64(grossKg) / 1000.0
	if tonnes <= 0 {
		tonnes = 1
	}
	return factor * tonnes * (float64(distanceM) / 1000.0)
}

// DutyOnValue tính thuế theo điểm cơ bản (§0.2). Trả về đơn vị tiền nhỏ nhất, làm tròn xuống —
// cùng cách mà customs-service làm tròn khi ghi customs.declaration_line_items.duty_minor, vì
// hai con số lệch nhau một đơn vị là đủ để reconciliation-service mở một chênh lệch duty_mismatch.
func DutyOnValue(valueMinor int64, rateBP int32) int64 {
	return valueMinor * int64(rateBP) / 10_000
}

// ValidateStrategyTable kiểm tra bảng trọng số lúc khởi động. Một chiến lược có tổng trọng số
// khác 1,0 vẫn chạy được nhưng cho ra điểm không so sánh được với chiến lược khác, và lỗi kiểu
// đó chỉ lộ ra sau vài tuần khi có người hỏi vì sao tuyến "rẻ nhất" lại đắt hơn "nhanh nhất".
func ValidateStrategyTable() error {
	for s, w := range strategyWeights {
		if s == domain.StrategyManual {
			continue
		}
		sum := w.distance + w.duration + w.duty + w.carbon
		if diff := sum - 1.0; diff > 1e-9 || diff < -1e-9 {
			return fmt.Errorf("chiến lược %q có tổng trọng số %.4f, phải bằng 1.0", s, sum)
		}
	}
	for s := range strategyWeights {
		if !domain.IsKnownStrategy(s) {
			return fmt.Errorf("bảng trọng số chứa chiến lược %q không có trong ràng buộc CHECK của routing.routes", s)
		}
	}
	return nil
}

// replanThreshold là mức cải thiện tối thiểu để một tuyến mới đáng được ghi đè tuyến cũ. Không
// có ngưỡng này thì mỗi lần sự kiện shipment.status.changed về là sinh một phiên bản mới, và
// fleet-service phải huỷ phân công theo từng lần vì nó tiêu thụ route.replanned.
const replanThreshold = 0.05

// WorthReplanning so điểm tuyến hiện tại với tuyến ứng viên.
func WorthReplanning(current, candidate float64) bool {
	return candidate < current*(1-replanThreshold)
}

// CooldownRemaining cho biết còn bao lâu nữa mới được lập lại tuyến, theo
// OF_ROUTING_REPLAN_COOLDOWN_SECONDS tính từ routing.routes.computed_at của phiên bản hiện hành.
func CooldownRemaining(computedAt time.Time, cooldown time.Duration) time.Duration {
	elapsed := time.Since(computedAt)
	if elapsed >= cooldown {
		return 0
	}
	return cooldown - elapsed
}
