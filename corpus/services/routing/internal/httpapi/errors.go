// Phong bì lỗi §0.4 và bảng ánh xạ từ lỗi trong nước sang mã lỗi công khai. Trường code là một
// phần của hợp đồng: web console và partner-portal-api rẽ nhánh theo nó, nên đổi một chuỗi ở
// bảng dưới đây là thay đổi API, không phải sửa câu chữ.

package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/orbitalfreight/platform/services/routing/internal/planner"
)

// errorBody là thân JSON trả về, giống hệt mọi dịch vụ khác trong nền tảng.
type errorBody struct {
	Error struct {
		Code       string      `json:"code"`
		HTTPStatus int         `json:"http_status"`
		Message    string      `json:"message"`
		TraceID    string      `json:"trace_id"`
		Retryable  bool        `json:"retryable"`
		Fields     []fieldFault `json:"fields,omitempty"`
	} `json:"error"`
}

// fieldFault chỉ đúng chỗ sai trong thân yêu cầu, dùng đường dẫn kiểu JSON pointer rút gọn
// ("legs[0].crossing_id") như phần còn lại của nền tảng.
type fieldFault struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// apiError là lỗi đã được gán mã. Handler dựng nó rồi giao cho writeError.
type apiError struct {
	code      string
	status    int
	message   string
	retryable bool
	fields    []fieldFault
	cause     error
}

func (e *apiError) Error() string { return e.code + ": " + e.message }
func (e *apiError) Unwrap() error { return e.cause }

// errorTable ánh xạ lỗi của package planner sang mã công khai. Bảng thay cho chuỗi if lồng nhau
// để thêm một lỗi mới là thêm một dòng, và để không ai lỡ tay trả 500 cho một tình huống bình thường.
var errorTable = []struct {
	match     error
	code      string
	status    int
	retryable bool
}{
	{planner.ErrRouteNotFound, "route_not_found", http.StatusNotFound, false},
	{planner.ErrCooldownActive, "replan_cooldown_active", http.StatusConflict, true},
	{planner.ErrTooManyLegs, "route_too_many_legs", http.StatusUnprocessableEntity, false},
	{planner.ErrFacilityUnknown, "facility_descriptor_required", http.StatusBadRequest, false},
	{planner.ErrNoCorridor, "no_customs_corridor", http.StatusUnprocessableEntity, false},
}

// classify tìm mã phù hợp cho một lỗi. Không khớp dòng nào thì là 500 và không cho thử lại tự
// động: một lỗi chưa từng được phân loại thì chưa ai biết thử lại có an toàn không.
func classify(err error) *apiError {
	var api *apiError
	if errors.As(err, &api) {
		return api
	}
	for _, row := range errorTable {
		if errors.Is(err, row.match) {
			return &apiError{
				code:      row.code,
				status:    row.status,
				message:   err.Error(),
				retryable: row.retryable,
				cause:     err,
			}
		}
	}
	return &apiError{
		code:    "internal_error",
		status:  http.StatusInternalServerError,
		message: "yêu cầu không xử lý được",
		cause:   err,
	}
}

// badRequest dựng lỗi 400 kèm danh sách trường sai.
func badRequest(code, message string, fields ...fieldFault) *apiError {
	return &apiError{code: code, status: http.StatusBadRequest, message: message, fields: fields}
}

// writeError trả phong bì §0.4. Thông điệp gốc chỉ vào log; ra ngoài là bản đã phân loại, để
// một lỗi Postgres không kéo theo tên bảng và tên cột ra ngoài biên dịch vụ.
func writeError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	api := classify(err)
	traceID := traceIDFrom(r.Context())

	if api.status >= 500 {
		log.Error("yêu cầu thất bại",
			"path", r.URL.Path, "code", api.code, "trace_id", traceID, "error", err)
	} else {
		log.Info("yêu cầu bị từ chối",
			"path", r.URL.Path, "code", api.code, "status", api.status, "trace_id", traceID)
	}

	var body errorBody
	body.Error.Code = api.code
	body.Error.HTTPStatus = api.status
	body.Error.Message = api.message
	body.Error.TraceID = traceID
	body.Error.Retryable = api.retryable
	body.Error.Fields = api.fields

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(api.status)
	_ = json.NewEncoder(w).Encode(body)
}

// writeJSON trả một thân JSON thành công.
func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

// page là hình dạng trả về của mọi danh sách trong nền tảng: phân trang bằng con trỏ, không
// bao giờ bằng offset (§0.5).
type page[T any] struct {
	Items      []T     `json:"items"`
	NextCursor *string `json:"next_cursor"`
}
