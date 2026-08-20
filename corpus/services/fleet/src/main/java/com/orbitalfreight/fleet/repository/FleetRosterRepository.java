/*
 * Copyright 2026 ORBITALFREIGHT Holding B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.orbitalfreight.fleet.repository;

import com.orbitalfreight.fleet.domain.Driver;
import com.orbitalfreight.fleet.domain.DutyStatusChange;
import com.orbitalfreight.fleet.domain.DutyStatusChange.DutyStatus;
import com.orbitalfreight.fleet.domain.Vehicle;
import com.orbitalfreight.fleet.domain.Vehicle.VehicleClass;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * 로스터 쪽 읽기 전용 접근을 모아 둔 저장소다. {@code fleet.carriers}, {@code fleet.vehicles},
 * {@code fleet.drivers}, {@code fleet.depots}와 기사 근무 상태 로그를 다룬다. 배차 자체는
 * {@code VehicleAssignmentRepository}가 따로 맡는다 — 읽기와 쓰기를 한 클래스에 두면
 * 트랜잭션 경계가 흐려지고, 실제로 그 때문에 로스터 조회가 배차 락을 잡은 적이 있다.
 *
 * <p>여기 있는 어떤 쿼리도 {@code fleet} 스키마 밖을 보지 않는다(§7.2). 화물이나 구간 정보가
 * 필요하면 container-registry와 routing-service의 API를 거친다.</p>
 */
@Repository
public class FleetRosterRepository {

    private static final String VEHICLE_COLUMNS = """
            SELECT vehicle_id, carrier_id, plate, plate_country, vehicle_class,
                   max_payload_kg, telematics_unit_id, adr_certified, decommissioned_at
              FROM fleet.vehicles
            """;

    private static final String DRIVER_COLUMNS = """
            SELECT driver_id, carrier_id, user_id, full_name, licence_number, licence_country,
                   licence_expires_on, adr_expires_on, phone_e164
              FROM fleet.drivers
            """;

    private final JdbcClient jdbc;

    public FleetRosterRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<Vehicle> findVehicle(String vehicleId) {
        return jdbc.sql(VEHICLE_COLUMNS + " WHERE vehicle_id = :vehicleId")
                .param("vehicleId", vehicleId)
                .query(FleetRosterRepository::mapVehicle)
                .optional();
    }

    /**
     * {@code GET /v1/carriers/{carrier_id}/vehicles}의 본문. 폐차된 차량은 기본적으로 빼되,
     * 감사 화면이 과거 배차를 재구성할 때 필요하므로 {@code includeDecommissioned}로 열어 둔다.
     *
     * @param cursorVehicleId 이전 페이지의 마지막 {@code veh_} id. ULID라 사전순 = 시간순이다
     */
    public List<Vehicle> listVehiclesByCarrier(String carrierId, String cursorVehicleId,
                                               boolean includeDecommissioned, int limit) {
        StringBuilder sql = new StringBuilder(VEHICLE_COLUMNS).append(" WHERE carrier_id = :carrierId");
        if (!includeDecommissioned) {
            sql.append(" AND decommissioned_at IS NULL");
        }
        if (cursorVehicleId != null) {
            sql.append(" AND vehicle_id > :cursorVehicleId");
        }
        sql.append(" ORDER BY vehicle_id LIMIT :limit");

        var spec = jdbc.sql(sql.toString()).param("carrierId", carrierId).param("limit", limit);
        if (cursorVehicleId != null) {
            spec = spec.param("cursorVehicleId", cursorVehicleId);
        }
        return spec.query(FleetRosterRepository::mapVehicle).list();
    }

    public Optional<Driver> findDriver(String driverId) {
        return jdbc.sql(DRIVER_COLUMNS + " WHERE driver_id = :driverId")
                .param("driverId", driverId)
                .query(FleetRosterRepository::mapDriver)
                .optional();
    }

    /**
     * 운송사의 보험 만료일. {@code fleet.carriers.insurance_expires_on}이 지난 운송사에는
     * 어떤 배차도 나가지 않는다 — 이 판정은 EligibilityService가 하고, 여기서는 값만 준다.
     */
    public Optional<LocalDate> findCarrierInsuranceExpiry(String carrierId) {
        return jdbc.sql("SELECT insurance_expires_on FROM fleet.carriers WHERE carrier_id = :carrierId")
                .param("carrierId", carrierId)
                .query(LocalDate.class)
                .optional();
    }

