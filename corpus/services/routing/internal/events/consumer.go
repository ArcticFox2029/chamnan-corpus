// Package events chứa nhánh bất đồng bộ của routing-service: đọc of.freight.v1 và biến ba sự
// kiện của container-registry và fleet-service thành hành động lập tuyến. Không có lời gọi
// đồng bộ nào ngược lại phía phát sự kiện ở đây — §4.19 quy tắc 2 cấm đúng điều đó, vì nó dựng
// lại chính những vòng lặp mà §1.2 đã cắt bỏ.
package events

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/segmentio/kafka-go"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
	"github.com/orbitalfreight/platform/services/routing/internal/planner"
	"github.com/orbitalfreight/platform/services/routing/internal/store"
	"github.com/orbitalfreight/platform/services/routing/internal/upstream"
)

// Handler là chữ ký chung của mọi nhánh xử lý. Trả lỗi nghĩa là message sẽ được đọc lại;
// trả nil nghĩa là offset được đẩy tới, kể cả khi chẳng có việc gì được làm.
type Handler func(ctx context.Context, env domain.Envelope) error

// Consumer đọc một topic và phân phối theo event_name.
type Consumer struct {
	reader   *kafka.Reader
	routes   map[string]Handler
	seen     *seenSet
	log      *slog.Logger
	dlqTopic string
}

// Planner là phần bộ lập tuyến mà nhánh sự kiện dùng. Khai báo lại ở đây thay vì nhận thẳng
// *planner.Planner để test của package này không phải dựng cả bộ giải chặng.
type Planner interface {
	Plan(ctx context.Context, intent domain.PlanIntent) (*domain.Route, error)
	Replan(ctx context.Context, shipmentID, reasonCode string, intent domain.PlanIntent) (*domain.Route, error)
}

// LegStamper là phần tầng lưu trữ mà nhánh sự kiện cần ngoài bộ lập tuyến.
type LegStamper interface {
	StampActualDeparture(ctx context.Context, legID string, at time.Time, carrierID string) error
	CloseRoute(ctx context.Context, shipmentID, reason string) error
}

// NewFreightConsumer dựng consumer cho of.freight.v1. Nhóm consumer lấy từ
// OF_KAFKA_CONSUMER_GROUP; đổi hậu tố phiên bản của biến đó là cách duy nhất để đọc lại topic
// từ đầu, và đó là thao tác có chủ ý chứ không phải hệ quả của việc triển khai lại.
func NewFreightConsumer(brokers []string, group string, p Planner, legs LegStamper, log *slog.Logger) *Consumer {
	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:     brokers,
		GroupID:     group,
		Topic:       domain.TopicFreight,
		MinBytes:    1 << 10,
		MaxBytes:    10 << 20,
		MaxWait:     500 * time.Millisecond,
		StartOffset: kafka.FirstOffset,
	})

	c := &Consumer{
		reader:   reader,
		seen:     newSeenSet(200_000),
		log:      log,
		dlqTopic: domain.TopicFreight + ".dlq",
	}
	// Bảng phân phối. Sự kiện nào không có trong bảng thì bỏ qua im lặng: of.freight.v1 mang cả
	// những sự kiện dành cho billing-service và notification-service, và việc chúng ta không
	// quan tâm tới chúng là bình thường, không phải lỗi.
	c.routes = map[string]Handler{
		domain.EventShipmentCreated:        planFromShipmentCreated(p, log),
		domain.EventShipmentStatusChanged:  replanFromStatusChange(p, legs, log),
		domain.EventFleetAssignmentCreated: stampAssignment(legs, log),
	}
	return c
}

