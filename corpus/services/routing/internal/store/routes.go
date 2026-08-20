// Package store là tầng duy nhất được chạm vào Postgres. Nó chỉ đọc và ghi hai bảng của schema
// routing — routing.routes và routing.route_legs — cộng với platform.outbox_messages ở tệp bên
// cạnh. Không có truy vấn nào ở đây đi qua schema của dịch vụ khác: §7 quy tắc 2 gọi một phép
// nối liên schema trong mã ứng dụng là lỗi, không phải là tối ưu hoá.
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/orbitalfreight/platform/services/routing/internal/domain"
)

// Routes hiện thực interface planner.Store.
type Routes struct {
	pool *pgxpool.Pool
}

// NewRoutes dựng tầng lưu trữ trên một pool đã mở từ OF_DATABASE_URL.
func NewRoutes(pool *pgxpool.Pool) *Routes {
	return &Routes{pool: pool}
}

const selectRouteColumns = `
    r.route_id, r.shipment_id, r.version, r.is_current, r.planned_by, r.strategy,
    r.total_distance_m, r.total_duration_s, r.computed_at, r.superseded_at`

const selectLegColumns = `
    l.leg_id, l.route_id, l.seq_no, l.mode, l.from_facility_id, l.to_facility_id,
    l.crossing_id, l.planned_depart_at, l.planned_arrive_at, l.actual_depart_at,
    l.actual_arrive_at, l.distance_m, l.carrier_id`

// CurrentRoute đọc phiên bản đang hiệu lực của một lô hàng. Điều kiện is_current dựa thẳng vào
// chỉ mục duy nhất routes_one_current_per_shipment, nên câu này không bao giờ trả về hai dòng.
func (s *Routes) CurrentRoute(ctx context.Context, shipmentID string) (*domain.Route, error) {
	row := s.pool.QueryRow(ctx, `
        SELECT `+selectRouteColumns+`
        FROM routing.routes r
        WHERE r.shipment_id = $1 AND r.is_current`, shipmentID)

	route, err := scanRoute(row)
	if errors.Is(err, pgx.ErrNoRows) {
		// Chưa có tuyến không phải là lỗi: lô hàng vừa được tạo xong là ở tình trạng này.
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("đọc tuyến hiện hành của %s: %w", shipmentID, err)
	}
	if err := s.loadLegs(ctx, route); err != nil {
		return nil, err
	}
	return route, nil
}

// RouteByID đọc một tuyến bất kỳ theo rte_ id, kể cả tuyến đã bị thay thế — GET /v1/routes/{route_id}
// phải trả được cả phiên bản cũ vì web console cho xem lại lịch sử lập tuyến.
func (s *Routes) RouteByID(ctx context.Context, routeID string) (*domain.Route, error) {
	row := s.pool.QueryRow(ctx, `
        SELECT `+selectRouteColumns+`
        FROM routing.routes r
        WHERE r.route_id = $1`, routeID)

	route, err := scanRoute(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("đọc tuyến %s: %w", routeID, err)
	}
	if err := s.loadLegs(ctx, route); err != nil {
		return nil, err
	}
	return route, nil
}

// InsertFirstVersion ghi tuyến phiên bản 1. Không phát sự kiện nào: §4 không có
// route.planned, và fleet-service biết tuyến đầu tiên qua chính lời gọi
// POST /v1/routes/plan mà nó vừa thực hiện.
func (s *Routes) InsertFirstVersion(ctx context.Context, r *domain.Route) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if err := insertRoute(ctx, tx, r); err != nil {
		return err
	}
	if err := insertLegs(ctx, tx, r); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SupersedeAndInsert đóng phiên bản cũ, ghi phiên bản mới và đặt route.replanned vào
