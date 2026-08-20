package com.orbitalfreight.warehouse

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.orbitalfreight.warehouse.sync.DamagePhotoUploadWorker
import com.orbitalfreight.warehouse.sync.ScanOutboxWorker
import dagger.hilt.android.HiltAndroidApp
import java.util.concurrent.TimeUnit
import javax.inject.Inject

/**
 * गोदाम स्कैनर ऐप का प्रवेश-बिंदु।
 *
 * यह क्लास तीन काम करती है और तीसरा ही असली वजह है कि यह मौजूद है:
 *
 * 1. Hilt का ग्राफ़ खड़ा करती है और WorkManager को उसका फ़ैक्टरी देती है
 *    (मेनिफ़ेस्ट में डिफ़ॉल्ट इनिशियलाइज़र हटाया गया है)।
 * 2. `telemetry.alert.raised` से बने पुश संदेशों के लिए सूचना-चैनल बनाती है।
 * 3. दो आवधिक वर्कर पंजीकृत करती है जो ऑफ़लाइन कतार खाली करते हैं। गोदाम में
 *    Wi-Fi ढाँचागत रूप से भरोसेमंद नहीं है — रैक की धातु दीवारें सिग्नल खा जाती
 *    हैं — इसलिए स्कैन पहले स्थानीय डेटाबेस में लिखा जाता है और भेजना हमेशा
 *    पृष्ठभूमि का काम है। उपयोगकर्ता को कभी "भेजा जा रहा है" वाला डायलॉग नहीं
 *    दिखता; वह अगला बॉक्स स्कैन करता रहता है।
 *
 * यह ढाँचा जान-बूझकर सर्वर के `platform.outbox_messages` जैसा ही है: स्थिति-परिवर्तन
 * और उसका प्रेषण एक ही लेन-देन में लिखे जाते हैं, फिर एक रिले उन्हें उठाता है।
 */
@HiltAndroidApp
class WarehouseScannerApp : Application(), Configuration.Provider {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .setMinimumLoggingLevel(if (BuildConfig.DEBUG) android.util.Log.DEBUG else android.util.Log.INFO)
            .build()

    override fun onCreate() {
        super.onCreate()
        registerAlertChannel()
        schedulePeriodicSync()
    }

    /**
     * notification-service `push` चैनल पर जो संदेश भेजती है वे यहीं उतरते हैं।
     * महत्व IMPORTANCE_HIGH है क्योंकि तापमान-विचलन (`temp_excursion_high`) पर
     * कर्मचारी को रीफ़र तक पहुँचने के लिए मिनट भर मिलते हैं, घंटे नहीं।
     */
    private fun registerAlertChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            getString(R.string.alert_channel_id),
            getString(R.string.alert_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "telemetry-ingest alerts for containers handled at this depot"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * दोनों वर्कर UNIQUE नाम से जुड़ते हैं ताकि ऐप के हर बार खुलने पर नई शृंखला न बने।
     *
     * अंतराल अलग-अलग हैं और यह सोच-समझकर है: स्कैन छोटे JSON हैं और जल्दी जाने
     * चाहिए, जबकि क्षति की तस्वीरें कई मेगाबाइट की हैं और उन्हें बिना-मीटर वाले
     * कनेक्शन का इंतज़ार करने देना सस्ता पड़ता है। WorkManager का न्यूनतम आवधिक
     * अंतराल 15 मिनट है, इसलिए तात्कालिक प्रेषण के लिए ScanViewModel अलग से
     * एक बार वाला अनुरोध भी लगाता है।
     */
    private fun schedulePeriodicSync() {
        val workManager = WorkManager.getInstance(this)

        workManager.enqueueUniquePeriodicWork(
            ScanOutboxWorker.UNIQUE_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<ScanOutboxWorker>(15, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .build(),
        )

        workManager.enqueueUniquePeriodicWork(
            DamagePhotoUploadWorker.UNIQUE_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<DamagePhotoUploadWorker>(1, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.UNMETERED)
                        .setRequiresBatteryNotLow(true)
                        .setRequiresStorageNotLow(true)
                        .build(),
                )
                .build(),
        )
    }
}
