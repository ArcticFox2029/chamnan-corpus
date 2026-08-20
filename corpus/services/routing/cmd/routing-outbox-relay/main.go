// Command routing-outbox-relay đọc những dòng platform.outbox_messages do routing-service ghi
// và đẩy chúng lên of.platform.v1. Chạy tách khỏi routingd để một Kafka chậm không kéo theo API
// chậm, và vì đây là tiến trình duy nhất trong dịch vụ được phép nói chuyện với Kafka theo
// chiều ghi — §7 quy tắc 3 nói rõ không handler nào tự publish.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/segmentio/kafka-go"

	"github.com/orbitalfreight/platform/services/routing/internal/config"
	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/store"
)

// batchSize là số message đọc mỗi vòng. routing-service phát rất ít sự kiện — chỉ
// route.replanned — nên một lô nhỏ là đủ và giữ giao dịch FOR UPDATE SKIP LOCKED ngắn.
const batchSize = 128

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "relay dừng vì lỗi:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})).
		With("service", cfg.ServiceName, "component", "outbox-relay", "region_code", cfg.RegionCode)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("mở pool Postgres: %w", err)
	}
	defer pool.Close()

	outbox := store.NewOutbox(pool, cfg.RegionCode)

	writer := &kafka.Writer{
		Addr:  kafka.TCP(cfg.KafkaBrokers...),
		Topic: domain.TopicPlatform,
		// Balancer băm theo Key, và Key là partition_key của phong bì. Đây là thứ giữ đúng thứ
		// tự hai lần lập lại tuyến của cùng một lô hàng — bảo đảm duy nhất mà §4 đưa ra.
		Balancer:     &kafka.Hash{},
		RequiredAcks: kafka.RequireAll,
		Compression:  kafka.Snappy,
		BatchTimeout: 50 * time.Millisecond,
	}
	defer writer.Close()

	dlq := &kafka.Writer{
		Addr:         kafka.TCP(cfg.KafkaBrokers...),
		Topic:        domain.TopicPlatform + ".dlq",
		Balancer:     &kafka.Hash{},
		RequiredAcks: kafka.RequireAll,
	}
	defer dlq.Close()

	log.Info("relay bắt đầu", "topic", domain.TopicPlatform, "interval", cfg.OutboxRelayInterval)

	ticker := time.NewTicker(cfg.OutboxRelayInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Info("relay dừng theo tín hiệu")
			return nil
		case <-ticker.C:
			n, err := drain(ctx, outbox, writer, dlq, log)
			if err != nil {
				log.Error("một vòng đẩy thất bại", "error", err)
				continue
			}
			if n > 0 {
				log.Info("đã đẩy sự kiện", "count", n)
			}
		}
	}
}

// drain đẩy một lô message và trả về số message đã đẩy thành công.
func drain(ctx context.Context, outbox *store.Outbox, writer, dlq *kafka.Writer, log *slog.Logger) (int, error) {
	pending, err := outbox.FetchPending(ctx, batchSize)
	if err != nil {
		return 0, err
	}
	if len(pending) == 0 {
		return 0, nil
	}

	published := make([]string, 0, len(pending))
	for _, m := range pending {
		tenantID, traceID := metadataOf(m)
		env := outbox.Envelope(m, tenantID, traceID)

		body, err := json.Marshal(env)
		if err != nil {
			// Payload không đóng gói được thì thử lại bao nhiêu lần cũng vậy — đẩy thẳng vào DLQ.
			if dlqErr := toDLQ(ctx, dlq, m, err); dlqErr != nil {
				log.Error("không đẩy được vào DLQ", "message_id", m.MessageID, "error", dlqErr)
			}
			continue
		}

		err = writer.WriteMessages(ctx, kafka.Message{
			Key:   []byte(env.PartitionKey),
			Value: body,
			Headers: []kafka.Header{
				{Key: "event_name", Value: []byte(env.EventName)},
				{Key: "producer", Value: []byte(env.Producer)},
				{Key: "trace_id", Value: []byte(env.TraceID)},
			},
		})
		if err == nil {
			published = append(published, m.MessageID)
			continue
		}

		if markErr := outbox.MarkFailed(ctx, m.MessageID, err); markErr != nil {
			log.Error("không ghi được lỗi vào outbox", "message_id", m.MessageID, "error", markErr)
		}
		if m.Attempts+1 >= store.MaxAttempts {
			// Tám lần là ngưỡng ở §4.19 quy tắc 4; sau đó message sang DLQ và người trực ca xử lý.
			if dlqErr := toDLQ(ctx, dlq, m, err); dlqErr != nil {
				log.Error("không đẩy được vào DLQ", "message_id", m.MessageID, "error", dlqErr)
			}
			continue
		}
		// Nghỉ theo hàm mũ trước message kế tiếp; Kafka đang có vấn đề thì cả lô cũng vậy.
		select {
		case <-ctx.Done():
			return len(published), ctx.Err()
		case <-time.After(store.BackoffFor(m.Attempts)):
		}
	}

	if len(published) > 0 {
		// Đánh dấu sau khi Kafka đã nhận. Đẩy trùng thì consumer tự khử theo event_id, còn đánh
		// dấu trước rồi Kafka hỏng là mất sự kiện vĩnh viễn.
		if err := outbox.MarkPublished(ctx, published); err != nil {
			return len(published), err
		}
	}
	return len(published), nil
}

// metadataOf moi tenant_id và trace_id ra khỏi payload. Bảng platform.outbox_messages không có
// hai cột đó, còn phong bì §0.7 thì bắt buộc phải có — với route.replanned thì tenant nằm trong
// chính payload vì bộ lập tuyến ghi nó xuống lúc dựng sự kiện.
func metadataOf(m store.PendingMessage) (tenantID, traceID string) {
	var probe struct {
		TenantID string `json:"tenant_id"`
		TraceID  string `json:"trace_id"`
	}
	if err := json.Unmarshal(m.Payload, &probe); err != nil {
		return "", ""
	}
	return probe.TenantID, probe.TraceID
}

// toDLQ chuyển một message hỏng sang of.platform.v1.dlq kèm lý do, giữ nguyên payload gốc để
// còn phát lại được sau khi sửa.
func toDLQ(ctx context.Context, dlq *kafka.Writer, m store.PendingMessage, cause error) error {
	if dlq == nil {
		return errors.New("chưa cấu hình writer cho DLQ")
	}
	wrapper := map[string]any{
		"message_id":   m.MessageID,
		"event_name":   m.EventName,
		"producer":     "routing-service",
		"attempts":     m.Attempts + 1,
		"failed_at":    time.Now().UTC(),
		"failed_reason": cause.Error(),
		"payload":      m.Payload,
	}
	body, err := json.Marshal(wrapper)
	if err != nil {
		return err
	}
	return dlq.WriteMessages(ctx, kafka.Message{Key: []byte(m.PartitionKey), Value: body})
}
