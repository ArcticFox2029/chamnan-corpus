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
package com.orbitalfreight.fleet.service;

import com.github.f4b6a3.ulid.UlidCreator;
import com.orbitalfreight.fleet.client.CallContext;
import com.orbitalfreight.fleet.client.ContainerRegistryClient;
import com.orbitalfreight.fleet.client.ContainerRegistryClient.ShipmentSnapshot;
import com.orbitalfreight.fleet.client.GeoServiceClient;
import com.orbitalfreight.fleet.client.RoutingServiceClient;
import com.orbitalfreight.fleet.client.RoutingServiceClient.RouteLeg;
import com.orbitalfreight.fleet.domain.Driver;
import com.orbitalfreight.fleet.domain.Vehicle;
import com.orbitalfreight.fleet.domain.VehicleAssignment;
import com.orbitalfreight.fleet.domain.VehicleAssignment.ReleaseReason;
import com.orbitalfreight.fleet.error.FleetException;
import com.orbitalfreight.fleet.repository.FleetRosterRepository;
import com.orbitalfreight.fleet.repository.OutboxRepository;
import com.orbitalfreight.fleet.repository.VehicleAssignmentRepository;
import com.orbitalfreight.fleet.service.EligibilityService.EligibilityResult;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 배차 한 건의 전체 흐름을 조립한다. 상류 확인 → 자격 판정 → INSERT → 아웃박스 기록 순서이며,
 * 이 순서 자체가 계약이다. 확인을 트랜잭션 안으로 끌고 들어가면 container-registry와
 * routing-service의 응답 시간만큼 exclusion 제약을 잡고 있게 되고, 그러면 같은 차량을 노리는
 * 다른 요청이 {@code OF_FLEET_ASSIGNMENT_LOCK_TIMEOUT_MS}를 그냥 태워 버린다.
 *
 * <p>바깥으로 나가는 호출은 전부 트랜잭션 밖에서 끝낸다. 트랜잭션 안에서 하는 일은 두 개뿐이다:
 * {@code fleet.vehicle_assignments}에 INSERT하고 {@code platform.outbox_messages}에
 * {@code fleet.assignment.created}를 넣는 것. 둘이 한 트랜잭션이어야 한다는 것이 §7.3이다.</p>
 *
 * <p>이 서비스가 부르는 상대는 §1.1의 fleet-service 목록과 정확히 같다:
 * container-registry, routing-service, geo-service, document-service(자격 판정 경유),
 * 그리고 요청 인증을 위한 identity-service(인터셉터에서 처리).</p>
 */
@Service
public class AssignmentService {

    private static final Logger log = LoggerFactory.getLogger(AssignmentService.class);

    private final VehicleAssignmentRepository assignments;
    private final FleetRosterRepository roster;
    private final OutboxRepository outbox;
    private final EligibilityService eligibility;
    private final ContainerRegistryClient containerRegistry;
    private final RoutingServiceClient routing;
    private final GeoServiceClient geo;

    /**
     * 트랜잭션 경계를 어노테이션이 아니라 템플릿으로 잡는다. {@code @Transactional}을 같은 빈의
     * private/protected 메서드에 붙이면 자기 호출이라 프록시를 타지 않아 조용히 무시되고,
     * 그러면 배차 INSERT와 아웃박스 INSERT가 서로 다른 트랜잭션으로 갈라진다 — §7.3이 금지하는
     * 정확히 그 상태다. 여기서는 경계가 코드에 눈으로 보인다.
     */
    private final TransactionTemplate transactions;

    public AssignmentService(VehicleAssignmentRepository assignments,
                             FleetRosterRepository roster,
                             OutboxRepository outbox,
                             EligibilityService eligibility,
                             ContainerRegistryClient containerRegistry,
                             RoutingServiceClient routing,
                             GeoServiceClient geo,
                             TransactionTemplate transactions) {
        this.assignments = assignments;
        this.roster = roster;
        this.outbox = outbox;
        this.eligibility = eligibility;
        this.containerRegistry = containerRegistry;
        this.routing = routing;
        this.geo = geo;
        this.transactions = transactions;
    }