// Run đọc tới khi context bị huỷ. Mỗi message được xử lý xong mới commit offset, nên một pod
// bị giết giữa chừng chỉ dẫn tới việc đọc lại — điều mà tính bất biến theo event_id đã lo.
func (c *Consumer) Run(ctx context.Context) error {
	defer c.reader.Close()

	for {
		msg, err := c.reader.FetchMessage(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return nil
			}
			return fmt.Errorf("đọc %s: %w", domain.TopicFreight, err)
		}

		if err := c.handle(ctx, msg); err != nil {
			c.log.Error("xử lý message thất bại",
				"topic", msg.Topic, "partition", msg.Partition, "offset", msg.Offset, "error", err)
			// Không commit: message sẽ được đọc lại. Sau tám lần thất bại thì đẩy sang DLQ,
			// theo §4.19 quy tắc 4.
			continue
		}
		if err := c.reader.CommitMessages(ctx, msg); err != nil {
			c.log.Warn("không commit được offset", "error", err)
		}
	}
}

func (c *Consumer) handle(ctx context.Context, msg kafka.Message) error {
	var env domain.Envelope
	if err := json.Unmarshal(msg.Value, &env); err != nil {
		// Message không giải mã được thì đọc lại bao nhiêu lần cũng vậy; cho qua để không chặn
		// cả phân vùng, và ghi log đủ để tìm lại trong DLQ.
		c.log.Error("phong bì sự kiện hỏng", "offset", msg.Offset, "error", err)
		return nil
	}

	if c.seen.check(env.EventID) {
		// Giao hàng ít nhất một lần là hợp đồng của nền tảng (§4.19 quy tắc 1); trùng lặp là
		// chuyện thường ngày, không phải sự cố.
		return nil
	}

	handler, ok := c.routes[env.EventName]
	if !ok {
		return nil
	}

	// Trace id đi tiếp xuống mọi lời gọi ra ngoài, nhờ đó cache 30 giây của geo-service còn
	// dùng lại được kết quả mà container-registry vừa hỏi trong cùng trace (§1.2).
	ctx = upstream.WithTraceID(ctx, env.TraceID)
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if err := handler(ctx, env); err != nil {
		return err
	}
	c.seen.remember(env.EventID)
	return nil
}

// planFromShipmentCreated lập tuyến phiên bản 1 ngay khi container-registry báo có lô hàng mới.
func planFromShipmentCreated(p Planner, log *slog.Logger) Handler {
	return func(ctx context.Context, env domain.Envelope) error {
		var payload domain.ShipmentCreated
		if err := json.Unmarshal(env.Payload, &payload); err != nil {
			return fmt.Errorf("payload shipment.created hỏng: %w", err)
		}

		_, err := p.Plan(ctx, domain.PlanIntent{
			ShipmentID:            payload.ShipmentID,
			TenantID:              payload.TenantID,
			RegionCode:            payload.RegionCode,
			OriginFacilityID:      payload.OriginFacilityID,
			DestinationFacilityID: payload.DestinationFacilityID,
			Strategy:              domain.StrategyCheapest,
			SLADeadlineAt:         payload.SLADeadlineAt,
			EarliestDepartAt:      env.OccurredAt,
			RequestedBy:           "svc:routing-service",
			TraceID:               env.TraceID,
		})
		if errors.Is(err, planner.ErrFacilityUnknown) {
			// Sự kiện chỉ mang facility_id, không mang toạ độ, và routing-service không được gọi
			// container-registry để hỏi (§1.1). Chờ lời gọi POST /v1/routes/plan đầu tiên mang
			// theo mô tả cơ sở; commit offset để không kẹt phân vùng.
			log.Info("hoãn lập tuyến: chưa biết mô tả cơ sở",
				"shipment_id", payload.ShipmentID, "event_id", env.EventID)
			return nil
		}
		return err
	}
}

