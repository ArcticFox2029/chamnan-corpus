package com.orbitalfreight.warehouse.data.net

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.MultipartBody
import okhttp3.RequestBody
import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.Multipart
import retrofit2.http.POST
import retrofit2.http.Part
import retrofit2.http.Query

/**
 * document-service (Node/NestJS, HTTP 8089) — केवल क्षति की तस्वीरें चढ़ाने और
 * पहले से चढ़ी तस्वीरें ढूँढ़ने के लिए।
 *
 * उपकरण कभी बाइट नहीं उतारता। `GET /v1/documents/{document_id}` केवल मेटाडेटा
 * देता है और असली फ़ाइल के लिए `POST /v1/documents/{document_id}/signed-url`
 * चाहिए, जिसकी आयु 15 मिनट है — गोदाम की स्क्रीन पर पुरानी तस्वीर दिखाने की
 * कोई ज़रूरत ही नहीं पड़ी, इसलिए वह पथ यहाँ नहीं है।
 *
 * चढ़ाने से पहले ऐप स्वयं SHA-256 गिनता है और उसे साथ भेजता है। इसका कारण
 * §1.2 का Diamond B है: वही तस्वीर दूसरी बार आने पर सेवा `documents.sha256` से
 * दोहराव पकड़कर पुराना `doc_` लौटा देती है, नया blob नहीं लिखती। हमारी ओर से
 * यह इसलिए मायने रखता है कि नेटवर्क टूटने पर वर्कर वही फ़ाइल दोबारा भेजता है और
 * हमें दो doc_ नहीं चाहिए।
 */
interface DocumentServiceApi {

    /**
     * `POST /v1/documents` — multipart।
     *
     * `owner_type` को सेवा `platform.document_owner_types` के विरुद्ध जाँचती है
     * और फिर मालिक सेवा से पूछती है कि वह id सचमुच है या नहीं। इसीलिए तस्वीर
     * तभी भेजी जाती है जब स्कैन का scn_ मिल चुका हो — पहले भेजने पर सेवा `404`
     * के साथ `owner_not_found` लौटाती है।
     */
    @Multipart
    @POST("v1/documents")
    suspend fun uploadDocument(
        @Header(OrbitalHeadersInterceptor.HEADER_IDEMPOTENCY_KEY) idempotencyKey: String,
        @Part("owner_type") ownerType: RequestBody,
        @Part("owner_id") ownerId: RequestBody,
        @Part("kind") kind: RequestBody,
        @Part("region_code") regionCode: RequestBody,
        @Part("sha256") sha256Hex: RequestBody,
        @Part file: MultipartBody.Part,
    ): Response<DocumentResponse>

    /**
     * किसी स्कैन से जुड़े दस्तावेज़ — `GET /v1/documents?owner_type=&owner_id=&kind=`।
     * वर्कर इसे तब चलाता है जब उसे शक हो कि पिछली बार तस्वीर चढ़ गई थी पर उत्तर
     * रास्ते में खो गया; मिल जाने पर स्थानीय पंक्ति बिना दोबारा भेजे बंद हो जाती है।
     */
    @GET("v1/documents")
    suspend fun findDocuments(
        @Query("owner_type") ownerType: String,
        @Query("owner_id") ownerId: String,
        @Query("kind") kind: String? = null,
        @Query("limit") limit: Int = 50,
    ): Response<PageResponse<DocumentResponse>>
}

@Serializable
data class DocumentResponse(
    /** doc_<ULID> */
    @SerialName("document_id") val documentId: String,
    @SerialName("tenant_id") val tenantId: String,
    @SerialName("owner_type") val ownerType: String,
    @SerialName("owner_id") val ownerId: String,
    val kind: String,
    @SerialName("mime_type") val mimeType: String,
    @SerialName("byte_size") val byteSize: Long,
    /** हेक्स में, वैसा ही जैसा `document.uploaded` घटना में जाता है। */
    val sha256: String,
    @SerialName("region_code") val regionCode: String,
    @SerialName("uploaded_by") val uploadedBy: String,
    @SerialName("uploaded_at") val uploadedAt: String,
    /** सीमा-शुल्क वाले दस्तावेज़ों पर दस साल; क्षति की तस्वीरों पर आमतौर पर null। */
    @SerialName("retained_until") val retainedUntil: String? = null,
)

/**
 * §0.4 का त्रुटि लिफ़ाफ़ा। हर सेवा यही लौटाती है, इसलिए इसे एक ही जगह रखा गया है।
 *
 * [ErrorBody.retryable] ही तय करता है कि कतार की पंक्ति दोबारा उठेगी या सीधे
 * `dead` होगी — यही वजह है कि वर्कर HTTP स्थिति-कोड पर निर्णय नहीं लेता। एक ही
 * `409` कभी दोहराने लायक होता है (आशावादी टकराव) और कभी नहीं (`shipment_already_sealed`)।
 */
@Serializable
data class ErrorEnvelope(val error: ErrorBody)

@Serializable
data class ErrorBody(
    val code: String,
    @SerialName("http_status") val httpStatus: Int,
    val message: String,
    @SerialName("trace_id") val traceId: String? = null,
    val retryable: Boolean = false,
    val fields: List<ErrorField> = emptyList(),
)

@Serializable
data class ErrorField(val path: String, val reason: String)
