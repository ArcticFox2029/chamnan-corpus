// Package corridor giữ danh mục cửa khẩu mà bộ lập tuyến chọn ra ứng viên từ đó. Danh mục là
// một bản chụp được commit vào repo của những dòng tham chiếu trong geo.border_crossings, vì
// §7 quy tắc 2 cấm routing-service truy vấn schema geo, còn §3.6 thì geo-service không có
// endpoint nào liệt kê cửa khẩu. Trọng tài cuối cùng vẫn là cơ sở dữ liệu: khoá ngoại
// routing.route_legs.crossing_id → geo.border_crossings sẽ chặn ngay một id đã lỗi thời.
package corridor

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// Crossing là một cửa khẩu. Các trường sao đúng tên cột của geo.border_crossings để khi so
// bản chụp với thực tế không ai phải dịch tên qua lại.
type Crossing struct {
	CrossingID        string   // bxg_<ULID>, khớp geo.border_crossings.crossing_id
	FromCountry       string   // ISO 3166-1 alpha-2, viết hoa
	ToCountry         string
	UNLOCODE          string   // năm ký tự
	CustomsOfficeCode string   // được customs-service ghi lên customs.customs_declarations
	GeofenceID        string   // gfn_<ULID>, hàng rào kind = 'border_zone'
	ModesAllowed      []string // tập con của routing.route_legs.mode
	AvgDwellMinutes   int      // analytics-pipeline làm mới cột này hằng đêm
	Open24h           bool
}

// catalogue là bảng tra cứu chính. Thứ tự trong bảng không mang ý nghĩa — điểm số ở
// planner mới quyết định thứ hạng — nhưng mỗi cặp (from, to, unlocode) chỉ được xuất hiện
// một lần, đúng như ràng buộc UNIQUE trên geo.border_crossings.
var catalogue = []Crossing{
	// Hành lang Bắc Âu — Ba Lan/Đức, tuyến bộ và tuyến sắt chạy song song.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD501", "DE", "PL", "DEFRA", "DE003891", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G1", []string{"road", "rail"}, 35, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD502", "PL", "DE", "PLSWI", "PL401220", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G2", []string{"road", "rail"}, 41, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD503", "PL", "BY", "PLTES", "PL301050", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G3", []string{"road"}, 260, false},
	// Hành lang Alpine — đường bộ và đường sắt qua Áo, có giới hạn giờ chạy ban đêm.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD504", "DE", "AT", "ATKUF", "AT100400", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G4", []string{"road", "rail"}, 28, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD505", "AT", "IT", "ATBRE", "AT700320", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G5", []string{"road", "rail"}, 46, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD506", "CH", "IT", "CHCHI", "CH061100", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G6", []string{"road", "rail"}, 52, false},
	// Măng-sơ: phà và đường hầm là hai cửa khẩu riêng biệt vì thủ tục khác nhau hoàn toàn.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD507", "FR", "GB", "FRCQF", "FR002850", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G7", []string{"road", "sea"}, 95, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD508", "FR", "GB", "FRCOQ", "FR002851", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G8", []string{"road", "rail"}, 74, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD509", "NL", "GB", "NLRTM", "NL010100", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5G9", []string{"sea", "barge"}, 180, true},
	// Bắc Mỹ.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50A", "US", "CA", "USBUF", "US090100", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GA", []string{"road", "rail"}, 62, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50B", "US", "MX", "USLRD", "US230400", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GB", []string{"road", "rail"}, 210, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50C", "MX", "US", "MXNVL", "MX240300", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GC", []string{"road"}, 245, false},
	// Đông Nam Á và Trung Đông.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50D", "SG", "MY", "SGWDL", "SG010200", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GD", []string{"road"}, 88, true},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50E", "MY", "TH", "MYBKS", "MY120600", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GE", []string{"road", "rail"}, 130, false},
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50F", "AE", "SA", "AEGHU", "AE050900", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GF", []string{"road"}, 165, true},
	// Nam Mỹ — Brazil/Argentina, cửa khẩu duy nhất chịu được xe container quá khổ.
	{"bxg_01H8ZK4T9QW3RM7XN2VB6HD50G", "BR", "AR", "BRURA", "BR811000", "gfn_01H8ZK4T9QW3RM7XN2VB6HD5GG", []string{"road"}, 190, false},
}

// byPair là chỉ mục "FROM>TO" -> danh sách cửa khẩu, dựng một lần lúc nạp package. Danh mục
// nhỏ và chỉ đọc, nên không cần khoá và cũng không cần làm mới khi đang chạy.
var byPair = func() map[string][]Crossing {
	idx := make(map[string][]Crossing, len(catalogue))
	for _, c := range catalogue {
		key := pairKey(c.FromCountry, c.ToCountry)
		idx[key] = append(idx[key], c)
	}
	for k := range idx {
		// Sắp theo thời gian chờ trung bình để bộ lập tuyến có thứ tự ổn định khi hai cửa khẩu
		// cùng điểm; ULID làm tiêu chí phụ để kết quả không phụ thuộc thứ tự map.
		sort.Slice(idx[k], func(i, j int) bool {
			if idx[k][i].AvgDwellMinutes != idx[k][j].AvgDwellMinutes {
				return idx[k][i].AvgDwellMinutes < idx[k][j].AvgDwellMinutes
			}
			return idx[k][i].CrossingID < idx[k][j].CrossingID
		})
	}
	return idx
}()

