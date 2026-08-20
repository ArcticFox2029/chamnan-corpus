package com.orbitalfreight.shared

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * साझा कोड के `expect` का Android रूप।
 *
 * यहाँ की सबसे नाज़ुक चीज़ [ApplicationHolder] है — एक स्थिर `Context`। यह सामान्यतः
 * ग़लत है और यहाँ भी सुखद नहीं, पर विकल्प इससे बुरे थे: हर `expect` फ़ंक्शन में
 * `Context` जोड़ने से साझा हस्ताक्षर iOS पर अर्थहीन हो जाते, और DI को साझा
 * मॉड्यूल में लाने का मतलब दोनों ऐप पर एक ही DI ढाँचा थोपना होता। इसलिए
 * `Application` का context (Activity का नहीं) एक बार रखा जाता है और लीक नहीं होता।
 */
object ApplicationHolder {

    @SuppressLint("StaticFieldLeak")
    private var applicationContext: Context? = null

    /** ऐप के `onCreate` से एक बार बुलाया जाता है, किसी और जगह से नहीं। */
    fun install(context: Context) {
        applicationContext = context.applicationContext
    }

    internal fun require(): Context = requireNotNull(applicationContext) {
        "ApplicationHolder.install(context) must run in Application.onCreate()"
    }
}

actual object Platform {
    actual val name: String = "android"

    /**
     * संस्करण पैकेज-प्रबंधक से पढ़ा जाता है, बिल्ड-स्थिरांक से नहीं: साझा मॉड्यूल
     * का अपना `BuildConfig` होता है और वह ऐप के संस्करण से अलग होता है, जिससे
     * लॉग में दो अलग संख्याएँ दिखने लगती थीं।
     */
    actual val appVersion: String
        get() {
            val context = ApplicationHolder.require()
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            return info.versionName ?: "0.0.0"
        }
}

/**
 * OkHttp इंजन, ऐप की अपनी पिनिंग और प्रॉक्सी व्यवस्था के साथ।
 *
 * समय-सीमाएँ यहाँ नहीं लगाई जातीं — वे [OrbitalHttpClient] के `HttpTimeout`
 * में हैं, ताकि दोनों मंचों पर एक ही संख्या रहे। दो जगह समय-सीमा रखने पर छोटी
 * वाली चुपचाप जीतती है और दूसरी जगह लिखी संख्या झूठ बन जाती है।
 */
actual fun createHttpEngine(): HttpClientEngine = OkHttp.create {
    config {
        retryOnConnectionFailure(false)
        followRedirects(false)
    }
}

/**
 * टोकन का भंडार — `EncryptedSharedPreferences`, यानी कुंजी Android Keystore में।
 *
 * फ़ाइल का नाम `of_credentials` वही है जो पुरानी Java स्क्रीनें
 * ({@code legacy.LegacyScanStore}) पढ़ती हैं। दोनों को एक ही फ़ाइल पर रखना
 * ज़रूरी है: अलग फ़ाइल का मतलब होता कि गेट पर खुला सत्र पुरानी स्क्रीन को दिखता
 * ही नहीं और वह हर स्कैन `401` पर मार देती।
 */
actual class TokenVault actual constructor() {

    private val preferences by lazy {
        val context = ApplicationHolder.require()
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            PREFERENCES_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    actual fun read(): Credentials? {
        val accessToken = preferences.getString(KEY_ACCESS_TOKEN, null) ?: return null
        return Credentials(
            accessToken = accessToken,
            refreshToken = preferences.getString(KEY_REFRESH_TOKEN, "").orEmpty(),
            tenantId = preferences.getString(KEY_TENANT_ID, "").orEmpty(),
            userId = preferences.getString(KEY_USER_ID, "").orEmpty(),
            expiresAtEpochSeconds = preferences.getLong(KEY_EXPIRES_AT, 0L),
        )
    }

    /** पाँचों मान एक ही commit में; आधा-लिखा भंडार हर अनुरोध को `403` कर देता है। */
    actual fun write(credentials: Credentials) {
        preferences.edit()
            .putString(KEY_ACCESS_TOKEN, credentials.accessToken)
            .putString(KEY_REFRESH_TOKEN, credentials.refreshToken)
            .putString(KEY_TENANT_ID, credentials.tenantId)
            .putString(KEY_USER_ID, credentials.userId)
            .putLong(KEY_EXPIRES_AT, credentials.expiresAtEpochSeconds)
            .apply()
    }

    actual fun clear() {
        // उपकरण का क्रमांक और तैनाती की सुविधा यहाँ नहीं हैं — वे लॉगआउट पर
        // मिटनी नहीं चाहिए, क्योंकि उपकरण वहीं का वहीं रहता है।
        preferences.edit()
            .remove(KEY_ACCESS_TOKEN)
            .remove(KEY_REFRESH_TOKEN)
            .remove(KEY_TENANT_ID)
            .remove(KEY_USER_ID)
            .remove(KEY_EXPIRES_AT)
            .apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "of_credentials"
        const val KEY_ACCESS_TOKEN = "access_token"
        const val KEY_REFRESH_TOKEN = "refresh_token"
        const val KEY_TENANT_ID = "tenant_id"
        const val KEY_USER_ID = "user_id"
        const val KEY_EXPIRES_AT = "expires_at"
    }
}

/**
 * उपकरण का क्रमांक।
 *
 * Android 10 से `Build.getSerial()` सामान्य ऐप को नहीं मिलता, पर गोदाम के Zebra
 * उपकरण प्रबंधित तैनाती में हैं और वहाँ यह मान प्रावधान के समय ही
 * `of_credentials` में लिख दिया जाता है। इसलिए क्रम यही है: पहले भंडार, फिर
 * `Build.SERIAL`, और अंत में मॉडल का नाम — जो पहचान तो नहीं है पर लॉग में
 * "unknown" से बेहतर पढ़ा जाता है।
 */
actual fun deviceSerial(): String {
    val preferences = ApplicationHolder.require()
        .getSharedPreferences("of_credentials", Context.MODE_PRIVATE)
    preferences.getString("device_serial", null)?.let { return it }

    @Suppress("DEPRECATION")
    val legacySerial = Build.SERIAL
    if (legacySerial != null && legacySerial != Build.UNKNOWN) {
        return legacySerial
    }
    return "${Build.MANUFACTURER}-${Build.MODEL}"
}

/** RFC 3339, UTC, अंत में `Z` — मिलीसेकंड सहित, वैसे ही जैसे सर्वर लिखता है। */
actual fun nowRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date())
}

actual fun nowEpochSeconds(): Long = System.currentTimeMillis() / 1000L
