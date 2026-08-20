package com.orbitalfreight.shared

import com.orbitalfreight.shared.model.Container
import com.orbitalfreight.shared.model.IdempotencyKeys
import com.orbitalfreight.shared.model.Position
import com.orbitalfreight.shared.model.Scan
import com.orbitalfreight.shared.model.Shipment
import io.ktor.client.request.parameter
import io.ktor.http.HttpMethod
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * container-registry (§3.3, HTTP 8083) का क्लाइंट — शिपमेंट, डिब्बे और स्कैन-पथ।
 *
 * यह उस सेवा का *पूरा* मुख वाला हिस्सा नहीं है, केवल वह जो मोबाइल से चलता है।
 * तीन पथ जान-बूझकर बाहर हैं:
 *
 *  • `POST /v1/containers` — डिब्बा पंजीकरण डिपो कार्यालय का काम है।
 *  • `DELETE /v1/shipments/{shipment_id}/containers/{container_id}` — सील लगने
 *    से पहले ही चलता है और केवल कंसोल से।
 *  • `freight.v1.ContainerLookup/ResolveShipmentForContainer` — वह gRPC है और
 *    telemetry-ingest के गरम रास्ते के लिए है; मोबाइल उसे कभी नहीं छूता।
 *
 * स्थिति बदलने का एक ही वैध रास्ता `PATCH …/status` है। ऐप कहीं और से स्थिति
 * नहीं बदल सकता, और यह सीमा सर्वर की है — यहाँ केवल दोहराई गई है ताकि पढ़ने
 * वाला दूसरा रास्ता ढूँढने न निकले।
 */
class ContainerRegistryClient(private val http: OrbitalHttpClient) {

    /** `GET /v1/shipments/{shipment_id}` — डिब्बों सहित पूरा शिपमेंट। */
    suspend fun shipment(shipmentId: String, traceId: String? = null): Shipment =
        http.send(HttpMethod.Get, "/v1/shipments/$shipmentId", traceId = traceId)

    /**
     * `GET /v1/containers` — BIC कोड, सील या शिपमेंट से खोज।
     *
     * तीनों फ़िल्टर एक साथ देने का कोई अर्थ नहीं है और सर्वर उन्हें AND की तरह
     * लेता है; व्यवहार में स्कैनर हमेशा एक ही देता है — वही जो बारकोड में था।
     */
    suspend fun findContainers(
        isoCode: String? = null,
        seal: String? = null,
        shipmentId: String? = null,
        limit: Int = OrbitalHttpClient.DEFAULT_PAGE_LIMIT,
        cursor: String? = null,
    ): Page<Container> {
        require(limit in 1..OrbitalHttpClient.MAX_PAGE_LIMIT) {
            "limit must be between 1 and ${OrbitalHttpClient.MAX_PAGE_LIMIT} (§0.5)"
        }
        return http.send(HttpMethod.Get, "/v1/containers") {
            isoCode?.let { parameter("iso_code", it) }
            seal?.let { parameter("seal", it) }
            shipmentId?.let { parameter("shipment_id", it) }
            parameter("limit", limit)
            cursor?.let { parameter("cursor", it) }
        }
    }

    /**
     * `POST /v1/containers/{container_id}/scans` — एक स्कैन दर्ज करता है।
     *
     * सफल होने पर सेवा `shipment.scanned` को `platform.outbox_messages` में
     * लिखती है और उसका relay उसे `of.freight.v1` पर प्रकाशित करता है। ऐप उस
     * घटना का उपभोक्ता नहीं है — जो कुछ उसे वापस चाहिए वह इसी उत्तर में है।
     *
     * @param idempotencyKey कतार की पंक्ति के साथ बँधी कुंजी। हर पुनःप्रयास पर
     *        वही भेजनी है; नई कुंजी का अर्थ है वही स्कैन दूसरी बार दर्ज होना।
     */
    suspend fun recordScan(
        containerId: String,
        request: RecordScanRequest,
        idempotencyKey: String,
        traceId: String? = null,
    ): Scan = http.send(
        method = HttpMethod.Post,
        path = "/v1/containers/$containerId/scans",
        body = request,
        idempotencyKey = idempotencyKey,
        traceId = traceId,
    )

    /** `GET /v1/shipments/{shipment_id}/scans` — स्कैन का इतिहास, नया पहले। */
    suspend fun scanTrail(
        shipmentId: String,
        limit: Int = OrbitalHttpClient.DEFAULT_PAGE_LIMIT,
        cursor: String? = null,
    ): Page<Scan> = http.send(HttpMethod.Get, "/v1/shipments/$shipmentId/scans") {
        parameter("limit", limit)
        cursor?.let { parameter("cursor", it) }
    }

    /**
     * `PATCH /v1/shipments/{shipment_id}/status` — स्थिति बदलने का एकमात्र रास्ता।
     *
     * मोबाइल से केवल दो संक्रमण चलते हैं और दोनों गोदाम/गेट पर होते हैं:
     * `booked` → `sealed` और `sealed` → `in_transit`। बाकी या तो
     * `customs.declaration.*` घटनाओं से आते हैं, या चेतावनी से (`at_risk`), या
     * कंसोल से। सर्वर वैसे भी अवैध संक्रमण को `409` देता है — यह टिप्पणी इसलिए
     * है कि कोई नई स्क्रीन बनाते समय तीसरा संक्रमण जोड़ने से पहले रुक जाए।
     */
    suspend fun changeStatus(
        shipmentId: String,
        toStatus: String,
        reasonCode: String,
        idempotencyKey: String = IdempotencyKeys.newIdempotencyKey(),
        traceId: String? = null,
    ): Shipment = http.send(
        method = HttpMethod.Patch,
        path = "/v1/shipments/$shipmentId/status",
        body = ChangeStatusRequest(status = toStatus, reasonCode = reasonCode),
        idempotencyKey = idempotencyKey,
        traceId = traceId,
    )
}

/**
 * स्कैन का शरीर।
 *
 * `recorded_at` यहाँ नहीं है और होना भी नहीं चाहिए — वह सर्वर की घड़ी है।
 * `scanned_by_user_id` भी नहीं: वह टोकन से आता है, और उसे शरीर में भेजने देना
 * एक ऐसा रास्ता खोलता है जिससे कोई दूसरे के नाम स्कैन दर्ज कर सके।
 */
@Serializable
data class RecordScanRequest(
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("scan_type") val scanType: String,
    @SerialName("occurred_at") val occurredAt: String,
    @SerialName("facility_id") val facilityId: String? = null,
    val position: Position? = null,
    @SerialName("device_serial") val deviceSerial: String,
    val notes: String? = null,
)

@Serializable
data class ChangeStatusRequest(
    val status: String,
    /** यही `shipment.status.changed` में `reason_code` बनकर जाता है। */
    @SerialName("reason_code") val reasonCode: String,
)
