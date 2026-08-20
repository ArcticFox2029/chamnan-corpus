package com.orbitalfreight.tracking

import android.content.Intent
import android.os.Bundle
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.facebook.react.uimanager.ViewManager

/**
 * Android की ओर का देशी पुल — iOS वाले `OFPushBridge` का जुड़वाँ, उसी नाम से
 * उजागर, ताकि JavaScript की तरफ़ कोई मंच-विशेष शाखा न रहे।
 *
 * यहाँ भी वही तीन काम हैं: FCM का टोकन देना, वह सूचना देना जिस पर टैप करके ऐप
 * खुला, और चलते ऐप में आई सूचनाओं को `of.notification.received` के रूप में ऊपर
 * भेजना। सूचनाएँ notification-service (§3.10) से आती हैं और उन्हें
 * `OF_NOTIFY_PUSH_FCM_KEY_PATH` वाली कुंजी से भेजा जाता है।
 *
 * **यह क्लास FCM की सेवा नहीं है।** `FirebaseMessagingService` का उत्तराधिकारी
 * ऐप के अपने कोड में है और वह यहाँ के स्थिर तरीक़ों को बुलाता है। दोनों को एक
 * करने की कोशिश की गई थी और वह इसलिए टूटी कि FCM की सेवा तब भी चलती है जब
 * React का ब्रिज मौजूद ही नहीं होता — प्रक्रिया केवल सूचना के लिए जागती है।
 * इसलिए यहाँ का हर स्थिर रास्ता ब्रिज के न होने को सामान्य मानकर लिखा गया है।
 */
class OFPushBridgeModule(
    private val reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = MODULE_NAME

    /**
     * FCM का उपकरण-टोकन।
     *
     * टोकन अभी न आया हो तो वादा रोका जाता है, अस्वीकार नहीं — अस्वीकार करने पर
     * लॉगिन बिना टोकन के पूरा हो जाता था और ग्राहक को कोई सूचना नहीं मिलती थी।
     */
    @ReactMethod
    fun deviceToken(promise: Promise) {
        val token = cachedToken
        if (token != null) {
            promise.resolve(token)
            return
        }
        pendingTokenPromises.add(promise)
    }

    /**
     * वह सूचना जिस पर टैप करके ऐप खुला — केवल एक बार।
     *
     * Android पर यह `Intent` के extras में आती है, इसलिए इसे Activity के
     * `onNewIntent` से भी सौंपा जाता है: पहले से चल रहे ऐप पर सूचना टैप करने से
     * नई Activity नहीं बनती और तब `launchIntent` पुराना ही रह जाता।
     */
    @ReactMethod
    fun launchNotification(promise: Promise) {
        val payload = launchPayload
        launchPayload = null
        promise.resolve(payload)
    }

    /** RCTEventEmitter की शर्त; Android पर खाली रहते हैं पर होने अनिवार्य हैं। */
    @ReactMethod
    fun addListener(eventName: String) = Unit

    @ReactMethod
    fun removeListeners(count: Int) = Unit

    companion object {
        const val MODULE_NAME = "OFPushBridge"

        private const val EVENT_NAME = "of.notification.received"

        private var cachedToken: String? = null
        private var launchPayload: WritableMap? = null
        private val pendingTokenPromises = mutableListOf<Promise>()

        /** ऐप की `FirebaseMessagingService` से, `onNewToken` पर। */
        @JvmStatic
        fun storeDeviceToken(token: String) {
            cachedToken = token
            pendingTokenPromises.forEach { it.resolve(token) }
            pendingTokenPromises.clear()
        }

        /**
         * सूचना पर टैप करके खुलने वाला रास्ता — Activity के `Intent` से।
         *
         * तीन ही कुंजियाँ पढ़ी जाती हैं और तीनों notification-service के पेलोड
         * में हमेशा होती हैं। बाकी extras (Android के अपने) जान-बूझकर छोड़ दिए
         * जाते हैं: उन्हें आगे भेजने से JS को वह कचरा मिलता है जिसका उसके पास
         * कोई अर्थ नहीं।
         */
        @JvmStatic
        fun captureLaunchIntent(intent: Intent?) {
            val extras: Bundle = intent?.extras ?: return
            val eventId = extras.getString("source_event_id") ?: return

            launchPayload = Arguments.createMap().apply {
                putString("template_code", extras.getString("template_code") ?: "unknown")
                putString("source_event_id", eventId)
                extras.getString("shipment_id")?.let { putString("shipment_id", it) }
                extras.getString("invoice_id")?.let { putString("invoice_id", it) }
            }
        }

        /**
         * चलते ऐप में आई सूचना।
         *
         * ब्रिज के न होने पर यहाँ कुछ नहीं होता, और वह सामान्य है: प्रक्रिया
         * केवल सूचना के लिए जागी थी, ऐप खुला ही नहीं है। सूचना ट्रे में रहती है
         * और टैप करने पर [captureLaunchIntent] वाला रास्ता चलता है।
         */
        @JvmStatic
        fun deliverNotification(context: ReactApplicationContext?, payload: Map<String, String>) {
            val bridgeContext = context ?: return
            if (!bridgeContext.hasActiveReactInstance()) {
                return
            }
            val event = Arguments.createMap().apply {
                payload.forEach { (key, value) -> putString(key, value) }
            }
            bridgeContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                .emit(EVENT_NAME, event)
        }
    }
}

/**
 * पैकेज पंजीकरण — `MainApplication` की `getPackages()` इसी को लौटाती है।
 *
 * यह उसी फ़ाइल में है क्योंकि इस ऐप में केवल एक ही देशी मॉड्यूल है और दोनों
 * हमेशा साथ बदलते हैं; अलग फ़ाइल का अर्थ होता एक ऐसी फ़ाइल जो कभी अकेले नहीं
 * खुलती।
 */
class OFTrackingPackage : ReactPackage {

    override fun createNativeModules(context: ReactApplicationContext): List<NativeModule> =
        listOf(OFPushBridgeModule(context))

    /** कोई कस्टम दृश्य नहीं; पूरी UI JavaScript की तरफ़ है। */
    override fun createViewManagers(context: ReactApplicationContext): List<ViewManager<*, *>> =
        emptyList()
}