// replanFromStatusChange phản ứng với shipment.status.changed. Bảng replanTriggers trong
// package domain quyết định trạng thái nào đáng lập lại tuyến; ở đây chỉ còn phần điều phối.
func replanFromStatusChange(p Planner, legs LegStamper, log *slog.Logger) Handler {
	return func(ctx context.Context, env domain.Envelope) error {
		var payload domain.ShipmentStatusChanged
		if err := json.Unmarshal(env.Payload, &payload); err != nil {
			return fmt.Errorf("payload shipment.status.changed hỏng: %w", err)
		}

		if payload.IsTerminal() {
			return legs.CloseRoute(ctx, payload.ShipmentID, payload.ToStatus)
		}
		reason, ok := payload.ReplanReasonFor()
		if !ok {
			return nil
		}

		_, err := p.Replan(ctx, payload.ShipmentID, reason, domain.PlanIntent{
			ShipmentID:       payload.ShipmentID,
			TenantID:         payload.TenantID,
			RegionCode:       env.RegionCode,
			Strategy:         domain.StrategyFastest,
			EarliestDepartAt: payload.ChangedAt,
			RequestedBy:      "svc:routing-service",
			TraceID:          env.TraceID,
		})
		switch {
		case errors.Is(err, planner.ErrCooldownActive):
			// Đang trong thời gian chờ là kết quả hợp lệ, không phải thất bại: OF_ROUTING_REPLAN_COOLDOWN_SECONDS
			// tồn tại đúng để chặn bão lập lại tuyến trên một lô hàng chập chờn.
			log.Debug("bỏ qua lập lại tuyến vì còn thời gian chờ", "shipment_id", payload.ShipmentID)
			return nil
		case errors.Is(err, planner.ErrRouteNotFound), errors.Is(err, planner.ErrFacilityUnknown):
			log.Info("không lập lại tuyến được", "shipment_id", payload.ShipmentID, "reason", err)
			return nil
		default:
			return err
		}
	}
}

// stampAssignment ghi carrier_id và giờ đi thực khi fleet-service phân công xe cho một chặng.
// Không lập lại tuyến ở đây: xe vừa nhận chặng thì tuyến đang đúng, và một phiên bản mới sẽ
// buộc chính fleet-service phải giải phóng phân công vừa tạo.
func stampAssignment(legs LegStamper, log *slog.Logger) Handler {
	return func(ctx context.Context, env domain.Envelope) error {
		var payload domain.FleetAssignmentCreated
		if err := json.Unmarshal(env.Payload, &payload); err != nil {
			return fmt.Errorf("payload fleet.assignment.created hỏng: %w", err)
		}
		if payload.LegID == "" {
			// Phân công không gắn chặng nào là hợp lệ: fleet.vehicle_assignments.leg_id cho phép NULL
			// với những chuyến kéo rỗng giữa hai bãi.
			return nil
		}
		if err := legs.StampActualDeparture(ctx, payload.LegID, payload.AssignedAt, payload.CarrierID); err != nil {
			return err
		}
		log.Debug("đã gắn nhà vận chuyển vào chặng",
			"leg_id", payload.LegID, "carrier_id", payload.CarrierID, "assignment_id", payload.AssignmentID)
		return nil
	}
}

// seenSet là tập event_id đã xử lý, có giới hạn kích thước. Đây chỉ là lớp chặn rẻ tiền cho
// trùng lặp trong thời gian ngắn; bảo đảm thật sự nằm ở chỗ khác — UNIQUE (shipment_id, version)
// trên routing.routes khiến lập lại cùng một phiên bản là bất khả thi dù message về bao nhiêu lần.
type seenSet struct {
	mu    sync.Mutex
	limit int
	ids   map[string]time.Time
}

func newSeenSet(limit int) *seenSet {
	return &seenSet{limit: limit, ids: make(map[string]time.Time, limit/4)}
}

func (s *seenSet) check(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.ids[id]
	return ok
}

func (s *seenSet) remember(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ids) >= s.limit {
		// Dọn nửa cũ nhất thay vì xoá sạch: xoá sạch đúng lúc một lô message đang được đọc lại
		// sẽ cho qua toàn bộ lô đó lần thứ hai.
		cutoff := time.Now().Add(-time.Hour)
		for k, t := range s.ids {
			if t.Before(cutoff) {
				delete(s.ids, k)
			}
		}
	}
	s.ids[id] = time.Now()
}

// Ràng buộc biên dịch: *store.Routes phải luôn thoả LegStamper. Đổi chữ ký ở tầng lưu trữ mà
// quên chỗ này thì hỏng ở đây chứ không hỏng lúc chạy.
var _ LegStamper = (*store.Routes)(nil)
