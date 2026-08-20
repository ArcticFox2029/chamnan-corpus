package com.orbitalfreight.warehouse.data.net

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * container-registry (Kotlin/Ktor, HTTP 8083) का वह हिस्सा जिसे गोदाम स्कैनर छूता है।
 *
 * ऐप इस सेवा के अलावा केवल दो और से बात करता है: identity-service (टोकन) और
 * document-service (क्षति की तस्वीरें)। telemetry-ingest से यह कुछ नहीं माँगता —
 * तापमान-चेतावनियाँ पुश से आती हैं, क्योंकि उन्हें उठाने के लिए उपकरण का जागना
 * ज़रूरी नहीं होना चाहिए।
 *
 * यहाँ जो पथ नहीं हैं वे भी उतने ही सोच-समझकर छोड़े गए हैं:
 * `POST /v1/containers` (डिब्बा पंजीकरण) डिपो कार्यालय का काम है, गोदाम के फ़र्श
 * का नहीं, और `DELETE /v1/shipments/{id}/containers/{container_id}` केवल कंसोल
 * से चलता है।
 */
interface ContainerRegistryApi {

    /** शिपमेंट, डिब्बों सहित — `GET /v1/shipments/{shipment_id}`। */
    @GET("v1/shipments/{shipment_id}")
    suspend fun getShipment(
        @Path("shipment_id") shipmentId: String,
    ): Response<ShipmentResponse>

    /**
     * BIC कोड या सील से खोज। §0.5 के अनुसार केवल कर्सर पेजिनेशन है; `limit` का
     * अधिकतम 200 है और सूची स्क्रीन 50 माँगती है।
     */
    @GET("v1/containers")
    suspend fun findContainers(
        @Query("iso_code") isoCode: String? = null,
        @Query("seal") seal: String? = null,
        @Query("shipment_id") shipmentId: String? = null,
        @Query("limit") limit: Int = 50,
        @Query("cursor") cursor: String? = null,
    ): Response<PageResponse<ContainerResponse>>

    /**
     * स्कैन दर्ज करता है — `POST /v1/containers/{container_id}/scans`।
     *
     * सफल होने पर container-registry `shipment.scanned` प्रकाशित करता है
     * (`of.freight.v1`, partition_key = shipment_id)। ऐप उस घटना का उपभोक्ता नहीं
     * है; यह केवल जानने योग्य है कि proof_of_delivery वाला स्कैन billing-service
     * के लिए चालान का द्वार खोल देता है, इसलिए वह प्रकार ग़लती से भेजा नहीं जा सकता —
     * ScanViewModel उसे केवल तभी दिखाता है जब शिपमेंट की स्थिति in_transit हो।
     */
    @POST("v1/containers/{container_id}/scans")
    suspend fun recordScan(
        @Path("container_id") containerId: String,
        @Header(OrbitalHeadersInterceptor.HEADER_IDEMPOTENCY_KEY) idempotencyKey: String,
        @Body body: RecordScanRequest,
    ): Response<ScanResponse>

    /** स्कैन का इतिहास, नया पहले — `GET /v1/shipments/{shipment_id}/scans`। */
    @GET("v1/shipments/{shipment_id}/scans")
    suspend fun getScanTrail(
        @Path("shipment_id") shipmentId: String,
        @Query("limit") limit: Int = 50,
        @Query("cursor") cursor: String? = null,
    ): Response<PageResponse<ScanResponse>>

    /**
     * स्थिति बदलने का एकमात्र वैध रास्ता — `PATCH /v1/shipments/{shipment_id}/status`।
     *
     * गोदाम से केवल दो संक्रमण चलते हैं: `booked` → `sealed` (सारे डिब्बे लद गए
     * और सील लग गई) और `sealed` → `in_transit` (वाहन गेट से निकल गया)। बाकी छह
     * स्थितियाँ या तो customs-service की घटनाओं से आती हैं या कंसोल से।
     */
    @PATCH("v1/shipments/{shipment_id}/status")
    suspend fun changeStatus(
        @Path("shipment_id") shipmentId: String,
        @Header(OrbitalHeadersInterceptor.HEADER_IDEMPOTENCY_KEY) idempotencyKey: String,
        @Body body: ChangeStatusRequest,
    ): Response<ShipmentResponse>
}

/** §0.5 का पेज लिफ़ाफ़ा। `next_cursor` null होने का अर्थ है सूची पूरी हुई। */
@Serializable
data class PageResponse<T>(
    val items: List<T>,
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
data class ShipmentResponse(
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("tenant_id") val tenantId: String,
    val reference: String,
    @SerialName("origin_facility_id") val originFacilityId: String,
    @SerialName("destination_facility_id") val destinationFacilityId: String,
    val incoterm: String,
    val status: String,
    @SerialName("sla_deadline_at") val slaDeadlineAt: String? = null,
    @SerialName("region_code") val regionCode: String,
    /** जोड़ी की पंक्तियाँ — सील नंबर यहीं आता है, डिब्बे पर नहीं। */
    val containers: List<ShipmentContainerResponse> = emptyList(),
)

@Serializable
data class ShipmentContainerResponse(
    @SerialName("container_id") val containerId: String,
    @SerialName("seal_number") val sealNumber: String,
    @SerialName("gross_kg") val grossKg: Int,
    @SerialName("loaded_at") val loadedAt: String? = null,
    @SerialName("unloaded_at") val unloadedAt: String? = null,
    val container: ContainerResponse? = null,
)

@Serializable
data class ContainerResponse(
    @SerialName("container_id") val containerId: String,
    @SerialName("iso_code") val isoCode: String,
    @SerialName("iso_size_type") val isoSizeType: String,
    @SerialName("is_reefer") val isReefer: Boolean = false,
    @SerialName("setpoint_c") val setpointC: Double? = null,
    @SerialName("max_gross_kg") val maxGrossKg: Int,
    @SerialName("last_reading_at") val lastReadingAt: String? = null,
    @SerialName("hazard_classes") val hazardClasses: List<HazardClassResponse> = emptyList(),
)

@Serializable
data class HazardClassResponse(
    @SerialName("hazard_class_code") val hazardClassCode: String,
    @SerialName("is_primary") val isPrimary: Boolean = false,
)

@Serializable
data class RecordScanRequest(
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("scan_type") val scanType: String,
    /**
     * घटना का समय, उपकरण की घड़ी से, RFC 3339 UTC। सर्वर `recorded_at` अपने आप
     * भरता है — दोनों का अंतर ही ऑफ़लाइन बीता समय है।
     */
    @SerialName("occurred_at") val occurredAt: String,
    @SerialName("facility_id") val facilityId: String? = null,
    val position: PositionPayload? = null,
    @SerialName("device_serial") val deviceSerial: String,
    val notes: String? = null,
)

/** GeoJSON नहीं — तार पर सादा जोड़ी, वैसी ही जैसी `shipment.scanned` में जाती है। */
@Serializable
data class PositionPayload(val lat: Double, val lon: Double)

@Serializable
data class ScanResponse(
    @SerialName("scan_id") val scanId: String,
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("container_id") val containerId: String? = null,
    @SerialName("scan_type") val scanType: String,
    @SerialName("scanned_by_user_id") val scannedByUserId: String,
    @SerialName("occurred_at") val occurredAt: String,
    @SerialName("recorded_at") val recordedAt: String,
    val notes: String? = null,
)

@Serializable
data class ChangeStatusRequest(
    val status: String,
    /** क्यों बदला — यह `shipment.status.changed` में `reason_code` बनकर जाता है। */
    @SerialName("reason_code") val reasonCode: String,
)