var byID = func() map[string]Crossing {
	idx := make(map[string]Crossing, len(catalogue))
	for _, c := range catalogue {
		idx[c.CrossingID] = c
	}
	return idx
}()

// Candidates trả về các cửa khẩu nối hai quốc gia, đã lọc theo phương thức vận chuyển. Trả về
// lát cắt rỗng chứ không phải lỗi khi không có cửa khẩu nào: hai nước có thể không có biên giới
// chung, và khi đó bộ lập tuyến phải tìm nước trung chuyển thay vì bỏ cuộc.
func Candidates(from, to, mode string) []Crossing {
	all := byPair[pairKey(from, to)]
	out := make([]Crossing, 0, len(all))
	for _, c := range all {
		if mode == "" || allows(c, mode) {
			out = append(out, c)
		}
	}
	return out
}

// ByID tra một cửa khẩu theo bxg_ id. Dùng khi đọc lại một tuyến đã lưu: routing.route_legs
// chỉ giữ crossing_id, phần còn lại nằm ở đây.
func ByID(crossingID string) (Crossing, bool) {
	c, ok := byID[crossingID]
	return c, ok
}

// Transits liệt kê các nước có thể làm điểm trung chuyển giữa from và to, tức những nước mà
// danh mục có cả cạnh from→X lẫn X→to. Đây là toàn bộ "đồ thị" mà routing-service cần: hành
// lang thật sự dài hơn hai chặng thì bộ giải chặng mới lo, không phải bảng này.
func Transits(from, to string) []string {
	seen := map[string]bool{}
	var out []string
	for _, c := range catalogue {
		if c.FromCountry != strings.ToUpper(from) {
			continue
		}
		mid := c.ToCountry
		if mid == strings.ToUpper(to) || seen[mid] {
			continue
		}
		if len(byPair[pairKey(mid, to)]) > 0 {
			seen[mid] = true
			out = append(out, mid)
		}
	}
	sort.Strings(out)
	return out
}

// ExpectedDwell ước lượng thời gian chờ ở cửa khẩu tại một thời điểm. Cửa khẩu không mở 24 giờ
// thì một xe tới lúc 22:00 phải đợi tới 06:00, và đó là khác biệt lớn nhất giữa ETA đúng và ETA
// sai vài tiếng đồng hồ.
func ExpectedDwell(c Crossing, arrival time.Time) time.Duration {
	dwell := time.Duration(c.AvgDwellMinutes) * time.Minute
	if c.Open24h {
		return dwell
	}
	const (
		openHour  = 6
		closeHour = 22
	)
	h := arrival.UTC().Hour()
	switch {
	case h >= openHour && h < closeHour:
		return dwell
	case h >= closeHour:
		return dwell + time.Duration(24-h+openHour)*time.Hour
	default:
		return dwell + time.Duration(openHour-h)*time.Hour
	}
}

// Validate kiểm tra tính nhất quán của chính danh mục. cmd/routingd gọi nó lúc khởi động: một
// bản chụp hỏng phải làm pod không lên được, chứ không phải làm một tuyến lẻ ghi hỏng lúc 3 giờ sáng.
func Validate() error {
	seen := map[string]bool{}
	for _, c := range catalogue {
		if c.FromCountry == c.ToCountry {
			return fmt.Errorf("cửa khẩu %s có from_country trùng to_country (%s)", c.CrossingID, c.FromCountry)
		}
		if len(c.UNLOCODE) != 5 {
			return fmt.Errorf("cửa khẩu %s có UN/LOCODE %q không đủ năm ký tự", c.CrossingID, c.UNLOCODE)
		}
		if len(c.ModesAllowed) == 0 {
			return fmt.Errorf("cửa khẩu %s không cho phép phương thức nào", c.CrossingID)
		}
		key := c.FromCountry + ">" + c.ToCountry + ">" + c.UNLOCODE
		if seen[key] {
			return fmt.Errorf("trùng lặp (from_country, to_country, unlocode) tại %s", c.CrossingID)
		}
		seen[key] = true
	}
	return nil
}

func allows(c Crossing, mode string) bool {
	for _, m := range c.ModesAllowed {
		if m == mode {
			return true
		}
	}
	return false
}

func pairKey(from, to string) string {
	return strings.ToUpper(from) + ">" + strings.ToUpper(to)
}
