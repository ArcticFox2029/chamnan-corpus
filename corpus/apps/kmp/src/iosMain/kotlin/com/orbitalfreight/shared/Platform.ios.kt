package com.orbitalfreight.shared

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.darwin.Darwin
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSBundle
import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter
import platform.Foundation.NSLocale
import platform.Foundation.NSTimeZone
import platform.Foundation.NSUserDefaults
import platform.Foundation.localeWithLocaleIdentifier
import platform.Foundation.timeIntervalSince1970
import platform.Foundation.timeZoneWithAbbreviation
import platform.UIKit.UIDevice

/**
 * साझा कोड के `expect` का iOS रूप।
 *
 * ड्राइवर ऐप इसी को `import OrbitalShared` से देखता है। Android पक्ष से एक बड़ा
 * अंतर है और वह जान-बूझकर है: यहाँ कोई `ApplicationHolder` नहीं चाहिए, क्योंकि
 * Foundation के पास पहले से प्रक्रिया-स्तरीय पहुँच है (`NSBundle.mainBundle`,
 * `NSUserDefaults.standardUserDefaults`)। इसलिए iOS की तरफ़ कोई स्थापना-चरण नहीं
 * है, और उसे जोड़ने की कोशिश भी नहीं करनी चाहिए — दोनों मंचों को एक जैसा
 * दिखाने के लिए एक बेकार चरण जोड़ना, दोनों में एक ग़लती और डालना है।
 */
actual object Platform {
    actual val name: String = "ios"

    /** `CFBundleShortVersionString` — वही semver जो App Store पर दिखता है। */
    actual val appVersion: String
        get() = NSBundle.mainBundle.objectForInfoDictionaryKey("CFBundleShortVersionString")
            as? String ?: "0.0.0"
}

/**
 * Darwin इंजन, यानी `NSURLSession`।
 *
 * प्रमाणपत्र-पिनिंग यहाँ नहीं है: ड्राइवर ऐप उसे अपने
 * `URLSessionDelegate` में करता है, क्योंकि वहीं वह प्रमाणपत्र पड़ा है जो
 * MDM से आता है। साझा मॉड्यूल में पिनिंग लाने का मतलब होता उस प्रमाणपत्र को
 * यहाँ लाना, और तब हर बार उसके बदलने पर साझा मॉड्यूल का नया संस्करण छोड़ना पड़ता।
 */
@OptIn(ExperimentalForeignApi::class)
actual fun createHttpEngine(): HttpClientEngine = Darwin.create {
    configureSession {
        setAllowsCellularAccess(true)
        // बंदरगाह पर सिग्नल टूटता-जुड़ता रहता है; प्रतीक्षा करने से अनुरोध
        // अनिश्चित काल तक लटका रहता था और ऊपर की समय-सीमा भी उसे नहीं काटती थी।
        setWaitsForConnectivity(false)
    }
}

/**
 * टोकन का भंडार।
 *
 * यहाँ `NSUserDefaults` दिखता है पर टोकन उसमें नहीं जाते — केवल वे मान जो
 * गोपनीय नहीं हैं (tenant, user, समाप्ति)। असली टोकन Keychain में हैं, और
 * Keychain तक पहुँच Swift की तरफ़ है: ड्राइवर ऐप में वह कोड पहले से मौजूद था और
 * उसे Kotlin/Native में दोबारा लिखने का कोई लाभ नहीं था, इसलिए यह वर्ग उसी
 * Swift परत को [KeychainBridge] के ज़रिए बुलाता है।
 */
actual class TokenVault actual constructor() {

    private val defaults = NSUserDefaults.standardUserDefaults

    actual fun read(): Credentials? {
        val accessToken = KeychainBridge.shared?.accessToken() ?: return null
        return Credentials(
            accessToken = accessToken,
            refreshToken = KeychainBridge.shared?.refreshToken().orEmpty(),
            tenantId = defaults.stringForKey(KEY_TENANT_ID).orEmpty(),
            userId = defaults.stringForKey(KEY_USER_ID).orEmpty(),
            expiresAtEpochSeconds = defaults.doubleForKey(KEY_EXPIRES_AT).toLong(),
        )
    }

    actual fun write(credentials: Credentials) {
        KeychainBridge.shared?.store(credentials.accessToken, credentials.refreshToken)
        defaults.setObject(credentials.tenantId, KEY_TENANT_ID)
        defaults.setObject(credentials.userId, KEY_USER_ID)
        defaults.setDouble(credentials.expiresAtEpochSeconds.toDouble(), KEY_EXPIRES_AT)
    }

    actual fun clear() {
        KeychainBridge.shared?.clear()
        defaults.removeObjectForKey(KEY_TENANT_ID)
        defaults.removeObjectForKey(KEY_USER_ID)
        defaults.removeObjectForKey(KEY_EXPIRES_AT)
    }

    private companion object {
        const val KEY_TENANT_ID = "of_tenant_id"
        const val KEY_USER_ID = "of_user_id"
        const val KEY_EXPIRES_AT = "of_expires_at"
    }
}

/**
 * वह छोटी सतह जिसे Swift लागू करता है और ऐप शुरू होते ही [shared] में रखता है।
 *
 * इसे इंटरफ़ेस रखने से साझा कोड Keychain के बारे में कुछ नहीं जानता, और परीक्षण
 * में इसकी जगह एक स्मृति-आधारित रूप रखा जा सकता है।
 */
interface KeychainBridge {
    fun accessToken(): String?
    fun refreshToken(): String?
    fun store(accessToken: String, refreshToken: String)
    fun clear()

    companion object {
        /** ड्राइवर ऐप के `AppDelegate` से एक बार भरा जाता है। */
        var shared: KeychainBridge? = null
    }
}

/**
 * उपकरण का क्रमांक।
 *
 * iOS पर असली क्रमांक किसी ऐप को नहीं मिलता, इसलिए `identifierForVendor` ही
 * उपलब्ध सबसे स्थिर मान है। यह ऐप हटाने पर बदल जाता है — और यही कारण है कि
 * `freight.shipment_scan_events.device_serial` को कभी पहचान की तरह नहीं
 * बरता जाता; वह केवल यह बताने के लिए है कि किस उपकरण से स्कैन आया।
 */
actual fun deviceSerial(): String =
    UIDevice.currentDevice.identifierForVendor?.UUIDString ?: "ios-unknown"

/**
 * RFC 3339, UTC, अंत में `Z` (§0.2)।
 *
 * लोकेल `en_US_POSIX` होना अनिवार्य है। यह वह जाल है जिसमें यह फ़ाइल एक बार फँस
 * चुकी है: उपयोगकर्ता के लोकेल पर छोड़ने से बौद्ध या फ़ारसी कैलेंडर वाले उपकरण
 * `2569-…` जैसी तिथि भेजते हैं, सर्वर उसे विधिवत स्वीकार कर लेता है, और वह
 * स्कैन विश्लेषण में पाँच सौ साल आगे बैठ जाता है।
 */
actual fun nowRfc3339(): String {
    val formatter = NSDateFormatter()
    formatter.locale = NSLocale.localeWithLocaleIdentifier("en_US_POSIX")
    formatter.timeZone = NSTimeZone.timeZoneWithAbbreviation("UTC")!!
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.stringFromDate(NSDate())
}

actual fun nowEpochSeconds(): Long = NSDate().timeIntervalSince1970.toLong()