// platform.outbox_messages — cả ba trong một giao dịch. Đây chính là chỗ §7 quy tắc 3 được
// tôn trọng: relay đọc outbox và đẩy lên of.platform.v1, không có ai publish từ handler.
func (s *Routes) SupersedeAndInsert(ctx context.Context, next *domain.Route, ev domain.RouteReplanned) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Hạ cờ is_current trước khi ghi dòng mới. Đảo thứ tự là vi phạm ngay chỉ mục duy nhất
	// routes_one_current_per_shipment, và Postgres sẽ từ chối cả giao dịch.
	cmd, err := tx.Exec(ctx, `
        UPDATE routing.routes
           SET is_current = false,
               superseded_at = now()
         WHERE shipment_id = $1 AND is_current`, next.ShipmentID)
	if err != nil {
		return fmt.Errorf("đóng phiên bản cũ của %s: %w", next.ShipmentID, err)
	}
	if cmd.RowsAffected() == 0 {
		return fmt.Errorf("lô hàng %s không có phiên bản nào đang hiệu lực để thay thế", next.ShipmentID)
	}

	if err := insertRoute(ctx, tx, next); err != nil {
		return err
	}
	if err := insertLegs(ctx, tx, next); err != nil {
		return err
	}
	if err := EnqueueRouteReplanned(ctx, tx, next, ev); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// CloseRoute đánh dấu tuyến hiện hành đã hết vòng đời khi lô hàng chuyển sang delivered hoặc
// cancelled. Không xoá dòng nào: analytics-pipeline đọc lại routing.routes qua vai trò
// of_analytics_ro để dựng analytics.mv_lane_performance_daily, và một tuyến biến mất là một
// tuyến hàng biến mất khỏi báo cáo.
func (s *Routes) CloseRoute(ctx context.Context, shipmentID, reason string) error {
	_, err := s.pool.Exec(ctx, `
        UPDATE routing.routes
           SET is_current = false,
               superseded_at = COALESCE(superseded_at, now())
         WHERE shipment_id = $1 AND is_current`, shipmentID)
	if err != nil {
		return fmt.Errorf("đóng tuyến của %s (%s): %w", shipmentID, reason, err)
	}
	return nil
}

// StampActualDeparture ghi giờ đi thực của một chặng. Được gọi từ nhánh tiêu thụ
// fleet.assignment.created: xe đã nhận chặng nghĩa là chặng đó bắt đầu chạy.
func (s *Routes) StampActualDeparture(ctx context.Context, legID string, at time.Time, carrierID string) error {
	_, err := s.pool.Exec(ctx, `
        UPDATE routing.route_legs
           SET actual_depart_at = COALESCE(actual_depart_at, $2),
               carrier_id       = COALESCE(carrier_id, $3)
         WHERE leg_id = $1`, legID, at, carrierID)
	if err != nil {
		return fmt.Errorf("ghi giờ đi thực cho chặng %s: %w", legID, err)
	}
	return nil
}

// LegsForShipments đọc chặng của nhiều lô hàng trong một lượt, phục vụ POST /v1/eta/batch với
// tối đa 500 lô hàng. Một truy vấn thay cho 500 truy vấn; không có cách nào khác để giữ endpoint
// đó trong ngân sách thời gian của nó.
func (s *Routes) LegsForShipments(ctx context.Context, shipmentIDs []string) (map[string]*domain.Route, error) {
	rows, err := s.pool.Query(ctx, `
        SELECT `+selectRouteColumns+`, `+selectLegColumns+`
        FROM routing.routes r
        JOIN routing.route_legs l ON l.route_id = r.route_id
        WHERE r.shipment_id = ANY($1) AND r.is_current
        ORDER BY r.shipment_id, l.seq_no`, shipmentIDs)
	if err != nil {
		return nil, fmt.Errorf("đọc chặng theo lô: %w", err)
	}
	defer rows.Close()

	out := map[string]*domain.Route{}
	for rows.Next() {
		var r domain.Route
		var l domain.Leg
		if err := rows.Scan(
			&r.RouteID, &r.ShipmentID, &r.Version, &r.IsCurrent, &r.PlannedBy, &r.Strategy,
			&r.TotalDistanceM, &r.TotalDurationS, &r.ComputedAt, &r.SupersededAt,
			&l.LegID, &l.RouteID, &l.SeqNo, &l.Mode, &l.FromFacilityID, &l.ToFacilityID,
			&l.CrossingID, &l.PlannedDepartAt, &l.PlannedArriveAt, &l.ActualDepartAt,
			&l.ActualArriveAt, &l.DistanceM, &l.CarrierID,
		); err != nil {
			return nil, err
		}
		existing, ok := out[r.ShipmentID]
		if !ok {
			copyOf := r
			out[r.ShipmentID] = &copyOf
			existing = &copyOf
		}
		existing.Legs = append(existing.Legs, l)
	}
	return out, rows.Err()
}

