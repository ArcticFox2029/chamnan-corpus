// Client HTTP tới customs-service. routing-service hỏi ở đây đúng hai thứ: thuế suất của một
// hành lang (để chiến lược customs_optimised có cái mà so) và trạng thái tờ khai của một lô
// hàng (để biết chặng qua biên giới có đang bị giữ hay không). Chiều ngược lại không tồn tại —
// customs-service không bao giờ gọi routing-service.

package upstream

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Customs là bề mặt customs-service mà planner dùng. Giữ ở dạng interface để phần chấm điểm
// hành lang chạy được với dữ liệu cố định trong test, và để một sự cố của customs-service
// biến thành "thiếu thông tin thuế" chứ không thành "không lập được tuyến".
type Customs interface {
	LookupTariff(ctx context.Context, q TariffQuery) (*Tariff, error)
	GetDeclaration(ctx context.Context, declarationID string) (*Declaration, error)
	DeclarationsForShipment(ctx context.Context, shipmentID string) ([]Declaration, error)
}

// TariffQuery là bộ tham số của GET /v1/tariffs/lookup. OnDate quan trọng: customs.tariff_schedules
// là bảng theo thời gian, một tờ khai nộp hôm qua vẫn phải tính theo thuế suất của hôm qua.
type TariffQuery struct {
	HSCode             string
	DestinationCountry string
	OriginCountry      string
	OnDate             time.Time
}

// Tariff là một dòng customs.tariff_schedules đã được customs-service phân giải. Thuế suất là
// điểm cơ bản (§0.2): 1250 nghĩa là 12,50 %, và không bao giờ là số thực.
type Tariff struct {
	TariffID           string `json:"tariff_id"`
	HSCode             string `json:"hs_code"`
	DestinationCountry string `json:"destination_country"`
	OriginCountry      string `json:"origin_country"`
	DutyRateBP         int32  `json:"duty_rate_bp"`
	VATRateBP          int32  `json:"vat_rate_bp"`
	PreferentialScheme string `json:"preferential_scheme"`
}

// Declaration là bản rút gọn của customs.customs_declarations. DutyPaid chỉ có thể do
// customs-service đặt sau khi nó tiêu thụ billing.invoice.settled; routing-service đọc, không suy diễn.
type Declaration struct {
	DeclarationID     string     `json:"declaration_id"`
	ShipmentID        string     `json:"shipment_id"`
	CrossingID        string     `json:"crossing_id"`
	CustomsOfficeCode string     `json:"customs_office_code"`
	Direction         string     `json:"direction"` // import | export | transit
	Status            string     `json:"status"`
	MRN               string     `json:"mrn"`
	AssessedDutyMinor int64      `json:"assessed_duty_minor"`
	AssessedVATMinor  int64      `json:"assessed_vat_minor"`
	Currency          string     `json:"currency"`
	DutyPaid          bool       `json:"duty_paid"`
	ClearedAt         *time.Time `json:"cleared_at"`
}

// IsBlocking cho biết tờ khai này có đang chặn lô hàng đi tiếp hay không. held và rejected là
// hai trạng thái duy nhất khiến planner phải cân nhắc đổi cửa khẩu.
func (d Declaration) IsBlocking() bool {
	return d.Status == "held" || d.Status == "rejected"
}

// CustomsClient nói chuyện với customs-service qua OF_CUSTOMS_BASE_URL.
type CustomsClient struct {
	baseURL string
	http    *http.Client
	tokens  ServiceTokenSource
}

// ServiceTokenSource cấp token kiểu service để gọi ra ngoài. customs-service vẫn introspect
// token đó với identity-service như với mọi lời gọi khác.
type ServiceTokenSource interface {
	Token(ctx context.Context) (string, error)
}

// NewCustomsClient dựng client. Thời gian chờ để ngắn có chủ ý: bảng thuế hầu như luôn nằm
// trong cache của customs-service (OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS đặt dài được vì các dòng
// customs.tariff_schedules là bất biến), nên một lời gọi chậm nghĩa là có sự cố thật.
func NewCustomsClient(baseURL string, tokens ServiceTokenSource) *CustomsClient {
	return &CustomsClient{
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    &http.Client{Timeout: 1500 * time.Millisecond},
		tokens:  tokens,
	}
}

// LookupTariff gọi GET /v1/tariffs/lookup.
func (c *CustomsClient) LookupTariff(ctx context.Context, q TariffQuery) (*Tariff, error) {
	params := url.Values{}
	params.Set("hs_code", q.HSCode)
	params.Set("destination_country", q.DestinationCountry)
	if q.OriginCountry != "" {
		params.Set("origin_country", q.OriginCountry)
	}
	// Ngày không có giờ thì đi ở dạng YYYY-MM-DD, theo quy ước hậu tố _on ở §0.2.
	params.Set("on_date", q.OnDate.UTC().Format("2006-01-02"))

	var out Tariff
	if err := c.get(ctx, "/v1/tariffs/lookup?"+params.Encode(), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// GetDeclaration gọi GET /v1/declarations/{declaration_id}.
func (c *CustomsClient) GetDeclaration(ctx context.Context, declarationID string) (*Declaration, error) {
	var out Declaration
	if err := c.get(ctx, "/v1/declarations/"+url.PathEscape(declarationID), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// DeclarationsForShipment gọi GET /v1/shipments/{shipment_id}/declarations. Một lô hàng qua ba
// biên giới thì có ba tờ khai, mỗi tờ gắn một crossing_id khác nhau.
func (c *CustomsClient) DeclarationsForShipment(ctx context.Context, shipmentID string) ([]Declaration, error) {
	var out struct {
		Items      []Declaration `json:"items"`
		NextCursor *string       `json:"next_cursor"`
	}
	path := "/v1/shipments/" + url.PathEscape(shipmentID) + "/declarations"
	if err := c.get(ctx, path, &out); err != nil {
		return nil, err
	}
	// Phân trang bằng con trỏ (§0.5). Một lô hàng có nhiều hơn 50 tờ khai là chuyện bất thường
	// nhưng có thật với hàng quá cảnh nhiều chặng, nên vẫn đi hết các trang.
	items := out.Items
	for out.NextCursor != nil {
		next := path + "?cursor=" + url.QueryEscape(*out.NextCursor)
		out.NextCursor = nil
		if err := c.get(ctx, next, &out); err != nil {
			return items, err
		}
		items = append(items, out.Items...)
	}
	return items, nil
}

func (c *CustomsClient) get(ctx context.Context, path string, dst any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return err
	}
	token, err := c.tokens.Token(ctx)
	if err != nil {
		return fmt.Errorf("không lấy được token gọi customs-service: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-OF-Actor-Kind", "service")
	req.Header.Set("Accept", "application/json")
	if id := TraceID(ctx); id != "" {
		req.Header.Set("X-OF-Trace-Id", id)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("customs-service %s: %w", path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// customs-service trả đúng phong bì lỗi ở §0.4; giữ nguyên code để tầng trên quyết định
		// có thử lại hay không thay vì đoán theo mã HTTP.
		var envelope struct {
			Error struct {
				Code      string `json:"code"`
				Message   string `json:"message"`
				Retryable bool   `json:"retryable"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&envelope)
		return fmt.Errorf("customs-service %s trả %d (%s): %s",
			path, resp.StatusCode, envelope.Error.Code, envelope.Error.Message)
	}
	return json.NewDecoder(resp.Body).Decode(dst)
}
