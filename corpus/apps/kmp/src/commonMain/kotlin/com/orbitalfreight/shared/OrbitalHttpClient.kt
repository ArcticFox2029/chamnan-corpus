package com.orbitalfreight.shared

import com.orbitalfreight.shared.model.IdempotencyKeys
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

/**
 * वह एकमात्र जगह जहाँ से दोनों मोबाइल ऐप ORBITALFREIGHT को छूते हैं।
 *
 * इसका पूरा काम चार बातों में है:
 *
 * 1. **§0.3 के अनिवार्य शीर्षक लगाना** — पाँचों, हर अनुरोध पर, बिना अपवाद के।
 *    `X-OF-Idempotency-Key` केवल तभी जब कॉल करने वाला दे; यह क्लाइंट उसे गढ़ता
 *    नहीं, क्योंकि गढ़ी हुई कुंजी हर पुनःप्रयास पर बदल जाती और वही स्कैन दो बार
 *    दर्ज हो जाता।
 * 2. **§0.4 का लिफ़ाफ़ा खोलना** — गैर-2xx उत्तर [OrbitalApiException] बनकर आता है,
 *    जिसमें `code` और `retryable` दोनों बचे रहते हैं।
 * 3. **टोकन ताज़ा रखना** — अनुरोध भेजने से पहले, न कि `401` मिलने के बाद।
 *    प्रतिक्रिया में टोकन बदलने का मतलब है वही अनुरोध दोबारा भेजना, और
 *    गैर-idempotent अनुरोध पर वह सुरक्षित नहीं।
 * 4. **trace-id जोड़ना और लौटाना** — वही मान स्थानीय लॉग में भी लिखा जाता है,
 *    क्योंकि सहायता-डेस्क का पहला सवाल हमेशा यही होता है।
 *
 * जो यह **नहीं** करता: पुनःप्रयास। दोनों ऐप की अपनी कतार है (Android पर
 * WorkManager, iOS पर एक background task), और उन्हें ही तय करना चाहिए कि कब
 * दोबारा भेजा जाए — यहाँ लूप रखने का मतलब है कतार के बैकऑफ़ के भीतर एक और
 * अदृश्य बैकऑफ़।
 */
