package com.orbitalfreight.warehouse.sync

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.orbitalfreight.warehouse.data.db.dao.ScanOutboxDao
import com.orbitalfreight.warehouse.data.db.entity.ScanOutboxEntity
import com.orbitalfreight.warehouse.data.net.ContainerRegistryApi
import com.orbitalfreight.warehouse.data.net.ErrorEnvelope
import com.orbitalfreight.warehouse.data.net.OrbitalHeadersInterceptor
import com.orbitalfreight.warehouse.data.net.PositionPayload
import com.orbitalfreight.warehouse.data.net.RecordScanRequest
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.serialization.json.Json
import java.io.IOException
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * ऑफ़लाइन कतार को container-registry तक पहुँचाने वाला रिले।
 *
 * यह वर्कर वही भूमिका निभाता है जो सर्वर पर हर सेवा का outbox रिले निभाता है:
 * लिखने वाला कोड नेटवर्क नहीं छूता, और नेटवर्क छूने वाला कोड कोई निर्णय नहीं लेता।
 * स्कैन का सत्य पहले ही स्थानीय डेटाबेस में लिखा जा चुका है; यहाँ केवल उसे आगे
 * बढ़ाया जाता है।
 *
 * तीन बातें जो अनुभव से यहाँ पहुँचीं:
 *
 *  1. **क्रम मायने रखता है।** एक ही शिपमेंट के स्कैन occurred_at के क्रम में
 *     जाते हैं। तार पर क्रम की एकमात्र गारंटी partition_key = shipment_id है, और
 *     वह तभी काम की है जब हम उलटे क्रम में न भेजें। एक बार gate_out पहले चला गया
 *     और विश्लेषण में डिब्बा गोदाम से निकलकर फिर अंदर आता दिखा।
 *  2. **`retryable` ही निर्णायक है, HTTP कोड नहीं।** §0.4 का लिफ़ाफ़ा यह साफ़
 *     बताता है, और `409 shipment_already_sealed` को दोहराना अनंत लूप है।
 *  3. **एक विफलता पूरा बैच नहीं रोकती।** हर पंक्ति स्वतंत्र है; एक sealed शिपमेंट
 *     की वजह से बाक़ी उन्नीस स्कैन रुक जाना गोदाम को खड़ा कर देता था।
 */
@HiltWorker
class ScanOutboxWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val dao: ScanOutboxDao,
    private val api: ContainerRegistryApi,
    private val json: Json,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val batch = dao.claimPendingScans(BATCH_SIZE)
        if (batch.isEmpty()) {
            pruneOldRows()
            return Result.success()
        }

        var transientFailures = 0

        for (scan in batch) {
            when (send(scan)) {
                Outcome.SENT -> Unit
                Outcome.PERMANENT -> Unit
                Outcome.TRANSIENT -> transientFailures++
            }
        }

        pruneOldRows()

        // यदि कोई पंक्ति अस्थायी कारण से रुकी है तो पूरा वर्कर retry माँगता है;
        // WorkManager का अपना बैकऑफ़ 500 ms से शुरू होकर घातीय बढ़ता है, वही
        // अंतराल जो §4.19 उपभोक्ताओं के लिए तय करता है।
        return if (transientFailures > 0) Result.retry() else Result.success()
    }

    private suspend fun send(scan: ScanOutboxEntity): Outcome {
        val request = RecordScanRequest(
            shipmentId = scan.shipmentId,
            scanType = scan.scanType,
            occurredAt = scan.occurredAt,
            facilityId = scan.facilityId,
            position = scan.latitude?.let { lat ->
                scan.longitude?.let { lon -> PositionPayload(lat = lat, lon = lon) }
            },
            deviceSerial = scan.deviceSerial,
            notes = scan.notes,
        )

        return try {
            val response = api.recordScan(
                containerId = scan.containerId,
                idempotencyKey = scan.idempotencyKey,
                body = request,
            )
            val traceId = response.headers()[OrbitalHeadersInterceptor.HEADER_TRACE_ID]

            if (response.isSuccessful) {
                val body = response.body()
                if (body == null) {
                    // 2xx पर खाली शरीर का अर्थ है प्रॉक्सी ने कुछ काटा है।
                    // scn_ के बिना तस्वीर नहीं जुड़ सकती, इसलिए दोबारा भेजना ही
                    // सही है — कुंजी वही है, सर्वर पर दूसरा स्कैन नहीं बनेगा।
                    dao.markScanFailed(scan.localId, "empty_response_body", traceId)
                    return Outcome.TRANSIENT
                }
                dao.markScanSent(scan.localId, body.scanId)
                return Outcome.SENT
            }

            val envelope = response.errorBody()?.string()?.let { raw ->
                runCatching { json.decodeFromString<ErrorEnvelope>(raw) }.getOrNull()
            }
            val code = envelope?.error?.code
            val retryable = envelope?.error?.retryable ?: (response.code() >= 500)

            if (retryable) {
                dao.markScanFailed(scan.localId, code, envelope?.error?.traceId ?: traceId)
                Outcome.TRANSIENT
            } else {
                // sealed शिपमेंट, अमान्य scan_type, या दूसरे किरायेदार का डिब्बा।
                // यह दोबारा भेजने से नहीं सुधरेगा; पंक्ति सहायता-डेस्क के लिए
                // रुकती है, ठीक वैसे ही जैसे विषाक्त संदेश DLQ में जाता है।
                dao.markScanDead(scan.localId, code, envelope?.error?.traceId ?: traceId)
                Outcome.PERMANENT
            }
        } catch (io: IOException) {
            // कोई नेटवर्क नहीं — गोदाम की सामान्य स्थिति, चेतावनी लायक भी नहीं।
            dao.markScanFailed(scan.localId, "network_unreachable", null)
            Outcome.TRANSIENT
        }
    }

    /**
     * भेजे जा चुके स्कैन सात दिन बाद हटते हैं। यह वर्कर के अंत में इसलिए चलता है
     * और शुरुआत में नहीं कि खाली कतार पर भी सफ़ाई हो — दिन में एक भी स्कैन न होने
     * वाला उपकरण (छुट्टी वाला डिपो) भी तालिका बढ़ने नहीं देता।
     */
    private suspend fun pruneOldRows() {
        val cutoff = Instant.now().minus(RETENTION_DAYS, ChronoUnit.DAYS).toString()
        dao.pruneSentScans(cutoff)
    }

    private enum class Outcome { SENT, TRANSIENT, PERMANENT }

    companion object {
        const val UNIQUE_NAME = "of-scan-outbox-relay"

        /**
         * एक बार में बीस। बड़ा बैच गोदाम के Wi-Fi पर टाइमआउट के क़रीब पहुँचता है
         * और तब पूरा बैच दोबारा जाता है; छोटा बैच वर्कर को बार-बार जगाता है।
         */
        private const val BATCH_SIZE = 20

        private const val RETENTION_DAYS = 7L
    }
}
