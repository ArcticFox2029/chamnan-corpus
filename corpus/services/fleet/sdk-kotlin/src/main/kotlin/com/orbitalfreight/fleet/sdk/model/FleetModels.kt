/**
 * fleet-service의 HTTP 응답 본문을 그대로 옮긴 데이터 모델이다. 필드 이름은 서버가 내보내는
 * snake_case를 [SerialName]으로 고정하고, 코틀린 쪽 이름만 관례에 맞춘다.
 *
 * 모르는 필드는 무시하도록 [kotlinx.serialization.json.Json]을 설정한다 — §4.19.3의 "알 수 없는
 * 필드는 거부하지 않는다"가 이벤트뿐 아니라 REST 응답에도 그대로 적용되기 때문이다. 서버가
 * 필드를 하나 더 붙였다고 SDK가 깨지면 배포 순서를 서비스가 아니라 클라이언트가 정하게 된다.
 */

package com.orbitalfreight.fleet.sdk.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * `fleet.vehicles` 한 대.
 *
 * @property telematicsUnitId `telemetry.device_gateways.serial`과 같은 값이다. 이 id로 게이트웨이
 *   상태를 보려면 telemetry-ingest의 API를 부른다 — fleet-service는 그 데이터를 갖고 있지 않다
 */
@Serializable
public data class Vehicle(
    @SerialName("vehicle_id") val vehicleId: String,
    @SerialName("carrier_id") val carrierId: String,
    val plate: String,
    @SerialName("plate_country") val plateCountry: String,
    @SerialName("vehicle_class") val vehicleClass: String,
    @SerialName("max_payload_kg") val maxPayloadKg: Int,
    @SerialName("adr_certified") val adrCertified: Boolean,
    @SerialName("telematics_unit_id") val telematicsUnitId: String? = null,
    @SerialName("decommissioned_at") val decommissionedAt: String? = null,
) {
    /** 사람이 읽는 식별자. 국가 코드가 없으면 번호판은 유일하지 않다. */
    public val displayPlate: String get() = "$plateCountry-$plate"

    public val isActive: Boolean get() = decommissionedAt == null
}

/**
 * `fleet.vehicle_assignments` 한 건.
 *
 * @property legId `routing.route_legs`를 가리키는 logical FK. 경로가 다시 짜이면 이 값은
 *   더 이상 존재하지 않을 수 있고, 그때 fleet-service가 `route.replanned`를 받아 배차를 푼다
 */
@Serializable
public data class Assignment(
    @SerialName("assignment_id") val assignmentId: String,
    @SerialName("vehicle_id") val vehicleId: String,
    @SerialName("driver_id") val driverId: String,
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("leg_id") val legId: String? = null,
    @SerialName("assigned_at") val assignedAt: String,
    @SerialName("released_at") val releasedAt: String? = null,
    @SerialName("assigned_by") val assignedBy: String,
) {
    public val isActive: Boolean get() = releasedAt == null
}

/**
 * 기사의 남은 근무 시간. `GET /v1/drivers/{driver_id}/availability`의 응답이자
 * `fleet.v1.FleetService/CheckEligibility`의 응답과 같은 내용이다.
 *
 * @property ruleset 서버의 `OF_FLEET_HOS_RULESET` 값 — `eu_561`, `us_fmcsa`, `none`
 * @property blockedBy 지금 배차가 막힌 이유. 막히지 않았으면 null
 */
@Serializable
public data class DriverAvailability(
    @SerialName("driver_id") val driverId: String,
    val ruleset: String,
    @SerialName("can_drive") val canDrive: Boolean,
    @SerialName("remaining_driving_minutes") val remainingDrivingMinutes: Long,
    @SerialName("remaining_daily_minutes") val remainingDailyMinutes: Long,
    @SerialName("continuous_driving_minutes") val continuousDrivingMinutes: Long,
    @SerialName("break_due") val breakDue: Boolean,
    @SerialName("blocked_by") val blockedBy: String? = null,
)

/**
 * 근무 상태 변경 요청. 기사 앱이 오프라인에서 쌓아 두었다가 한꺼번에 올리는 형태라
 * [occurredAt]과 서버 수신 시각이 크게 벌어지는 것이 정상이다.
 *
 * @property status `driving`, `on_duty_not_driving`, `off_duty`, `sleeper_berth`
 * @property occurredAt RFC 3339 UTC 문자열(§0.2). 미래 시각은 서버가 거절한다
 */
@Serializable
public data class DutyStatusPost(
    val status: String,
    @SerialName("occurred_at") val occurredAt: String,
    @SerialName("vehicle_id") val vehicleId: String? = null,
    @SerialName("odometer_km") val odometerKm: Int? = null,
    val source: String = "driver-ios",
)

/** 커서 페이지 한 장(§0.5). `nextCursor`가 null이면 마지막 장이다. */
@Serializable
public data class Page<T>(
    val items: List<T>,
    @SerialName("next_cursor") val nextCursor: String? = null,
)

/**
 * 배차 요청. gRPC `fleet.v1.FleetService/Assign`에 그대로 대응한다.
 *
 * @property legId null이면 서버가 현재 경로에서 아직 배차되지 않은 첫 구간을 고른다
 * @property allowCrossCarrier 기사와 차량의 운송사가 다를 때만 의미가 있다. 기본값은 거절
 */
public data class AssignRequest(
    val shipmentId: String,
    val vehicleId: String,
    val driverId: String,
    val assignedBy: String,
    val legId: String? = null,
    val allowCrossCarrier: Boolean = false,
)

/** 배차 결과. [warnings]에는 배차를 막지는 않은 경고(면허 임박, 휴식 임박 등)가 들어온다. */
public data class AssignResult(
    val assignmentId: String,
    val shipmentId: String,
    val legId: String?,
    val vehicleId: String,
    val driverId: String,
    val assignedAt: String,
    val warnings: List<String>,
)