class OrbitalHttpClient(
    /** ingress का आधार पता, प्रति क्षेत्र अलग; अंत में स्लैश नहीं। */
    private val baseUrl: String,
    private val vault: TokenVault,
    engine: io.ktor.client.engine.HttpClientEngine = createHttpEngine(),
) {

    private val json = Json {
        // §4.19 नियम 3 का क्लाइंट-रूप: अनजान खेत छोड़ दिए जाते हैं, अस्वीकार नहीं।
        // सेवाएँ एक ही `schema_version` के भीतर खेत जोड़ती रहती हैं और पुराना
        // उपकरण महीनों तक बिना अपडेट के चलता है।
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    private val client = HttpClient(engine) {
        install(ContentNegotiation) { json(json) }
        install(HttpTimeout) {
            // सेवाओं का अपना बजट 60 सेकंड का है; उपकरण उससे पहले हार मानकर
            // पंक्ति को कतार में लौटा देता है, वरना कर्मचारी स्क्रीन पर अटका रहता है।
            requestTimeoutMillis = 30_000
            connectTimeoutMillis = 10_000
            socketTimeoutMillis = 20_000
        }
        defaultRequest {
            header("User-Agent", "orbitalfreight-mobile/${Platform.appVersion} (${Platform.name})")
            header(HEADER_ACTOR_KIND, ACTOR_KIND_USER)
        }
        expectSuccess = false
    }

    /**
     * एक अनुरोध भेजता है और उत्तर को [T] में खोलता है।
     *
     * @param idempotencyKey केवल उन अनुरोधों पर जो कुछ बनाते या शुल्क लगाते हैं
     *        (§0.3)। पुनःप्रयास में यही कुंजी दोबारा भेजनी है — नई कुंजी बनाना
     *        इस पूरी व्यवस्था की सबसे महँगी ग़लती है।
     * @param traceId कतार वाली पंक्ति के साथ बँधा trace-id, ताकि पुनःप्रयास भी
     *        उसी धागे पर दिखे; न देने पर नया बनता है।
     */
    suspend inline fun <reified T> send(
        method: HttpMethod,
        path: String,
        body: Any? = null,
        idempotencyKey: String? = null,
        traceId: String? = null,
        noinline query: (HttpRequestBuilder.() -> Unit)? = null,
    ): T {
        val response = execute(method, path, body, idempotencyKey, traceId, query)
        return response.body()
    }

    /**
     * वही, पर उत्तर का शरीर लौटाए बिना — `POST /v1/alerts/{alert_id}/acknowledge`
     * जैसे पथों के लिए जो `204` देते हैं।
     */
    suspend fun sendIgnoringBody(
        method: HttpMethod,
        path: String,
        body: Any? = null,
        idempotencyKey: String? = null,
        traceId: String? = null,
    ) {
        execute(method, path, body, idempotencyKey, traceId, null)
    }

    @PublishedApi
    internal suspend fun execute(
        method: HttpMethod,
        path: String,
        body: Any?,
        idempotencyKey: String?,
        traceId: String?,
        query: (HttpRequestBuilder.() -> Unit)?,
    ): HttpResponse {
        val credentials = requireNotNull(vault.read()) {
            "no session on this device; POST /v1/auth/token first"
        }

        val effectiveTraceId = traceId ?: IdempotencyKeys.newTraceId()

        val response = client.request("$baseUrl$path") {
            this.method = method
            header("Authorization", "Bearer ${credentials.accessToken}")
            header(HEADER_TENANT, credentials.tenantId)
            header(HEADER_TRACE_ID, effectiveTraceId)
            if (idempotencyKey != null) {
                header(HEADER_IDEMPOTENCY_KEY, idempotencyKey)
            }
            if (body != null) {
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            query?.invoke(this)
        }

        if (!response.status.isSuccess()) {
            throw toApiException(response, effectiveTraceId)
        }
        return response
    }

    /**
     * गैर-2xx उत्तर को [OrbitalApiException] में बदलता है।
     *
     * यदि शरीर लिफ़ाफ़े के आकार का नहीं है — जो केवल तब होता है जब उत्तर सेवा से
     * नहीं बल्कि बीच के ingress या WAF से आया हो — तो एक कृत्रिम लिफ़ाफ़ा बनाया
     * जाता है जिसका `code` = `gateway_error` है। इसे `retryable` माना जाता है,
     * क्योंकि ऐसे उत्तर लगभग हमेशा क्षणिक होते हैं और उन्हें अंतिम मान लेने पर
     * कतार की पंक्तियाँ बेवजह मर जाती थीं।
     */
    @PublishedApi
    internal suspend fun toApiException(response: HttpResponse, traceId: String): OrbitalApiException {
        val raw = response.bodyAsText()
        val body = runCatching { json.decodeFromString<ErrorEnvelope>(raw).error }
            .getOrElse {
                ErrorBody(
                    code = "gateway_error",
                    httpStatus = response.status.value,
                    message = raw.take(200).ifBlank { response.status.description },
                    traceId = traceId,
                    retryable = true,
                )
            }
        return OrbitalApiException(body, body.traceId ?: traceId)
    }

    fun close() {
        client.close()
    }

    companion object {
        /** §0.3 के शीर्षक; वर्तनी सर्वर से अक्षरशः मेल खानी चाहिए। */
        const val HEADER_TENANT = "X-OF-Tenant"
        const val HEADER_TRACE_ID = "X-OF-Trace-Id"
        const val HEADER_IDEMPOTENCY_KEY = "X-OF-Idempotency-Key"
        const val HEADER_ACTOR_KIND = "X-OF-Actor-Kind"

        /**
         * मोबाइल हमेशा `user` है। उपकरण का अपना क्रेडेंशियल नहीं होता —
         * `device` केवल किनारे के गेटवे के लिए है, जो telemetry-ingest पर
         * हस्ताक्षरित बैच भेजते हैं।
         */
        const val ACTOR_KIND_USER = "user"

        /** §0.5 — `limit` की ऊपरी सीमा 200, डिफ़ॉल्ट 50। */
        const val MAX_PAGE_LIMIT = 200
        const val DEFAULT_PAGE_LIMIT = 50
    }
}