func (s *Routes) loadLegs(ctx context.Context, r *domain.Route) error {
	rows, err := s.pool.Query(ctx, `
        SELECT `+selectLegColumns+`
        FROM routing.route_legs l
        WHERE l.route_id = $1
        ORDER BY l.seq_no`, r.RouteID)
	if err != nil {
		return fmt.Errorf("đọc chặng của tuyến %s: %w", r.RouteID, err)
	}
	defer rows.Close()

	for rows.Next() {
		var l domain.Leg
		if err := rows.Scan(
			&l.LegID, &l.RouteID, &l.SeqNo, &l.Mode, &l.FromFacilityID, &l.ToFacilityID,
			&l.CrossingID, &l.PlannedDepartAt, &l.PlannedArriveAt, &l.ActualDepartAt,
			&l.ActualArriveAt, &l.DistanceM, &l.CarrierID,
		); err != nil {
			return err
		}
		r.Legs = append(r.Legs, l)
	}
	return rows.Err()
}

func insertRoute(ctx context.Context, tx pgx.Tx, r *domain.Route) error {
	_, err := tx.Exec(ctx, `
        INSERT INTO routing.routes
            (route_id, shipment_id, version, is_current, planned_by, strategy,
             total_distance_m, total_duration_s, computed_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		r.RouteID, r.ShipmentID, r.Version, r.IsCurrent, r.PlannedBy, r.Strategy,
		r.TotalDistanceM, r.TotalDurationS, r.ComputedAt)
	if err != nil {
		// Vi phạm UNIQUE (shipment_id, version) nghĩa là một tiến trình khác vừa lập cùng phiên
		// bản đó — thường là hai bản sao cùng đọc một message Kafka. Trả lỗi rõ ràng để nhánh
		// tiêu thụ coi đây là trùng lặp chứ không phải sự cố.
		return fmt.Errorf("ghi routing.routes (%s v%d): %w", r.ShipmentID, r.Version, err)
	}
	return nil
}

func insertLegs(ctx context.Context, tx pgx.Tx, r *domain.Route) error {
	batch := &pgx.Batch{}
	for _, l := range r.Legs {
		batch.Queue(`
            INSERT INTO routing.route_legs
                (leg_id, route_id, seq_no, mode, from_facility_id, to_facility_id, crossing_id,
                 planned_depart_at, planned_arrive_at, distance_m, carrier_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
			l.LegID, r.RouteID, l.SeqNo, l.Mode, l.FromFacilityID, l.ToFacilityID, l.CrossingID,
			l.PlannedDepartAt, l.PlannedArriveAt, l.DistanceM, l.CarrierID)
	}
	results := tx.SendBatch(ctx, batch)
	defer results.Close()

	for i := range r.Legs {
		if _, err := results.Exec(); err != nil {
			// crossing_id sai sẽ hỏng ở đây, không hỏng lúc đọc: khoá ngoại
			// routing.route_legs.crossing_id → geo.border_crossings là một trong bốn khoá ngoại
			// liên schema được §2 cho phép, và nó tồn tại đúng để chặn tình huống này.
			return fmt.Errorf("ghi chặng %d của tuyến %s: %w", i+1, r.RouteID, err)
		}
	}
	return nil
}

// scanRoute đọc một dòng routing.routes. Chú ý: bảng không có cột tenant_id và cũng không có
// region_code — hai giá trị đó đi kèm yêu cầu (header X-OF-Tenant, OF_REGION_CODE) chứ không
// được lưu lại, nên Route đọc lên từ đây luôn có hai trường ấy rỗng.
func scanRoute(row pgx.Row) (*domain.Route, error) {
	var r domain.Route
	err := row.Scan(
		&r.RouteID, &r.ShipmentID, &r.Version, &r.IsCurrent, &r.PlannedBy, &r.Strategy,
		&r.TotalDistanceM, &r.TotalDurationS, &r.ComputedAt, &r.SupersededAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}
