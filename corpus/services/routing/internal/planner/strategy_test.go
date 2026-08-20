// Kiểm thử bảng trọng số và các hàm chấm điểm. Ở đây không có geo-service, không có
// customs-service và không có Postgres: mọi thứ đắt tiền đều nằm sau interface, nên phần logic
// quyết định "đi cửa khẩu nào" kiểm tra được bằng bảng dữ liệu thuần tuý.

package planner

import (
	"testing"
	"time"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
)

func TestValidateStrategyTable(t *testing.T) {
	// Bảng phải khớp ràng buộc CHECK của routing.routes.strategy và tổng trọng số phải bằng 1.
	if err := ValidateStrategyTable(); err != nil {
		t.Fatalf("bảng trọng số không hợp lệ: %v", err)
	}
	for _, s := range []domain.Strategy{
		domain.StrategyCheapest, domain.StrategyFastest, domain.StrategyLowestCarbon,
		domain.StrategyCustomsOptimised, domain.StrategyManual,
	} {
		if _, ok := strategyWeights[s]; !ok {
			t.Errorf("thiếu chiến lược %q trong bảng trọng số", s)
		}
	}
}

func TestScoreRanksByStrategy(t *testing.T) {
	// Ba ứng viên cố tình mỗi cái mạnh một trục: một cái ngắn nhất, một cái nhanh nhất,
	// một cái thuế thấp nhất. Chiến lược nào phải chọn cái nào là điều duy nhất đang kiểm tra.
	short := candidateScore{DistanceM: 400_000, DurationS: 40_000, DutyMinor: 900_000, CarbonG: 24_800}
	fast := candidateScore{DistanceM: 720_000, DurationS: 26_000, DutyMinor: 950_000, CarbonG: 44_640}
	cheapDuty := candidateScore{DistanceM: 690_000, DurationS: 43_000, DutyMinor: 310_000, CarbonG: 42_780}
	all := []candidateScore{short, fast, cheapDuty}
	b := boundsOf(all)

	cases := []struct {
		name     string
		strategy domain.Strategy
		want     candidateScore
	}{
		{"rẻ nhất chọn quãng đường ngắn", domain.StrategyCheapest, short},
		{"nhanh nhất chọn thời gian ngắn", domain.StrategyFastest, fast},
		{"tối ưu hải quan chọn thuế thấp", domain.StrategyCustomsOptimised, cheapDuty},
		{"ít phát thải chọn quãng đường ngắn", domain.StrategyLowestCarbon, short},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			best := all[0]
			bestScore := Score(tc.strategy, all[0], b)
			for _, c := range all[1:] {
				if s := Score(tc.strategy, c, b); s < bestScore {
					best, bestScore = c, s
				}
			}
			if best != tc.want {
				t.Errorf("chiến lược %s chọn %+v, mong đợi %+v", tc.strategy, best, tc.want)
			}
		})
	}
}

func TestDutyOnValue(t *testing.T) {
	// Thuế suất là điểm cơ bản (§0.2) và kết quả là đơn vị tiền nhỏ nhất, làm tròn xuống —
	// đúng cách customs-service làm tròn, nếu không reconciliation-service sẽ mở duty_mismatch.
	cases := []struct {
		valueMinor int64
		rateBP     int32
		want       int64
	}{
		{1_000_00, 1250, 12_50},     // 1000,00 EUR ở mức 12,50 % = 125,00
		{999_99, 1250, 12_49},       // làm tròn xuống, không lên
		{50_000_00, 0, 0},           // hàng miễn thuế
		{0, 2000, 0},                // giá trị bằng 0
		{7_531_21, 375, 28_24},      // mức lẻ 3,75 %
	}
	for _, tc := range cases {
		if got := DutyOnValue(tc.valueMinor, tc.rateBP); got != tc.want {
			t.Errorf("DutyOnValue(%d, %d) = %d, mong đợi %d", tc.valueMinor, tc.rateBP, got, tc.want)
		}
	}
}

func TestCarbonForLeg(t *testing.T) {
	// Đường sắt phải thấp hơn đường bộ trên cùng quãng đường, nếu không chiến lược
	// lowest_carbon sẽ chọn sai phương thức trên mọi hành lang có cả hai.
	const distanceM = 800_000
	road := CarbonForLeg(domain.ModeRoad, distanceM, 20_000)
	rail := CarbonForLeg(domain.ModeRail, distanceM, 20_000)
	sea := CarbonForLeg(domain.ModeSea, distanceM, 20_000)
	if !(sea < rail && rail < road) {
		t.Errorf("thứ tự phát thải sai: biển=%.0f sắt=%.0f bộ=%.0f", sea, rail, road)
	}
	// Không biết khối lượng thì tính theo một tấn, không phải bằng 0.
	if CarbonForLeg(domain.ModeRoad, distanceM, 0) <= 0 {
		t.Error("khối lượng bằng 0 phải rơi về một tấn chứ không cho ra 0")
	}
}

func TestWorthReplanning(t *testing.T) {
	cases := []struct {
		name      string
		current   float64
		candidate float64
		want      bool
	}{
		{"cải thiện 20 phần trăm thì đáng", 0.500, 0.400, true},
		{"cải thiện 2 phần trăm thì không", 0.500, 0.490, false},
		{"bằng nhau thì không", 0.500, 0.500, false},
		{"tệ hơn thì không", 0.500, 0.610, false},
		{"đúng ngưỡng 5 phần trăm thì chưa đủ", 0.500, 0.475, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := WorthReplanning(tc.current, tc.candidate); got != tc.want {
				t.Errorf("WorthReplanning(%.3f, %.3f) = %v, mong đợi %v",
					tc.current, tc.candidate, got, tc.want)
			}
		})
	}
}

func TestCooldownRemaining(t *testing.T) {
	const cooldown = 10 * time.Minute
	if got := CooldownRemaining(time.Now().Add(-11*time.Minute), cooldown); got != 0 {
		t.Errorf("quá hạn chờ phải trả 0, nhận %s", got)
	}
	got := CooldownRemaining(time.Now().Add(-4*time.Minute), cooldown)
	if got <= 5*time.Minute || got > 6*time.Minute {
		t.Errorf("còn lại %s, mong đợi khoảng 6 phút", got)
	}
}
