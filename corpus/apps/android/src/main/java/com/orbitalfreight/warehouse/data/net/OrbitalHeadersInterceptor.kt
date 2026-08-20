package com.orbitalfreight.warehouse.data.net

import okhttp3.Interceptor
import okhttp3.Response
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/**
 * हर बाहर जाने वाले अनुरोध पर ORBITALFREIGHT के अनिवार्य शीर्षक लगाता है।
 *
 * पाँच शीर्षक हैं और चारों सेवाओं पर एक जैसे हैं:
 *
 *  • `Authorization: Bearer <jwt>` — identity-service का RS256 टोकन, आयु 15 मिनट।
 *  • `X-OF-Tenant` — tnt_<ULID>। यह टोकन के `tid` दावे से मेल न खाए तो सर्वर
 *    सीधे `403` देता है, इसलिए दोनों एक ही स्रोत ([TokenStore]) से आते हैं।
 *  • `X-OF-Trace-Id` — 32 हेक्स अक्षर। किनारे पर अपने आप बन जाता है, पर हम इसे
 *    खुद बनाते हैं ताकि वही मान स्थानीय लॉग और कतार की पंक्ति में भी लिखा जा सके;
 *    सहायता-डेस्क का पहला सवाल हमेशा यही होता है।
 *  • `X-OF-Idempotency-Key` — हर उस अनुरोध पर जो कुछ बनाता है। यह इंटरसेप्टर
 *    इसे **नहीं** गढ़ता; कॉल करने वाला देता है, क्योंकि कुंजी पुनःप्रयासों में
 *    वही रहनी चाहिए। यहाँ केवल जाँच होती है कि गैर-GET पर वह मौजूद है।
 *  • `X-OF-Actor-Kind` — यहाँ हमेशा `user`। उपकरण का अपना क्रेडेंशियल नहीं है;
 *    कर्मचारी लॉगिन करता है और स्कैन उसी के नाम जाता है।
 *
 * जो शीर्षक यहाँ नहीं लगते: क्षेत्र। क्षेत्र URL में है (ingress प्रति क्षेत्र
 * अलग है), इसलिए `eu-west` का उपकरण `latam-br` का पता कभी बना ही नहीं सकता —
 * §7 नियम 7 का ऐप-स्तरीय रूप।
 */
@Singleton
class OrbitalHeadersInterceptor @Inject constructor(
    private val tokenStore: TokenStore,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val original = chain.request()
        val credentials = tokenStore.current()

        val traceId = original.header(HEADER_TRACE_ID) ?: newTraceId()

        val builder = original.newBuilder()
            .header("Authorization", "Bearer ${credentials.accessToken}")
            .header(HEADER_TENANT, credentials.tenantId)
            .header(HEADER_TRACE_ID, traceId)
            .header(HEADER_ACTOR_KIND, ACTOR_KIND_USER)
            .header("Accept", "application/json")

        // गैर-GET पर idempotency कुंजी अनिवार्य है (§0.3)। यह प्रोग्रामर की ग़लती
        // है, उपयोगकर्ता की नहीं, इसलिए यहाँ चुपचाप एक कुंजी गढ़ने के बजाय गिरना
        // बेहतर है — गढ़ी हुई कुंजी हर पुनःप्रयास पर बदल जाती और दोहरे स्कैन बनते।
        if (original.method != "GET" && original.header(HEADER_IDEMPOTENCY_KEY) == null) {
            error("${original.method} ${original.url.encodedPath} sent without $HEADER_IDEMPOTENCY_KEY")
        }

        return chain.proceed(builder.build())
    }

    /**
     * W3C trace-id — 32 हेक्स अक्षर, कभी पूरा शून्य नहीं (वह अमान्य माना जाता है)।
     */
    private fun newTraceId(): String {
        val bytes = ByteArray(16)
        do {
            RANDOM.nextBytes(bytes)
        } while (bytes.all { it == 0.toByte() })
        return bytes.joinToString("") { "%02x".format(it) }
    }

    companion object {
        const val HEADER_TENANT = "X-OF-Tenant"
        const val HEADER_TRACE_ID = "X-OF-Trace-Id"
        const val HEADER_IDEMPOTENCY_KEY = "X-OF-Idempotency-Key"
        const val HEADER_ACTOR_KIND = "X-OF-Actor-Kind"

        /** §0.3 के चार वैध मानों में से वह जो इस ऐप पर लागू होता है। */
        const val ACTOR_KIND_USER = "user"

        private val RANDOM = SecureRandom()
    }
}

/**
 * उपकरण पर रखे गए टोकन और उसके साथ का tenant_id।
 *
 * यह इंटरफ़ेस जान-बूझकर छोटा है: इंटरसेप्टर को केवल "अभी क्या मान्य है" चाहिए।
 * नवीनीकरण ([refresh]) अलग है और उसे OkHttp का `Authenticator` बुलाता है, तब जब
 * सर्वर `401` लौटाता है। हम पहले से समय देखकर नवीनीकरण नहीं करते — गोदाम के
 * उपकरणों की घड़ी इतनी भरोसेमंद नहीं है कि उस पर 15 मिनट की गणना टिकाई जाए।
 */
interface TokenStore {

    data class Credentials(
        val accessToken: String,
        /** tnt_<ULID>, टोकन के `tid` दावे से लिया गया। */
        val tenantId: String,
        /** usr_<ULID>, स्कैन की पंक्ति में `scanned_by_user_id` बनकर जाता है। */
        val userId: String,
    )

    fun current(): Credentials

    /**
     * `POST /v1/auth/token/refresh` चलाकर नई जोड़ी लेता है।
     *
     * यदि सर्वर बताता है कि refresh टोकन का दोबारा उपयोग हुआ है, तो पूरा
     * `refresh_family_id` मारा जा चुका है और उपकरण को नए सिरे से लॉगिन कराना
     * पड़ेगा; ऐसी स्थिति में यह विधि null लौटाती है और UI लॉगिन स्क्रीन दिखाता है।
     */
    suspend fun refresh(): Credentials?
}