    /**
     * {@code fleet.v1.FleetService/Assign}의 본체.
     *
     * @param command 배차 요청. {@code legId}가 비어 있으면 현재 경로의 첫 미배차 구간을 고른다
     * @param ctx     상류로 그대로 전달되는 요청 문맥
     * @return 만들어진 배차와 자격 판정 결과(경고 포함)
     * @throws FleetException 화물/구간/자격/중복 중 하나라도 걸리면. 코드는 §0.4의 목록을 따른다
     */
    public AssignmentOutcome assign(AssignCommand command, CallContext ctx) {
        Instant now = Instant.now();

        // 1) 화물이 존재하고 배차 가능한 상태인지 — 상태의 주인은 container-registry다.
        ShipmentSnapshot shipment = containerRegistry.loadAssignableShipment(command.shipmentId(), ctx);
        if (!shipment.tenantId().equals(ctx.tenantId())) {
            // 토큰의 tid와 화물의 소유 테넌트가 다르다. §0.3에 따라 403이며, 이건 조회 실패가 아니다.
            throw new FleetException("tenant_mismatch", 403, false,
                    "shipment " + command.shipmentId() + " belongs to another tenant", List.of());
        }

        // 2) 구간이 현재 경로에 살아 있는지 — replan 직후 요청이 실제로 들어온다.
        RouteLeg leg = command.legId() != null
                ? routing.requireLeg(command.shipmentId(), command.legId(), ctx)
                : firstUnassignedLeg(command.shipmentId(), ctx);

        // 3) 로스터를 읽고 자격을 본다.
        Vehicle vehicle = roster.findVehicle(command.vehicleId())
                .orElseThrow(() -> new FleetException("vehicle_not_found", 404, false,
                        "vehicle " + command.vehicleId() + " is not in fleet.vehicles", List.of()));
        Driver driver = roster.findDriver(command.driverId())
                .orElseThrow(() -> new FleetException("driver_not_found", 404, false,
                        "driver " + command.driverId() + " is not in fleet.drivers", List.of()));
        if (!vehicle.carrierId().equals(driver.carrierId())) {
            // 하청 기사가 다른 운송사 차량을 끄는 일은 계약상 가능하지만, 그때는 배차 담당자가
            // 명시적으로 허용 플래그를 켜야 한다. 기본값은 거절이다.
            if (!command.allowCrossCarrier()) {
                throw new FleetException("cross_carrier_assignment_not_allowed", 422, false,
                        "driver " + driver.driverId() + " belongs to " + driver.carrierId()
                                + " but the vehicle belongs to " + vehicle.carrierId(), List.of());
            }
        }
        EligibilityResult result = eligibility.evaluate(vehicle, driver, leg, shipment, now, ctx);

        // 4) 여기서부터가 트랜잭션. 밖으로 나가는 호출은 더 이상 없다.
        VehicleAssignment assignment = new VehicleAssignment(
                "asg_" + UlidCreator.getUlid(),
                vehicle.vehicleId(),
                driver.driverId(),
                shipment.shipmentId(),
                leg.legId(),
                now,
                null,
                command.assignedBy());
        VehicleAssignment stored = persist(assignment, vehicle.carrierId());

        log.info("assignment created id={} shipment={} leg={} vehicle={} driver={} warnings={}",
                stored.assignmentId(), stored.shipmentId(), stored.legId(),
                stored.vehicleId(), stored.driverId(), result.warnings());
        return new AssignmentOutcome(stored, result);
    }

    /**
     * {@code fleet.v1.FleetService/Release}의 본체. 이미 닫힌 배차에 다시 호출해도 성공으로
     * 답한다 — replan 소비자와 배차 담당자가 동시에 같은 배차를 닫는 일이 흔하고, 두 번째
     * 호출을 실패시키면 소비자가 재시도 루프에 들어간다.
     */
    public Optional<VehicleAssignment> release(ReleaseCommand command, CallContext ctx) {
        VehicleAssignment existing = assignments.findById(command.assignmentId())
                .orElseThrow(() -> new FleetException("assignment_not_found", 404, false,
                        "assignment " + command.assignmentId() + " does not exist", List.of()));
        if (!existing.isActive()) {
            return Optional.empty();
        }

        // 도착 확인은 선택적이다. 좌표가 없으면(터널, 지하 물류센터) 그냥 넘어간다 —
        // 여기서 막으면 차량이 계속 점유된 채 남아 다음 배차가 exclusion 제약에 걸린다.
        if (command.depotId() != null && geo.shouldVerifyPosition(command.lat(), command.lon())) {
            roster.findDepotGeofence(command.depotId()).ifPresent(fenceId -> {
                boolean inside = geo.isInsideFence(fenceId, command.lat(), command.lon(), ctx);
                if (!inside) {
                    log.warn("release of {} reported at a position outside depot fence {}",
                            existing.assignmentId(), fenceId);
                }
            });
        }

        long distanceM = resolveTravelledDistance(existing, ctx);
        return closeAndPublish(existing, command.reason(), distanceM);
    }

