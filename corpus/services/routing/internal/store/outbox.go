// Ghi sự kiện vào platform.outbox_messages trong cùng giao dịch với thay đổi trạng thái, và
// đọc chúng ra cho relay. routing-service phát đúng một loại sự kiện — route.replanned trên
// of.platform.v1 — nhưng vẫn dùng đủ cơ chế outbox, vì §7 quy tắc 3 không có ngoại lệ cho
// dịch vụ nào phát ít sự kiện.

package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/ids"
)

// producerName phải trùng từng ký tự với tên dịch vụ ở §1; cột producer là thứ mà relay lọc
// theo, nên viết sai một chữ là outbox không bao giờ được đẩy đi.
const producerName = "routing-service"

// EnqueueRouteReplanned đặt một sự kiện route.replanned vào outbox. Nhận pgx.Tx chứ không nhận
// pool: gọi được hàm này ngoài giao dịch nghĩa là đã phá vỡ chính bảo đảm mà outbox tồn tại để giữ.
func EnqueueRouteReplanned(ctx context.Context, tx pgx.Tx, route *domain.Route, ev domain.RouteReplanned) error {
	payload, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("đóng gói payload route.replanned: %w", err)
	}
	version, err := domain.SchemaVersionFor(domain.EventRouteReplanned)
	if err != nil {
		return err
	}

	_, err = tx.Exec(ctx, `
        INSERT INTO platform.outbox_messages
            (message_id, producer, aggregate_type, aggregate_id, event_name, topic,
             partition_key, schema_version, payload)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		ids.NewEvent(),
		producerName,
		"route",
		route.RouteID,
		domain.EventRouteReplanned,
		domain.TopicPlatform,
		// Khoá phân vùng là shipment_id chứ không phải route_id: §4 chỉ bảo đảm thứ tự theo lô
		// hàng, và fleet-service cần thấy hai lần lập lại tuyến của cùng một lô đúng thứ tự.
		route.ShipmentID,
		version,
		payload,
	)
	if err != nil {
		return fmt.Errorf("ghi outbox cho tuyến %s: %w", route.RouteID, err)
	}
	return nil
}

// PendingMessage là một dòng outbox chưa được đẩy đi, kèm đủ dữ liệu để dựng phong bì §0.7.
type PendingMessage struct {
	MessageID     string
	EventName     string
	Topic         string
	PartitionKey  string
	SchemaVersion int
	AggregateID   string
	Payload       json.RawMessage
	CreatedAt     time.Time
	Attempts      int
}

// Outbox phục vụ tiến trình relay ở cmd/routing-outbox-relay.
type Outbox struct {
	pool       *pgxpool.Pool
	regionCode string
}

// NewOutbox dựng cổng truy cập outbox. regionCode được đóng dấu vào từng phong bì và phải là
// OF_REGION_CODE của chính pod đang chạy — không phải vùng của lô hàng, vì §7 quy tắc 7 chỉ cho
// phép dữ liệu của một vùng được xử lý trong vùng đó.
func NewOutbox(pool *pgxpool.Pool, regionCode string) *Outbox {
	return &Outbox{pool: pool, regionCode: regionCode}
}

// FetchPending lấy một lô message chưa đẩy. FOR UPDATE SKIP LOCKED cho phép chạy nhiều bản sao
// relay cùng lúc mà không bản nào đẩy trùng message của bản khác.
func (o *Outbox) FetchPending(ctx context.Context, limit int) ([]PendingMessage, error) {
	rows, err := o.pool.Query(ctx, `
        SELECT message_id, event_name, topic, partition_key, schema_version,
               aggregate_id, payload, created_at, attempts
          FROM platform.outbox_messages
         WHERE producer = $1 AND published_at IS NULL
         ORDER BY created_at
         LIMIT $2
           FOR UPDATE SKIP LOCKED`, producerName, limit)
	if err != nil {
		return nil, fmt.Errorf("đọc outbox: %w", err)
	}
	defer rows.Close()

	var out []PendingMessage
	for rows.Next() {
		var m PendingMessage
		if err := rows.Scan(&m.MessageID, &m.EventName, &m.Topic, &m.PartitionKey,
			&m.SchemaVersion, &m.AggregateID, &m.Payload, &m.CreatedAt, &m.Attempts); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Envelope dựng phong bì §0.7 quanh một message outbox. tenantID không nằm trong bảng outbox
// nên relay phải nhận từ chỗ gọi; với route.replanned thì nó lấy từ chính payload.
func (o *Outbox) Envelope(m PendingMessage, tenantID, traceID string) domain.Envelope {
	return domain.Envelope{
		EventID:       m.MessageID,
		EventName:     m.EventName,
		SchemaVersion: m.SchemaVersion,
		OccurredAt:    m.CreatedAt.UTC(),
		TenantID:      tenantID,
		RegionCode:    o.regionCode,
		Producer:      producerName,
		TraceID:       traceID,
		PartitionKey:  m.PartitionKey,
		Payload:       m.Payload,
	}
}

// MarkPublished đóng dấu published_at sau khi Kafka đã nhận. Chạy sau lời gọi Kafka chứ không
// trước: đẩy trùng một message thì consumer tự khử theo event_id (§4.19 quy tắc 1), còn đánh
// dấu sớm rồi Kafka hỏng thì sự kiện mất hẳn.
func (o *Outbox) MarkPublished(ctx context.Context, messageIDs []string) error {
	_, err := o.pool.Exec(ctx, `
        UPDATE platform.outbox_messages
           SET published_at = now()
         WHERE message_id = ANY($1)`, messageIDs)
	if err != nil {
		return fmt.Errorf("đánh dấu đã đẩy %d message: %w", len(messageIDs), err)
	}
	return nil
}

// MarkFailed tăng attempts và ghi lỗi cuối. Sau tám lần, relay chuyển message sang
// of.platform.v1.dlq theo §4.19 quy tắc 4 thay vì thử mãi.
func (o *Outbox) MarkFailed(ctx context.Context, messageID string, cause error) error {
	_, err := o.pool.Exec(ctx, `
        UPDATE platform.outbox_messages
           SET attempts = attempts + 1,
               last_error = $2
         WHERE message_id = $1`, messageID, cause.Error())
	return err
}

// MaxAttempts là ngưỡng ở §4.19 quy tắc 4.
const MaxAttempts = 8

// BackoffFor tính thời gian chờ trước lần thử lại kế tiếp: bắt đầu ở 500 ms và nhân đôi.
func BackoffFor(attempts int) time.Duration {
	d := 500 * time.Millisecond
	for i := 0; i < attempts && d < 2*time.Minute; i++ {
		d *= 2
	}
	return d
}