    /**
     * 데포의 지오펜스 id. 배차 반납 시 차량이 실제로 데포 안에 있는지 확인하려고
     * geo-service의 {@code geo.v1.GeoService/PointInFence}에 넘길 값이다.
     */
    public Optional<String> findDepotGeofence(String depotId) {
        return jdbc.sql("SELECT geofence_id FROM fleet.depots WHERE depot_id = :depotId AND closed_on IS NULL")
                .param("depotId", depotId)
                .query(String.class)
                .optional();
    }

    /**
     * 배차 이력에서 운전 구간을 복원한다. §2의 {@code fleet} 스키마에는 근무 상태 로그 테이블이
     * 없고, 그건 의도된 것이다 — 법정 보존본은 기사 앱(apps/driver-ios)의 ELD 기록이 원본이고,
     * fleet-service는 판정에 필요한 창만 들고 있으면 된다. 표를 하나 더 만들려면 §2를 먼저
     * 고쳐야 한다(§7.1).
     *
     * <p>{@code DutyStatusJournal}의 Redis 창이 비었을 때(파드 재기동, 캐시 비움) 이 결과로
     * 창을 다시 채운다. 배차가 걸려 있던 시간은 최소한 근무 시간이었다고 보는 보수적 복원이며,
     * 실제 운전/대기 구분은 기사 앱이 다음 상태 변경을 올리는 순간 정확해진다.</p>
     *
     * @param since 보통 {@code now - 36h}. 일일 휴식 초기화를 반드시 포함하도록 넉넉히 잡는다
     */
    public List<DutyStatusChange> reconstructDutyWindow(String driverId, Instant since) {
        return jdbc.sql("""
                SELECT driver_id, vehicle_id, assigned_at, released_at
                  FROM fleet.vehicle_assignments
                 WHERE driver_id = :driverId
                   AND upper(active_period) IS DISTINCT FROM lower(active_period)
                   AND active_period && tstzrange(:since, now(), '[)')
                 ORDER BY assigned_at
                """)
                .param("driverId", driverId)
                .param("since", Timestamp.from(since))
                .query(FleetRosterRepository::mapAssignmentAsDuty)
                .list()
                .stream()
                .flatMap(List::stream)
                .toList();
    }

    private static Vehicle mapVehicle(ResultSet rs, int rowNum) throws SQLException {
        Timestamp decommissioned = rs.getTimestamp("decommissioned_at");
        return new Vehicle(
                rs.getString("vehicle_id"),
                rs.getString("carrier_id"),
                rs.getString("plate"),
                rs.getString("plate_country"),
                VehicleClass.fromColumn(rs.getString("vehicle_class")),
                rs.getInt("max_payload_kg"),
                rs.getString("telematics_unit_id"),
                rs.getBoolean("adr_certified"),
                decommissioned == null ? null : decommissioned.toInstant());
    }

    private static Driver mapDriver(ResultSet rs, int rowNum) throws SQLException {
        java.sql.Date adr = rs.getDate("adr_expires_on");
        return new Driver(
                rs.getString("driver_id"),
                rs.getString("carrier_id"),
                rs.getString("user_id"),
                rs.getString("full_name"),
                rs.getString("licence_number"),
                rs.getString("licence_country"),
                rs.getDate("licence_expires_on").toLocalDate(),
                adr == null ? null : adr.toLocalDate(),
                rs.getString("phone_e164"));
    }

    /**
     * 배차 한 건을 근무 상태 변경 두 개로 편다: 시작 시점의 {@code DRIVING}, 반납 시점의
     * {@code OFF_DUTY}. 아직 반납되지 않은 배차는 뒤쪽 항목이 없다 — 계산기가 마지막 상태를
     * {@code now}까지 이어진 것으로 보기 때문에 그대로 맞는다.
     */
    private static List<DutyStatusChange> mapAssignmentAsDuty(ResultSet rs, int rowNum) throws SQLException {
        String driverId = rs.getString("driver_id");
        String vehicleId = rs.getString("vehicle_id");
        Instant assignedAt = rs.getTimestamp("assigned_at").toInstant();
        Timestamp released = rs.getTimestamp("released_at");
        DutyStatusChange start =
                new DutyStatusChange(driverId, DutyStatus.DRIVING, assignedAt, assignedAt, vehicleId, null,
                        "reconstructed:vehicle_assignments");
        if (released == null) {
            return List.of(start);
        }
        Instant end = released.toInstant();
        return List.of(start,
                new DutyStatusChange(driverId, DutyStatus.OFF_DUTY, end, end, vehicleId, null,
                        "reconstructed:vehicle_assignments"));
    }
}