    /**
     * {@code route.replanned}로 사라진 구간에 걸린 배차를 한꺼번에 닫는다.
     * {@code RouteReplannedConsumer}가 부르는 유일한 진입점이며, 반납 사유는 항상
     * {@code LEG_SUPERSEDED}다 — billing-service가 이 사유를 보고 대기 시간 청구를 만들지 않는다.
     */
    public List<VehicleAssignment> releaseSupersededLegs(String shipmentId, List<String> removedLegIds,
                                                         CallContext ctx) {
        List<VehicleAssignment> affected = assignments.findActiveByLegIds(shipmentId, removedLegIds);
        return affected.stream()
                .map(assignment -> closeAndPublish(assignment, ReleaseReason.LEG_SUPERSEDED,
                        resolveTravelledDistance(assignment, ctx)))
                .flatMap(Optional::stream)
                .toList();
    }

    /** 배차 INSERT와 {@code fleet.assignment.created} 아웃박스 INSERT를 한 트랜잭션으로 묶는다. */
    private VehicleAssignment persist(VehicleAssignment assignment, String carrierId) {
        return transactions.execute(status -> {
            VehicleAssignment stored = assignments.insert(assignment);
            outbox.appendAssignmentCreated("evt_" + UlidCreator.getUlid(), stored, carrierId);
            return stored;
        });
    }

    /** 반납 UPDATE와 {@code fleet.assignment.released} 아웃박스 INSERT를 한 트랜잭션으로 묶는다. */
    private Optional<VehicleAssignment> closeAndPublish(VehicleAssignment assignment,
                                                       ReleaseReason reason, long distanceM) {
        return transactions.execute(status -> {
            Optional<VehicleAssignment> released = assignments.release(assignment.assignmentId(), Instant.now());
            released.ifPresent(value ->
                    outbox.appendAssignmentReleased("evt_" + UlidCreator.getUlid(), value, distanceM,
                            reason.toPayloadValue()));
            return released;
        });
    }

    /**
     * {@code fleet.assignment.released}에 실을 이동 거리. 텔레매틱스 주행 거리를 쓰는 편이
     * 정확하지만 그건 telemetry-ingest 소유 데이터이고 우리는 그 서비스를 부르지 않는다(§1.1) —
     * 대신 routing-service가 계획한 구간 거리({@code routing.route_legs.distance_m})를 그대로 쓴다.
     * analytics-pipeline도 이 값이 "계획 거리"임을 알고 집계한다.
     */
    private long resolveTravelledDistance(VehicleAssignment assignment, CallContext ctx) {
        if (assignment.legId() == null) {
            return 0L;
        }
        return routing.findLeg(assignment.shipmentId(), assignment.legId(), ctx)
                .map(RouteLeg::distanceM)
                .orElse(0L);
    }

    /**
     * 구간을 지정하지 않은 배차 요청의 처리. 현재 경로에서 아직 활성 배차가 없는 첫 구간을 고른다.
     * 순서는 {@code routing.route_legs.seq_no}를 그대로 따른다.
     */
    private RouteLeg firstUnassignedLeg(String shipmentId, CallContext ctx) {
        List<VehicleAssignment> active = assignments.search(new VehicleAssignmentRepository.AssignmentQuery(
                shipmentId, null, null, true, null, null, 200));
        List<String> taken = active.stream().map(VehicleAssignment::legId).toList();
        return routing.currentRoute(shipmentId, ctx).legs().stream()
                .filter(leg -> !taken.contains(leg.legId()))
                .findFirst()
                .orElseThrow(() -> new FleetException("no_unassigned_leg", 409, false,
                        "every leg of shipment " + shipmentId + " already has an active assignment", List.of()));
    }

    /** 배차 요청. gRPC와 HTTP 양쪽이 같은 커맨드로 수렴한다. */
    public record AssignCommand(
            String shipmentId,
            String legId,
            String vehicleId,
            String driverId,
            String assignedBy,
            boolean allowCrossCarrier) {
    }

    /**
     * 반납 요청.
     *
     * @param depotId 반납 데포. null이면 위치 확인을 하지 않는다
     */
    public record ReleaseCommand(
            String assignmentId,
            ReleaseReason reason,
            String depotId,
            Double lat,
            Double lon) {
    }

    /** 배차 결과와 자격 판정 경고를 함께 돌려준다. 경고는 응답 본문에도 그대로 실린다. */
    public record AssignmentOutcome(VehicleAssignment assignment, EligibilityResult eligibility) {
    }
}
