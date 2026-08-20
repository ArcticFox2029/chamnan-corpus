package com.orbitalfreight.shared

import io.ktor.client.engine.HttpClientEngine

/**
 * वे थोड़ी-सी चीज़ें जो साझा कोड को चाहिए पर हर मंच पर अलग हैं।
 *
 * सूची जान-बूझकर छोटी रखी गई है। हर `expect` का मतलब है दो जगह लिखा और दो जगह
 * जाँचा गया कोड, इसलिए यहाँ केवल वही आया है जिसका कोई साझा रूप है ही नहीं:
 * HTTP इंजन, सुरक्षित भंडारण, उपकरण का क्रमांक और घड़ी।
 *
 * जो यहाँ **नहीं** है, और क्यों:
 *  • लॉगिंग — दोनों ऐप Ktor के अपने लॉगर पर हैं।
 *  • JSON — kotlinx.serialization दोनों मंचों पर एक ही है।
 *  • क्षेत्र (`region_code`) — वह बिल्ड के समय तय होता है, चलने के समय नहीं;
 *    §7 नियम 7 के अनुसार एक ही उपकरण दो क्षेत्रों में कभी नहीं होता।
 */
expect object Platform {

    /** `android` या `ios`; केवल लॉग और `User-Agent` में जाता है। */
    val name: String

    /** ऐप का संस्करण, `/version` से लौटने वाले semver जैसा ही रूप। */
    val appVersion: String
}

/**
 * मंच का HTTP इंजन — Android पर OkHttp, iOS पर Darwin (NSURLSession)।
 *
 * इंजन साझा नहीं हो सकता क्योंकि प्रमाणपत्र-पिनिंग दोनों जगह मंच की अपनी
 * व्यवस्था से होती है, और वही इस विभाजन का असली कारण है: पिनिंग को साझा कोड में
 * ले जाने का मतलब है दोनों मंचों पर अपना TLS सत्यापन लिखना, जो हर सुरक्षा
 * समीक्षा में (सही ही) रोक दिया गया।
 */
expect fun createHttpEngine(): HttpClientEngine

/**
 * टोकन का सुरक्षित भंडार — Android पर EncryptedSharedPreferences, iOS पर Keychain।
 *
 * यहाँ पाँच मान रहते हैं और पाँचों एक साथ बदलते हैं, इसलिए इंटरफ़ेस एक ही
 * [Credentials] पर चलता है: आधा-अद्यतन भंडार (नया टोकन, पुराना tenant) वह
 * स्थिति है जिसमें हर अनुरोध `403` लाता है और कारण कहीं नहीं दिखता।
 */
expect class TokenVault() {

    /** भंडार से मौजूदा पहचान; कभी लॉगिन न हुआ हो तो `null`। */
    fun read(): Credentials?

    /** पूरा सेट एक साथ लिखता है। */
    fun write(credentials: Credentials)

    /** लॉगआउट या `401` पर सब कुछ मिटा देता है। */
    fun clear()
}

/**
 * एक खुला सत्र, वैसा ही जैसा identity-service ने `POST /v1/auth/token` पर दिया।
 *
 * [accessToken] की आयु 15 मिनट है (`OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS`), इसलिए
 * [expiresAtEpochSeconds] को समय से पहले पढ़कर टोकन बदलना ज़रूरी है — समाप्त
 * टोकन के साथ भेजा गया स्कैन `401` लाता है और कतार में एक बेकार प्रयास गिनता है।
 */
data class Credentials(
    val accessToken: String,
    val refreshToken: String,
    /** tnt_<ULID> — टोकन के `tid` दावे से मेल खाना अनिवार्य है, वरना `403`। */
    val tenantId: String,
    /** usr_<ULID> — स्कैन इसी के नाम दर्ज होते हैं। */
    val userId: String,
    val expiresAtEpochSeconds: Long,
) {
    /**
     * टोकन की समाप्ति से एक मिनट पहले ही उसे "बासी" मान लिया जाता है। एक मिनट
     * इसलिए कि गोदाम का धीमा Wi-Fi और उपकरण की घड़ी का हल्का विचलन दोनों इसी
     * खिड़की में समा जाते हैं।
     */
    fun isStale(nowEpochSeconds: Long): Boolean =
        nowEpochSeconds >= expiresAtEpochSeconds - 60
}

/**
 * उपकरण का क्रमांक, जो हर स्कैन के साथ `device_serial` बनकर जाता है और
 * `freight.shipment_scan_events.device_serial` में उतरता है।
 *
 * यह `telemetry.device_gateways.serial` नहीं है — वह डिपो में लगे गेटवे का
 * क्रमांक है और उसे मोबाइल कभी नहीं भेजता। दोनों को मिलाने से टेलीमेट्री की
 * पंक्तियाँ उस गेटवे से जुड़ने लगती हैं जो कभी अस्तित्व में ही नहीं था।
 */
expect fun deviceSerial(): String

/**
 * अभी का समय, RFC 3339 UTC में, अंत में `Z` (§0.2)।
 *
 * उपकरण की घड़ी ही एकमात्र स्रोत है — सर्वर का समय पूछकर लिखना ऑफ़लाइन स्कैन के
 * लिए काम ही नहीं करता, और वहीं यह फ़ील्ड सबसे ज़्यादा मायने रखती है।
 */
expect fun nowRfc3339(): String

/** युग से बीते सेकंड, टोकन की समाप्ति जाँचने के लिए। */
expect fun nowEpochSeconds(): Long
