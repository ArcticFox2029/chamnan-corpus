package com.orbitalfreight.fleet.repository;

import com.orbitalfreight.fleet.domain.VehicleAssignment;
import com.orbitalfreight.fleet.error.FleetException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.postgresql.util.PSQLException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * {@code fleet.vehicle_assignments}에 대한 유일한 접근 경로다. 겹치는 배차를 막는 판정은
 * 여기서 SELECT로 미리 확인하지 않고, INSERT를 시도해서 GiST exclusion 제약이 거부하는지로
 * 판단한다 — 배차 콘솔과 기사 앱이 동시에 같은 차량을 잡는 경쟁이 실제로 매일 일어나기 때문에
 * "확인 후 삽입"은 원리적으로 틀린 순서다.
 *
 * <p>{@code SQLSTATE 23P01}(exclusion_violation)의 constraint 이름으로 차량 충돌인지 기사
 * 충돌인지를 구분한다. 두 제약이 같은 테이블에 있으므로 이름을 보지 않으면 어느 쪽이 막혔는지
 * 알 수 없고, 배차 담당자는 "무엇을 바꿔야 하는지"를 알아야 다음 행동을 한다.</p>
 */
@Repository
public class VehicleAssignmentRepository {

    private static final String VEHICLE_OVERLAP_CONSTRAINT = "vehicle_assignments_vehicle_id_active_period_excl";
    private static final String DRIVER_OVERLAP_CONSTRAINT = "vehicle_assignments_driver_id_active_period_excl";

    private static final String INSERT = """
            INSERT INTO fleet.vehicle_assignments
                   (assignment_id, vehicle_id, driver_id, shipment_id, leg_id, assigned_at, assigned_by)
            VALUES (:assignmentId, :vehicleId, :driverId, :shipmentId, :legId, :assignedAt, :assignedBy)
            """;

    private static final String RELEASE = """
            UPDATE fleet.vehicle_assignments
               SET released_at = :releasedAt
             WHERE assignment_id = :assignmentId
               AND released_at IS NULL
            """;

    private static final String SELECT_BASE = """
            SELECT assignment_id, vehicle_id, driver_id, shipment_id, leg_id,
                   assigned_at, released_at, assigned_by
              FROM fleet.vehicle_assignments
            """;

    private final JdbcClient jdbc;

    public VehicleAssignmentRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 배차를 한 건 삽입한다. 호출 트랜잭션 안에서 {@code OutboxRepository}가
     * {@code fleet.assignment.created}를 같이 넣어야 한다(§7.3) — 이 메서드는 커밋하지 않는다.
     *
     * @throws FleetException 겹치는 배차가 이미 있을 때. 차량/기사 중 어느 쪽인지 구분해 던진다
     */
    public VehicleAssignment insert(VehicleAssignment assignment) {
        try {
            jdbc.sql(INSERT)
                    .param("assignmentId", assignment.assignmentId())
                    .param("vehicleId", assignment.vehicleId())
                    .param("driverId", assignment.driverId())
                    .param("shipmentId", assignment.shipmentId())
                    .param("legId", assignment.legId())
                    .param("assignedAt", Timestamp.from(assignment.assignedAt()))
                    .param("assignedBy", assignment.assignedBy())
                    .update();
            return assignment;
        } catch (DataIntegrityViolationException e) {
            throw translateExclusion(e, assignment);
        }
    }

    /**
     * 배차를 닫는다. 이미 닫힌 배차에 다시 호출해도 예외를 던지지 않고 {@code empty}를 돌려준다 —
     * {@code fleet.v1.FleetService/Release}는 멱등해야 하고, {@code route.replanned} 소비자와
     * 배차 담당자가 같은 배차를 동시에 닫는 일이 흔하다.
     */
    public Optional<VehicleAssignment> release(String assignmentId, Instant releasedAt) {
        int updated = jdbc.sql(RELEASE)
                .param("assignmentId", assignmentId)
                .param("releasedAt", Timestamp.from(releasedAt))
                .update();
        return updated == 0 ? Optional.empty() : findById(assignmentId);
    }

    public Optional<VehicleAssignment> findById(String assignmentId) {
        return jdbc.sql(SELECT_BASE + " WHERE assignment_id = :assignmentId")
                .param("assignmentId", assignmentId)
                .query(VehicleAssignmentRepository::map)
                .optional();
    }

