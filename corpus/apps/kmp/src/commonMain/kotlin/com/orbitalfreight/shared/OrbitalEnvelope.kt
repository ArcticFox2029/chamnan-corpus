package com.orbitalfreight.shared

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * ORBITALFREIGHT की हर सेवा एक ही आकार में विफल होती है, और यह फ़ाइल उसी आकार
 * का Kotlin रूप है (§0.4)।
 *
 * यह क्यों मायने रखता है: चौदह सेवाएँ नौ भाषाओं में लिखी हैं, पर उनका
 * त्रुटि-लिफ़ाफ़ा एक है। इसका मतलब है कि मोबाइल की तरफ़ त्रुटि संभालने का *एक ही*
 * रास्ता चाहिए — HTTP कोड देखकर अंदाज़ा लगाने का नहीं। `code` सार्वजनिक अनुबंध का
 * हिस्सा है और बदलता नहीं, इसलिए UI उसी पर संदेश चुनता है; `message` केवल
 * सहायता-डेस्क के लिए है और उसमें असली पहचान (shp_…) होती है जो उपयोगकर्ता को
 * दिखाने लायक नहीं।
 */
@Serializable
data class ErrorEnvelope(
    val error: ErrorBody,
)

@Serializable
data class ErrorBody(
    /** `snake_case`, स्थिर, अनुबंध का हिस्सा — जैसे `shipment_already_sealed`। */
    val code: String,

    @SerialName("http_status") val httpStatus: Int,

    /** मनुष्य के पढ़ने के लिए, अनुवादित नहीं; इसमें पहचानें खुली होती हैं। */
    val message: String,

    @SerialName("trace_id") val traceId: String? = null,

    /**
     * यही तय करता है कि पंक्ति दोबारा भेजी जाए या मार दी जाए। HTTP कोड अकेला
     * काफ़ी नहीं — 409 दोनों हो सकता है: "सील अपरिवर्तनीय है" (अंतिम) और
     * "समवर्ती लेखन, फिर कोशिश करें" (दोबारा भेजने योग्य)।
     */
    val retryable: Boolean = false,

    /** किस खेत में क्या ग़लत है; फ़ॉर्म वाली स्क्रीनें इसी से लाल निशान लगाती हैं। */
    val fields: List<FieldError> = emptyList(),
)

@Serializable
data class FieldError(
    /** JSON पथ, जैसे `containers[0].seal_number`। */
    val path: String,
    val reason: String,
)

/**
 * वह अपवाद जो [OrbitalHttpClient] गैर-2xx उत्तर पर फेंकता है।
 *
 * इसमें लिफ़ाफ़ा जस का तस रखा जाता है ताकि कतार वाला कोड `retryable` पढ़ सके और
 * UI वाला कोड `code`। दोनों को एक ही अपवाद से काम चल जाता है, इसलिए हर सेवा के
 * लिए अलग अपवाद-वंश बनाने की ज़रूरत कभी नहीं पड़ी।
 */
class OrbitalApiException(
    val body: ErrorBody,
    /** उस अनुरोध का trace-id, चाहे सर्वर ने लिफ़ाफ़े में लौटाया हो या नहीं। */
    val traceId: String,
) : Exception("${body.code} (${body.httpStatus}): ${body.message}") {

    val retryable: Boolean get() = body.retryable

    /**
     * क्या यह विफलता टोकन की है — यानी लॉगिन दोबारा चाहिए।
     *
     * `403` को यहाँ जान-बूझकर शामिल नहीं किया गया: वह अधिकार की कमी है, पहचान
     * की नहीं, और उस पर लॉगिन स्क्रीन दिखाना उपयोगकर्ता को उसी दीवार पर बार-बार
     * पटकता है। एक अपवाद है — `X-OF-Tenant` का बेमेल — पर वह अपने कोड
     * (`tenant_mismatch`) से पहचाना जाता है, स्थिति-कोड से नहीं।
     */
    val needsReauthentication: Boolean
        get() = body.httpStatus == 401 || body.code == "tenant_mismatch"
}

/**
 * §0.5 का पेज लिफ़ाफ़ा। मंच पर ऑफ़सेट पेजिनेशन कहीं नहीं है, इसलिए यहाँ भी नहीं है।
 *
 * [nextCursor] का `null` होना ही सूची के पूरे होने का एकमात्र संकेत है — खाली
 * [items] का मतलब अंत नहीं होता, क्योंकि फ़िल्टर लगे पेज बीच में खाली आ सकते हैं।
 */
@Serializable
data class Page<T>(
    val items: List<T>,
    @SerialName("next_cursor") val nextCursor: String? = null,
) {
    val hasMore: Boolean get() = nextCursor != null
}

/**
 * सेवाओं की सूची जिनसे मोबाइल क्लाइंट बात करते हैं, उनके §1 वाले नामों के साथ।
 *
 * नाम शाब्दिक हैं और वैसे ही लॉग में जाते हैं, इसलिए सहायता-डेस्क का ग्राफ़
 * और उपकरण के लॉग एक ही शब्दावली बोलते हैं। मोबाइल शेष दस सेवाओं को कभी सीधे
 * नहीं छूता — जो चाहिए वह इन्हीं चार से होकर आता है।
 */
enum class OrbitalService(val serviceName: String, val httpPort: Int) {
    IDENTITY("identity-service", 8081),
    CONTAINER_REGISTRY("container-registry", 8083),
    TELEMETRY_INGEST("telemetry-ingest", 8084),
    DOCUMENT("document-service", 8089),
    ;

    /** कंटेनर-भीतर का पता; ऐप बाहर से ingress के ज़रिए आता है, यह केवल लॉग के लिए है। */
    val clusterAddress: String
        get() = "http://$serviceName.orbitalfreight.svc.cluster.local:$httpPort"
}
