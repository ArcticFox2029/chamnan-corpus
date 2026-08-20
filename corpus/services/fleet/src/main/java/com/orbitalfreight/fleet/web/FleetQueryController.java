package com.orbitalfreight.fleet.web;

import com.orbitalfreight.fleet.domain.Vehicle;
import com.orbitalfreight.fleet.domain.VehicleAssignment;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.fleet.repository.FleetRosterRepository;
import com.orbitalfreight.fleet.repository.VehicleAssignmentRepository;
import com.orbitalfreight.fleet.repository.VehicleAssignmentRepository.AssignmentQuery;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * fleet-service의 읽기 전용 HTTP 표면이다. §3.2의 조회 엔드포인트 세 개 —
 * {@code GET /v1/vehicles/{vehicle_id}}, {@code GET /v1/carriers/{carrier_id}/vehicles},
 * {@code GET /v1/assignments} — 를 그대로 구현한다. 쓰기는 전부 gRPC 쪽에 있다.
 *
 * <p>페이지네이션은 §0.5의 커서 방식만 쓴다. 커서는 정렬 키를 base64로 감싼 불투명 문자열이고,
 * 클라이언트가 그 안을 들여다보지 않기를 기대한다. 오프셋 파라미터는 받지도 않는다 —
 * 배차 목록은 조회 도중에도 계속 늘어나므로 오프셋은 항상 항목을 빠뜨리거나 겹치게 만든다.</p>
 */
@RestController
@RequestMapping(produces = MediaType.APPLICATION_JSON_VALUE)
public class FleetQueryController {

    /** §0.5의 상한과 기본값. 이 두 값은 플랫폼 공통이라 서비스가 임의로 바꾸지 않는다. */
    private static final int MAX_LIMIT = 200;
    private static final int DEFAULT_LIMIT = 50;

    private final FleetRosterRepository roster;
    private final VehicleAssignmentRepository assignments;

    public FleetQueryController(FleetRosterRepository roster, VehicleAssignmentRepository assignments) {
        this.roster = roster;
        this.assignments = assignments;
    }

    /** 차량 한 대. 폐차된 차량도 그대로 돌려준다 — 과거 배차를 재구성하는 화면이 필요로 한다. */
    @GetMapping("/v1/vehicles/{vehicle_id}")
    public Map<String, Object> vehicle(@PathVariable("vehicle_id") String vehicleId) {
        Vehicle vehicle = roster.findVehicle(vehicleId)
                .orElseThrow(() -> new FleetException("vehicle_not_found", 404, false,
                        "vehicle " + vehicleId + " is not in fleet.vehicles", List.of()));
        return toJson(vehicle);
    }

    /**
     * 운송사의 차량 목록. {@code veh_} id가 ULID라 사전순 정렬이 곧 등록 순서이고,
     * 그래서 커서가 마지막 id 하나면 충분하다.
     */
    @GetMapping("/v1/carriers/{carrier_id}/vehicles")
    public Map<String, Object> carrierVehicles(
            @PathVariable("carrier_id") String carrierId,
            @RequestParam(value = "cursor", required = false) String cursor,
            @RequestParam(value = "include_decommissioned", defaultValue = "false") boolean includeDecommissioned,
            @RequestParam(value = "limit", required = false) Integer limit) {

        int pageSize = clamp(limit);
        String after = cursor == null ? null : decode(cursor);
        List<Vehicle> page = roster.listVehiclesByCarrier(carrierId, after, includeDecommissioned, pageSize);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("items", page.stream().map(FleetQueryController::toJson).toList());
        body.put("next_cursor", page.size() < pageSize ? null : encode(page.getLast().vehicleId()));
        return body;
    }

