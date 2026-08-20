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
package com.orbitalfreight.fleet.sdk

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * fleet-service가 돌려준 §0.4 오류 봉투를 예외로 옮긴 것이다. HTTP 표면과 gRPC 표면이 같은
 * 봉투를 쓰기 때문에, SDK 사용자는 어느 전송으로 불렀는지와 무관하게 [code] 하나로 분기한다.
 *
 * 메시지 문구로 분기하지 말 것. 문구는 예고 없이 바뀌지만 [code]는 공개 계약의 일부다.
 *
 * @property code 안정적인 snake_case 오류 코드. 예: `vehicle_already_assigned`
 * @property httpStatus 봉투에 실려 온 HTTP 상태. gRPC 호출이어도 값이 들어 있다
 * @property retryable 참이면 지수 백오프로 다시 시도해도 된다. 거짓이면 재시도는 무의미하다
 * @property traceId 장애 신고 시 이 값만 있으면 관련 서비스 로그를 전부 꿸 수 있다
 */
public class FleetApiException(
    public val code: String,
    public val httpStatus: Int,
    public val retryable: Boolean,
    public val traceId: String,
    public val fields: List<FieldViolation>,
    message: String,
) : RuntimeException(message) {

    /**
     * 배차가 이미 잡혀 있어서 실패했는가. 배차 화면이 이 경우에만 후보를 다시 계산한다.
     *
     * 두 코드는 각각 `fleet.vehicle_assignments`의 차량 쪽 exclusion 제약과 기사 쪽 제약에
     * 대응한다 — 어느 쪽인지 알아야 사용자에게 무엇을 바꾸라고 말할 수 있다.
     */
    public val isAssignmentConflict: Boolean
        get() = code == "vehicle_already_assigned" || code == "driver_already_assigned"

    /** 자격 판정에서 막혔는가. 면허 만료, ADR 미보유, 근무 시간 소진이 여기 들어온다. */
    public val isEligibilityFailure: Boolean
        get() = code in setOf(
            "driver_not_eligible",
            "hours_of_service_exhausted",
            "vehicle_class_mismatch",
            "payload_exceeds_vehicle_capacity",
            "carrier_insurance_expired",
        )

    /**
     * routing-service가 방금 경로를 다시 짰다는 뜻이다. 호출자는 새 구간 id를 다시 읽고
     * 재시도해야 하며, 같은 `leg_id`로 다시 시도하면 영원히 같은 오류가 난다.
     */
    public val isLegSuperseded: Boolean
        get() = code == "leg_not_on_current_route"

    override fun toString(): String = "FleetApiException(code=$code, status=$httpStatus, trace=$traceId)"

    public companion object {
        /** 상류 서비스가 답하지 않아 SDK가 스스로 만든 오류. 실제 응답이 없을 때만 쓴다. */
        public fun transport(message: String, traceId: String): FleetApiException =
            FleetApiException("transport_failure", 0, true, traceId, emptyList(), message)
    }
}

/** 오류 봉투의 `fields[]` 한 항목. 어떤 입력이 왜 거부됐는지를 가리킨다. */
@Serializable
public data class FieldViolation(
    val path: String,
    val reason: String,
)

/**
 * 응답 본문을 그대로 받는 형태. 서비스가 봉투를 `{"error": {...}}`로 한 겹 감싸서 주므로
 * 파싱도 두 겹이다.
 */
@Serializable
internal data class ErrorEnvelope(val error: ErrorBody) {

    @Serializable
    internal data class ErrorBody(
        val code: String,
        @SerialName("http_status") val httpStatus: Int,
        val message: String,
        @SerialName("trace_id") val traceId: String = "",
        val retryable: Boolean = false,
        val fields: List<FieldViolation> = emptyList(),
    )

    fun toException(): FleetApiException =
        FleetApiException(error.code, error.httpStatus, error.retryable, error.traceId, error.fields, error.message)
}
