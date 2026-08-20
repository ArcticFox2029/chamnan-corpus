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

import com.orbitalfreight.fleet.sdk.http.OrbitalFreightTransport
import com.orbitalfreight.fleet.sdk.model.AssignRequest
import com.orbitalfreight.fleet.sdk.model.AssignResult
import com.orbitalfreight.fleet.sdk.model.Assignment
import com.orbitalfreight.fleet.sdk.model.DriverAvailability
import com.orbitalfreight.fleet.sdk.model.DutyStatusPost
import com.orbitalfreight.fleet.sdk.model.Page
import com.orbitalfreight.fleet.sdk.model.Vehicle
import com.orbitalfreight.gen.fleet.v1.FleetServiceGrpcKt
import com.orbitalfreight.gen.fleet.v1.assignRequest
import com.orbitalfreight.gen.fleet.v1.checkEligibilityRequest
import com.orbitalfreight.gen.fleet.v1.releaseRequest
import io.grpc.ManagedChannel
import io.grpc.Metadata
import io.grpc.StatusException
import io.grpc.protobuf.StatusProto
import java.util.UUID
import kotlinx.serialization.json.Json

/**
 * fleet-service를 부르는 공식 코틀린 클라이언트다. 배차 콘솔(web/), 검수 앱
 * (apps/inspector-android), 그리고 JVM으로 도는 내부 도구가 모두 이것을 쓴다.
 *
 * 전송이 두 가지로 갈리는 것은 서비스 표면이 실제로 그렇게 생겼기 때문이다(§3.2).
 * 배차를 잡고 푸는 세 개의 RPC — `fleet.v1.FleetService/Assign`, `/Release`,
 * `/CheckEligibility` — 는 gRPC(9082)에만 있고, 조회 다섯 개는 HTTP(8082)에만 있다.
 * 이 클래스는 그 사실을 감추지 않는다. 감추면 사용자가 조회에 gRPC 데드라인을 기대하게 된다.
 *
 * ### 쓰는 법
 * ```kotlin
 * val client = FleetClient(
 *     httpBaseUrl = "http://fleet-service:8082",
 *     channel = ManagedChannelBuilder.forTarget("fleet-service:9082").usePlaintext().build(),
 *     tenantId = "tnt_01J7A0000000000000000000AA",
 *     tokenProvider = { identity.currentAccessToken() },
 * )
 * val result = client.assign(AssignRequest(shipmentId, vehicleId, driverId, assignedBy = me))
 * ```
 *
 * 토큰은 [tokenProvider]로 매번 새로 받는다. identity-service의 액세스 토큰은 15분짜리라
 * 클라이언트를 오래 들고 있으면 반드시 만료되고, SDK가 토큰을 캐시해 버리면 그 갱신을
 * 사용자가 눈치채지 못한 채 401을 만나게 된다.
 */