    /**
     * 배차 목록. 필터 조합은 §3.2에 적힌 그대로이며, {@code shipment_id}로 거르는 경우가
     * 압도적으로 많다 — 배차 화면과 partner-portal-api의 화물 상세가 둘 다 그렇게 부른다.
     *
     * @param active {@code true}면 아직 반납되지 않은 배차만. 기본값은 전체다
     */
    @GetMapping("/v1/assignments")
    public Map<String, Object> assignments(
            @RequestParam(value = "shipment_id", required = false) String shipmentId,
            @RequestParam(value = "vehicle_id", required = false) String vehicleId,
            @RequestParam(value = "driver_id", required = false) String driverId,
            @RequestParam(value = "active", defaultValue = "false") boolean active,
            @RequestParam(value = "cursor", required = false) String cursor,
            @RequestParam(value = "limit", required = false) Integer limit) {

        if (shipmentId == null && vehicleId == null && driverId == null) {
            // 필터 없는 전체 스캔은 막는다. 테넌트 전체 배차를 훑는 것은 analytics-pipeline의
            // 일이고, 그쪽은 of_analytics_ro 역할로 직접 읽는다(§2).
            throw new FleetException("filter_required", 422, false,
                    "at least one of shipment_id, vehicle_id, driver_id is required",
                    List.of(new FleetException.FieldViolation("shipment_id", "missing")));
        }

        int pageSize = clamp(limit);
        Cursor decoded = cursor == null ? Cursor.none() : Cursor.parse(decode(cursor));
        List<VehicleAssignment> page = this.assignments.search(new AssignmentQuery(
                shipmentId, vehicleId, driverId, active,
                decoded.assignedAt(), decoded.assignmentId(), pageSize));

        String next = page.size() < pageSize
                ? null
                : encode(page.getLast().assignedAt().toString() + "|" + page.getLast().assignmentId());
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("items", page.stream().map(FleetQueryController::toJson).toList());
        body.put("next_cursor", next);
        return body;
    }

    /**
     * JSON 본문을 만들 때 {@code Map.of}를 쓰지 않는다 — null 값을 허용하지 않기 때문이다.
     * {@code decommissioned_at}이나 {@code leg_id}는 정상적으로 비어 있을 수 있고, 그때는
     * 키를 빼는 게 아니라 {@code null}을 실어야 SDK 쪽 옵셔널 파싱이 맞아떨어진다.
     */
    private static Map<String, Object> toJson(Vehicle vehicle) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("vehicle_id", vehicle.vehicleId());
        body.put("carrier_id", vehicle.carrierId());
        body.put("plate", vehicle.plate());
        body.put("plate_country", vehicle.plateCountry());
        body.put("vehicle_class", vehicle.vehicleClass().toColumn());
        body.put("max_payload_kg", vehicle.maxPayloadKg());
        body.put("adr_certified", vehicle.adrCertified());
        body.put("telematics_unit_id", vehicle.telematicsUnitId());
        body.put("decommissioned_at", vehicle.decommissionedAt());
        return body;
    }

    private static Map<String, Object> toJson(VehicleAssignment assignment) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("assignment_id", assignment.assignmentId());
        body.put("vehicle_id", assignment.vehicleId());
        body.put("driver_id", assignment.driverId());
        body.put("shipment_id", assignment.shipmentId());
        body.put("leg_id", assignment.legId());
        body.put("assigned_at", assignment.assignedAt().toString());
        body.put("released_at", assignment.releasedAt() == null ? null : assignment.releasedAt().toString());
        body.put("assigned_by", assignment.assignedBy());
        return body;
    }

    private static int clamp(Integer limit) {
        if (limit == null) {
            return DEFAULT_LIMIT;
        }
        if (limit < 1 || limit > MAX_LIMIT) {
            throw new FleetException("limit_out_of_range", 422, false,
                    "limit must be between 1 and " + MAX_LIMIT,
                    List.of(new FleetException.FieldViolation("limit", "out_of_range")));
        }
        return limit;
    }

    private static String encode(String raw) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(raw.getBytes(StandardCharsets.UTF_8));
    }

    private static String decode(String cursor) {
        try {
            return new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            throw new FleetException("cursor_malformed", 422, false,
                    "cursor is not a value this endpoint issued",
                    List.of(new FleetException.FieldViolation("cursor", "malformed")));
        }
    }

    /** 복합 정렬 키 {@code (assigned_at, assignment_id)}를 담는 커서. */
    private record Cursor(Instant assignedAt, String assignmentId) {

        static Cursor none() {
            return new Cursor(null, null);
        }

        static Cursor parse(String raw) {
            int separator = raw.indexOf('|');
            if (separator < 0) {
                throw new FleetException("cursor_malformed", 422, false,
                        "cursor is not a value this endpoint issued",
                        List.of(new FleetException.FieldViolation("cursor", "malformed")));
            }
            return new Cursor(Instant.parse(raw.substring(0, separator)), raw.substring(separator + 1));
        }
    }
}