    /**
     * {@code GET /v1/assignments}의 필터를 그대로 옮긴다. 커서는 {@code assigned_at DESC,
     * assignment_id DESC} 복합 키를 base64로 감싼 값이고, 오프셋 페이지네이션은 어디에도 없다(§0.5).
     */
    public List<VehicleAssignment> search(AssignmentQuery query) {
        StringBuilder sql = new StringBuilder(SELECT_BASE).append(" WHERE 1 = 1");
        if (query.shipmentId() != null) {
            sql.append(" AND shipment_id = :shipmentId");
        }
        if (query.vehicleId() != null) {
            sql.append(" AND vehicle_id = :vehicleId");
        }
        if (query.driverId() != null) {
            sql.append(" AND driver_id = :driverId");
        }
        if (query.activeOnly()) {
            sql.append(" AND released_at IS NULL");
        }
        if (query.cursorAssignedAt() != null) {
            sql.append(" AND (assigned_at, assignment_id) < (:cursorAssignedAt, :cursorId)");
        }
        sql.append(" ORDER BY assigned_at DESC, assignment_id DESC LIMIT :limit");

        var spec = jdbc.sql(sql.toString()).param("limit", query.limit());
        if (query.shipmentId() != null) {
            spec = spec.param("shipmentId", query.shipmentId());
        }
        if (query.vehicleId() != null) {
            spec = spec.param("vehicleId", query.vehicleId());
        }
        if (query.driverId() != null) {
            spec = spec.param("driverId", query.driverId());
        }
        if (query.cursorAssignedAt() != null) {
            spec = spec.param("cursorAssignedAt", Timestamp.from(query.cursorAssignedAt()))
                    .param("cursorId", query.cursorAssignmentId());
        }
        return spec.query(VehicleAssignmentRepository::map).list();
    }

    /**
     * routing-service가 {@code route.replanned}로 없앤 구간에 걸린 활성 배차를 찾는다.
     * {@code RouteReplannedConsumer}가 이 목록을 받아 한 건씩 반납 처리한다.
     */
    public List<VehicleAssignment> findActiveByLegIds(String shipmentId, List<String> legIds) {
        return jdbc.sql(SELECT_BASE + """
                 WHERE shipment_id = :shipmentId
                   AND leg_id = ANY (:legIds)
                   AND released_at IS NULL
                """)
                .param("shipmentId", shipmentId)
                .param("legIds", legIds.toArray(String[]::new))
                .query(VehicleAssignmentRepository::map)
                .list();
    }

    /** 조회 조건 묶음. 컨트롤러와 gRPC 양쪽이 같은 객체를 만든다. */
    public record AssignmentQuery(
            String shipmentId,
            String vehicleId,
            String driverId,
            boolean activeOnly,
            Instant cursorAssignedAt,
            String cursorAssignmentId,
            int limit) {
    }

    private FleetException translateExclusion(DataIntegrityViolationException e, VehicleAssignment assignment) {
        Throwable cause = e.getMostSpecificCause();
        if (cause instanceof PSQLException psql && "23P01".equals(psql.getSQLState())) {
            String constraint = psql.getServerErrorMessage() == null
                    ? ""
                    : String.valueOf(psql.getServerErrorMessage().getConstraint());
            if (DRIVER_OVERLAP_CONSTRAINT.equals(constraint)) {
                return FleetException.driverAlreadyAssigned(assignment.driverId());
            }
            if (VEHICLE_OVERLAP_CONSTRAINT.equals(constraint)) {
                return FleetException.vehicleAlreadyAssigned(assignment.vehicleId());
            }
            // 제약 이름을 못 읽었으면 차량 쪽으로 보고한다. 실무상 이쪽이 훨씬 흔하다.
            return FleetException.vehicleAlreadyAssigned(assignment.vehicleId());
        }
        throw e;
    }

    private static VehicleAssignment map(java.sql.ResultSet rs, int rowNum) throws java.sql.SQLException {
        Timestamp released = rs.getTimestamp("released_at");
        return new VehicleAssignment(
                rs.getString("assignment_id"),
                rs.getString("vehicle_id"),
                rs.getString("driver_id"),
                rs.getString("shipment_id"),
                rs.getString("leg_id"),
                rs.getTimestamp("assigned_at").toInstant(),
                released == null ? null : released.toInstant(),
                rs.getString("assigned_by"));
    }
}