public class FleetClient(
    httpBaseUrl: String,
    private val channel: ManagedChannel,
    private val tenantId: String,
    private val tokenProvider: suspend () -> String,
) {

    private val transport = OrbitalFreightTransport(httpBaseUrl, tenantId, tokenProvider)
    private val json: Json = OrbitalFreightTransport.defaultJson()

    // ------------------------------------------------------------------
    // gRPC — 배차를 잡고 푸는 경로
    // ------------------------------------------------------------------

    /**
     * 차량과 기사를 화물의 한 구간에 예약한다.
     *
     * 서버는 예약 전에 container-registry에서 화물 상태를, routing-service에서 구간을 확인하고,
     * 마지막에 `fleet.vehicle_assignments`의 exclusion 제약으로 중복을 막는다. 그래서 이
     * 호출이 성공했다는 것은 "그 시간대에 그 차량과 그 기사가 확실히 우리 것"이라는 뜻이다.
     *
     * @throws FleetApiException [FleetApiException.isAssignmentConflict]가 참이면 다른 후보로
     *   바꿔야 하고, [FleetApiException.isLegSuperseded]가 참이면 경로를 다시 읽어야 한다.
     *   두 경우 모두 재시도는 의미가 없다
     */
    public suspend fun assign(request: AssignRequest, traceId: String = newTraceId()): AssignResult =
        withFleetErrors(traceId) {
            val response = stub(traceId).assign(
                assignRequest {
                    shipmentId = request.shipmentId
                    vehicleId = request.vehicleId
                    driverId = request.driverId
                    assignedBy = request.assignedBy
                    request.legId?.let { legId = it }
                    allowCrossCarrier = request.allowCrossCarrier
                },
            )
            AssignResult(
                assignmentId = response.assignmentId,
                shipmentId = response.shipmentId,
                legId = response.legId.ifEmpty { null },
                vehicleId = response.vehicleId,
                driverId = response.driverId,
                assignedAt = response.assignedAt,
                warnings = response.warningsList,
            )
        }

    /**
     * 배차를 닫는다. 이미 닫혀 있으면 `false`를 돌려주고 예외를 던지지 않는다 — 서버 쪽이
     * 멱등하게 설계되어 있어서, 같은 배차를 배차 담당자와 `route.replanned` 소비자가 동시에
     * 닫는 흔한 상황에서 클라이언트가 오류를 처리할 필요가 없다.
     *
     * @param depotId 반납 데포. 좌표와 함께 주면 서버가 geo-service로 데포 지오펜스 안인지 확인한다
     */
    public suspend fun release(
        assignmentId: String,
        reason: String = "completed",
        depotId: String? = null,
        lat: Double? = null,
        lon: Double? = null,
        traceId: String = newTraceId(),
    ): Boolean = withFleetErrors(traceId) {
        val response = stub(traceId).release(
            releaseRequest {
                this.assignmentId = assignmentId
                releaseReason = reason
                depotId?.let { this.depotId = it }
                if (lat != null && lon != null) {
                    position = com.orbitalfreight.gen.geo.v1.point {
                        this.lat = lat
                        this.lon = lon
                    }
                }
            },
        )
        response.released
    }

    /**
     * 예약하지 않고 기사 자격만 확인한다. 배차 화면이 후보 목록을 그릴 때 기사마다 부른다.
     *
     * 결과를 캐시해 두었다가 [assign]에 쓰지 말 것. 조회와 예약 사이에 기사가 상태를 바꾸는 일이
     * 실제로 일어나고, 그 간극을 메우는 것은 캐시가 아니라 서버 쪽 exclusion 제약이다.
     */
    public suspend fun checkEligibility(driverId: String, traceId: String = newTraceId()): DriverAvailability =
        withFleetErrors(traceId) {
            val response = stub(traceId).checkEligibility(
                checkEligibilityRequest { this.driverId = driverId },
            )
            DriverAvailability(
                driverId = driverId,
                ruleset = response.ruleset,
                canDrive = response.eligible,
                remainingDrivingMinutes = response.remainingDrivingMinutes,
                remainingDailyMinutes = response.remainingDrivingMinutes,
                continuousDrivingMinutes = 0,
                breakDue = response.breakDue,
                blockedBy = response.blockedBy.ifEmpty { null },
            )
        }

    // ------------------------------------------------------------------
    // HTTP — 조회 경로
    // ------------------------------------------------------------------

    /** 차량 한 대. 폐차된 차량도 그대로 온다. */
    public suspend fun vehicle(vehicleId: String, traceId: String = newTraceId()): Vehicle =
        transport.get("/v1/vehicles/$vehicleId", traceId)

    /**
     * 운송사 차량 목록 한 장. 전체를 훑으려면 [vehiclesOf]를 쓴다 — 커서 처리를 손으로 하다가
     * 마지막 장을 빠뜨리는 실수가 잦다.
     */
    public suspend fun vehiclePage(
        carrierId: String,
        cursor: String? = null,
        limit: Int = 50,
        traceId: String = newTraceId(),
    ): Page<Vehicle> {
        val query = buildString {
            append("?limit=").append(limit)
            cursor?.let { append("&cursor=").append(it) }
        }
        return transport.get("/v1/carriers/$carrierId/vehicles$query", traceId)
    }

    /**
     * 배차 목록 한 장. 세 필터(`shipment_id`, `vehicle_id`, `driver_id`) 중 최소 하나는 있어야
     * 한다 — 서버가 필터 없는 전체 스캔을 거절한다. 테넌트 전체 집계는 analytics-pipeline의 일이다.
     */
    public suspend fun assignmentPage(
        shipmentId: String? = null,
        vehicleId: String? = null,
        driverId: String? = null,
        activeOnly: Boolean = false,
        cursor: String? = null,
        limit: Int = 50,
        traceId: String = newTraceId(),
    ): Page<Assignment> {
        require(shipmentId != null || vehicleId != null || driverId != null) {
            "at least one of shipmentId, vehicleId, driverId is required"
        }
        val query = buildString {
            append("?limit=").append(limit)
            append("&active=").append(activeOnly)
            shipmentId?.let { append("&shipment_id=").append(it) }
            vehicleId?.let { append("&vehicle_id=").append(it) }
            driverId?.let { append("&driver_id=").append(it) }
            cursor?.let { append("&cursor=").append(it) }
        }
        return transport.get("/v1/assignments$query", traceId)
    }

    /** 기사의 남은 운전 가능 시간. [checkEligibility]와 같은 계산을 HTTP로 부르는 것뿐이다. */
    public suspend fun availability(driverId: String, traceId: String = newTraceId()): DriverAvailability =
        transport.get("/v1/drivers/$driverId/availability", traceId)

    /**
     * 근무 상태 변경을 올린다. 오프라인 재전송이 잦은 호출이라 멱등 키를 호출자가 고정할 수 있게
     * 열어 두었다 — 같은 상태 변경을 다시 보낼 때 반드시 같은 키를 써야 서버가 중복으로 보지 않는다.
     */
    public suspend fun postDutyStatus(
        driverId: String,
        post: DutyStatusPost,
        idempotencyKey: String = "$driverId:${post.occurredAt}:${post.status}",
        traceId: String = newTraceId(),
    ): Map<String, String> = transport.post(
        path = "/v1/drivers/$driverId/hours-of-service",
        body = json.encodeToString(DutyStatusPost.serializer(), post),
        traceId = traceId,
        idempotencyKey = idempotencyKey,
    )

    private suspend fun stub(traceId: String): FleetServiceGrpcKt.FleetServiceCoroutineStub {
        val headers = Metadata().apply {
            put(TENANT_KEY, tenantId)
            put(TRACE_KEY, traceId)
            put(AUTHORIZATION_KEY, "Bearer ${tokenProvider()}")
            put(ACTOR_KIND_KEY, "user")
        }
        return FleetServiceGrpcKt.FleetServiceCoroutineStub(channel)
            .withInterceptors(io.grpc.stub.MetadataUtils.newAttachHeadersInterceptor(headers))
    }

    /**
     * gRPC 오류를 HTTP 쪽과 같은 예외로 바꾼다. 서버가 §0.4 봉투를 `google.rpc.Status.details`에
     * 실어 주므로, 두 전송에서 나오는 [FleetApiException.code]는 완전히 같은 문자열이다.
     */
    private suspend fun <T> withFleetErrors(traceId: String, block: suspend () -> T): T =
        try {
            block()
        } catch (e: StatusException) {
            val status = StatusProto.fromThrowable(e)
            val detail = status?.detailsList?.firstOrNull()
            if (detail != null) {
                val envelope = detail.unpack(com.orbitalfreight.gen.platform.v1.ErrorEnvelope::class.java)
                throw FleetApiException(
                    code = envelope.code,
                    httpStatus = envelope.httpStatus,
                    retryable = envelope.retryable,
                    traceId = envelope.traceId.ifEmpty { traceId },
                    fields = envelope.fieldsList.map { FieldViolation(it.path, it.reason) },
                    message = envelope.message,
                )
            }
            throw FleetApiException.transport(e.status.description ?: e.status.code.name, traceId)
        }

    public companion object {
        private val TENANT_KEY = Metadata.Key.of("x-of-tenant", Metadata.ASCII_STRING_MARSHALLER)
        private val TRACE_KEY = Metadata.Key.of("x-of-trace-id", Metadata.ASCII_STRING_MARSHALLER)
        private val AUTHORIZATION_KEY = Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER)
        private val ACTOR_KIND_KEY = Metadata.Key.of("x-of-actor-kind", Metadata.ASCII_STRING_MARSHALLER)

        /**
         * 트레이스가 없을 때만 새로 만든다. 이미 있는 트레이스를 이어 주는 편이 언제나 낫다 —
         * §1.2 Diamond A에서 geo-service가 트레이스 단위로 지오펜스 해석을 캐시하기 때문에,
         * 한 흐름 안에서 트레이스를 새로 만들면 같은 계산이 두 번 일어난다.
         */
        public fun newTraceId(): String = UUID.randomUUID().toString().replace("-", "")
    }
}
