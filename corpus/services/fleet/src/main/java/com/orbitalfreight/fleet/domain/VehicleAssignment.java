package com.orbitalfreight.fleet.domain;

import java.time.Instant;
import java.util.Locale;

/**
 * {@code fleet.vehicle_assignments} 한 행. 이 도메인 전체에서 유일하게 "쓰기"가 일어나는 대상이며,
 * 차량 한 대와 기사 한 명이 같은 시각에 두 화물에 걸리지 않는다는 불변식은 애플리케이션이 아니라
 * 테이블의 GiST exclusion 제약이 지킨다(§2.2). 이 레코드는 그 결과를 담을 뿐이다.
 *
 * <p>{@code shipmentId}는 {@code freight.shipments}를 가리키는 logical FK이고
 * {@code legId}는 {@code routing.route_legs}를 가리키는 logical FK다. 둘 다 DB 제약이 없으므로
 * 유효성은 container-registry와 routing-service를 호출해 확인한 뒤에만 INSERT한다.</p>
 */
public record VehicleAssignment(
        String assignmentId,
        String vehicleId,
        String driverId,
        String shipmentId,
        String legId,
        Instant assignedAt,
        Instant releasedAt,
        String assignedBy) {

    /**
     * {@code fleet.assignment.released} 이벤트의 {@code release_reason} 값 목록.
     * billing-service가 이 값을 보고 대기 시간(waiting_time) 청구 라인을 만들지 결정하므로
     * 새 값을 추가하려면 §4.7을 먼저 고쳐야 한다.
     */
    public enum ReleaseReason {
        /** 구간을 정상 완주했다. billing-service가 청구 가능한 이동으로 취급한다. */
        COMPLETED,
        /** routing-service가 {@code route.replanned}를 내면서 이 구간을 없앴다. */
        LEG_SUPERSEDED,
        /** 배차 담당자가 콘솔에서 직접 취소했다. */
        CANCELLED_BY_DISPATCH,
        /** 기사 근무 시간이 소진되어 교대가 필요했다. */
        HOS_LIMIT,
        /** 차량 고장. 후속 배차는 새 assignment로 만들어진다. */
        BREAKDOWN;

        public String toPayloadValue() {
            return name().toLowerCase(Locale.ROOT);
        }
    }

    public boolean isActive() {
        return releasedAt == null;
    }

    /**
     * 반납 처리된 사본을 만든다. 원본을 수정하지 않는 이유는 감사 때문이다 —
     * 같은 트랜잭션에서 audit-ledger로 보낼 payload가 반납 전후를 모두 담아야 한다.
     */
    public VehicleAssignment released(Instant at) {
        if (releasedAt != null) {
            throw new IllegalStateException("assignment " + assignmentId + " was already released at " + releasedAt);
        }
        return new VehicleAssignment(assignmentId, vehicleId, driverId, shipmentId, legId, assignedAt, at, assignedBy);
    }

    /**
     * 배차가 실제로 유지된 시간(초). {@code fleet.vehicle_assignments.active_period}가 DB에서
     * 계산하는 것과 같은 구간이지만, 이벤트를 만들 때 다시 SELECT하지 않기 위해 여기서도 구한다.
     */
    public long heldSeconds(Instant now) {
        Instant end = releasedAt != null ? releasedAt : now;
        return end.getEpochSecond() - assignedAt.getEpochSecond();
    }
}
