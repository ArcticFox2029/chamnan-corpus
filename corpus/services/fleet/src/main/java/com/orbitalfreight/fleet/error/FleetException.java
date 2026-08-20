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
package com.orbitalfreight.fleet.error;

import java.util.List;

/**
 * fleet-service가 밖으로 내보내는 모든 실패를 §0.4의 오류 봉투 모양으로 옮길 수 있게 하는 예외다.
 * {@code code}는 공개 계약의 일부라 한번 정하면 바뀌지 않는다 — 기사 앱과 Kotlin SDK가 이 문자열로
 * 분기하기 때문에, 메시지 문구는 고쳐도 코드는 고치지 않는다.
 *
 * <p>HTTP 경로에서는 {@code FleetExceptionHandler}가, gRPC 경로에서는 {@code FleetGrpcService}가
 * 같은 인스턴스를 각자의 표현으로 바꾼다. gRPC 쪽은 {@code google.rpc.Status.details}에 같은
 * 봉투를 그대로 실어 보내므로 두 표면의 오류 코드가 절대 갈라지지 않는다.</p>
 */
public class FleetException extends RuntimeException {

    private final String code;
    private final int httpStatus;
    private final boolean retryable;
    private final List<FieldViolation> fields;

    public FleetException(String code, int httpStatus, boolean retryable, String message, List<FieldViolation> fields) {
        super(message);
        this.code = code;
        this.httpStatus = httpStatus;
        this.retryable = retryable;
        this.fields = fields == null ? List.of() : List.copyOf(fields);
    }

    /** 오류 봉투의 {@code fields[]} 한 항목. */
    public record FieldViolation(String path, String reason) {
    }

    public String code() {
        return code;
    }

    public int httpStatus() {
        return httpStatus;
    }

    public boolean retryable() {
        return retryable;
    }

    public List<FieldViolation> fields() {
        return fields;
    }

    // ------------------------------------------------------------------
    // 배차 경로에서 실제로 나오는 실패들. 새 코드를 늘리기 전에 여기 목록을 먼저 본다.
    // ------------------------------------------------------------------

    /**
     * {@code fleet.vehicle_assignments}의 GiST exclusion 제약(차량 기준)에 걸렸다.
     * 재시도해도 같은 결과이므로 {@code retryable=false}다.
     */
    public static FleetException vehicleAlreadyAssigned(String vehicleId) {
        return new FleetException("vehicle_already_assigned", 409, false,
                "vehicle " + vehicleId + " already holds an overlapping assignment", List.of());
    }

    /** 같은 제약의 기사 쪽. 두 제약을 구분해 두어야 배차 화면이 어느 쪽을 바꿔야 하는지 안다. */
    public static FleetException driverAlreadyAssigned(String driverId) {
        return new FleetException("driver_already_assigned", 409, false,
                "driver " + driverId + " already holds an overlapping assignment", List.of());
    }

    /** container-registry가 알려준 화물 상태로는 배차할 수 없다. */
    public static FleetException shipmentNotAssignable(String shipmentId, String status) {
        return new FleetException("shipment_not_assignable", 409, false,
                "shipment " + shipmentId + " is in status '" + status + "' and cannot take an assignment",
                List.of(new FieldViolation("shipment_id", "status=" + status)));
    }

    /** 기사 면허 또는 ADR 자격이 구간 출발일 기준으로 만료되었다. */
    public static FleetException driverNotEligible(String driverId, String reason) {
        return new FleetException("driver_not_eligible", 422, false,
                "driver " + driverId + " failed eligibility: " + reason,
                List.of(new FieldViolation("driver_id", reason)));
    }

    /** 남은 운전 가능 시간이 구간 소요 시간보다 짧다. */
    public static FleetException hoursOfServiceExhausted(String driverId, long remainingMinutes) {
        return new FleetException("hours_of_service_exhausted", 422, false,
                "driver " + driverId + " has only " + remainingMinutes + " driving minutes left in the window",
                List.of(new FieldViolation("driver_id", "remaining_minutes=" + remainingMinutes)));
    }

    /** routing-service가 준 현재 경로에 요청된 {@code leg_id}가 없다. 대개 replan 직후다. */
    public static FleetException legNotOnCurrentRoute(String legId, String shipmentId) {
        return new FleetException("leg_not_on_current_route", 409, false,
                "leg " + legId + " is not part of the current route of shipment " + shipmentId,
                List.of(new FieldViolation("leg_id", "superseded")));
    }

    /** 차량 등급이 구간의 운송 수단과 맞지 않는다(예: barge 구간에 tractor). */
    public static FleetException vehicleClassMismatch(String vehicleId, String mode) {
        return new FleetException("vehicle_class_mismatch", 422, false,
                "vehicle " + vehicleId + " cannot perform a '" + mode + "' leg", List.of());
    }

    /** 상류 서비스가 예산 안에 답하지 못했다. 이건 재시도 가치가 있다. */
    public static FleetException upstreamUnavailable(String service, String detail) {
        return new FleetException("upstream_unavailable", 503, true,
                service + " did not answer in time: " + detail, List.of());
    }

    /** 같은 {@code X-OF-Idempotency-Key}로 다른 본문이 들어왔다(§7.5). */
    public static FleetException idempotencyKeyReused(String key) {
        return new FleetException("idempotency_key_reused", 409, false,
                "idempotency key " + key + " was already used with a different payload", List.of());
    }
}
