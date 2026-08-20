package com.orbitalfreight.warehouse.legacy;

import android.app.Notification;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.core.app.NotificationCompat;

import com.orbitalfreight.warehouse.BuildConfig;
import com.orbitalfreight.warehouse.R;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.Charset;
import java.security.SecureRandom;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * पुरानी अपलोड सेवा, जो {@link LegacySealCheckActivity} के हर सबमिट पर जागती है
 * और <code>scan_outbox</code> की लंबित पंक्तियाँ container-registry के
 * <code>POST /v1/containers/{container_id}/scans</code> पर भेजती है।
 *
 * <p>यह {@code ScanOutboxWorker} की नकल है, पर WorkManager से पहले की। दोनों एक
 * ही तालिका पर चलते हैं और यही इस व्यवस्था को सुरक्षित बनाता है: दोनों में से जो
 * भी पहले पंक्ति उठाए, वह उसे {@code sent} कर देता है, और
 * {@code idempotency_key} पंक्ति के साथ बँधी होने की वजह से दोनों के एक साथ
 * चलने पर भी सर्वर पर दूसरा scn_ नहीं बनता — बस दूसरा अनुरोध वही उत्तर पाता है।</p>
 *
 * <p>तो यह अब भी क्यों है? क्योंकि गेट पर खड़ा कर्मचारी सील जाँच के तुरंत बाद
 * पुष्टि देखना चाहता है, और WorkManager अपनी अगली विंडो का इंतज़ार कर सकता है।
 * यह सेवा उस इंतज़ार को हटा देती है और फिर खुद रुक जाती है।</p>
 *
 * <p><b>सीमाएँ, जो जान-बूझकर हैं:</b> एक बार में बीस पंक्तियों से ज़्यादा नहीं;
 * कोई बैकऑफ़ नहीं (वह वर्कर का काम है); और 5xx मिलने पर पंक्ति वापस
 * {@code pending} रह जाती है ताकि रात का वर्कर उसे उठा ले।</p>
 */
public class LegacyScanUploadService extends Service {

    private static final String TAG = "OFLegacyUpload";

    private static final int NOTIFICATION_ID = 4121;

    /** एक जागरण में इससे ज़्यादा पंक्तियाँ नहीं; बाकी वर्कर के लिए छोड़ी जाती हैं। */
    private static final int BATCH_SIZE = 20;

    /** गेट का Wi-Fi सुस्त है पर टूटा नहीं; दस सेकंड से ज़्यादा इंतज़ार बेकार है। */
    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int READ_TIMEOUT_MS = 15_000;

    private static final Charset UTF_8 = Charset.forName("UTF-8");

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final SecureRandom random = new SecureRandom();

    private LegacyScanStore store;

    /** Activity से एक ही जगह से शुरू होती है, ताकि intent का आकार यहीं तय रहे। */
    static void start(Context context) {
        Intent intent = new Intent(context, LegacyScanUploadService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        store = new LegacyScanStore(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startInForeground();
        final int currentStartId = startId;
        executor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    drainQueue();
                } catch (RuntimeException error) {
                    // कतार में पंक्तियाँ बची रह जाती हैं और अगला जागरण उन्हें
                    // उठा लेगा; यहाँ गिरना उपयोगकर्ता को कुछ नहीं बताता।
                    Log.e(TAG, "drain aborted", error);
                }
                stopSelf(currentStartId);
            }
        });
        // START_NOT_STICKY: सिस्टम इसे दोबारा शुरू न करे। कतार खाली करना वर्कर की
        // भी ज़िम्मेदारी है, इसलिए मरने के बाद कुछ खोता नहीं।
        return START_NOT_STICKY;
    }

    /**
     * लंबित स्कैन एक-एक करके भेजती है।
     *
     * <p>क्रम मायने रखता है: पंक्तियाँ {@code occurred_at} के क्रम में उठती हैं,
     * इसलिए एक ही डिब्बे का gate_in उसके seal_check से पहले पहुँचता है। सर्वर
     * क्रम नहीं थोपता — <code>shipment.scanned</code> का partition_key
     * {@code shipment_id} है, यानी क्रम की गारंटी प्रति शिपमेंट है, और वह
     * गारंटी तभी अर्थ रखती है जब उपकरण खुद क्रम बिगाड़कर न भेजे।</p>
     */
    private void drainQueue() {
        List<LegacyScanStore.PendingScan> pending = store.pendingScans(BATCH_SIZE);
        if (pending.isEmpty()) {
            return;
        }
        Log.i(TAG, "draining " + pending.size() + " queued scans");

        for (LegacyScanStore.PendingScan scan : pending) {
            String traceId = newTraceId();
            try {
                String scanId = postScan(scan, traceId);
                if (scanId != null) {
                    store.markSent(scan.localId, scanId, traceId);
                }
            } catch (Exception error) {
                Log.w(TAG, "scan " + scan.localId + " failed on trace " + traceId, error);
                store.markFailed(scan.localId, scan.attempts, "transport_error", traceId);
            }
        }
    }

    /**
     * एक स्कैन भेजती है और उसका scn_ लौटाती है।
     *
     * @return scn_&lt;ULID&gt;, या {@code null} जब सर्वर ने पंक्ति अस्वीकार की
     *         (4xx) — उस स्थिति में दोबारा भेजना बेकार है और पंक्ति यहीं
     *         {@code dead} कर दी जाती है
     */
    private String postScan(LegacyScanStore.PendingScan scan, String traceId) throws Exception {
        URL url = new URL(BuildConfig.CONTAINER_REGISTRY_BASE_URL
                + "/v1/containers/" + scan.containerId + "/scans");

        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setRequestMethod("POST");
        connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
        connection.setReadTimeout(READ_TIMEOUT_MS);
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Accept", "application/json");
        connection.setRequestProperty("Authorization", "Bearer " + store.accessToken());
        connection.setRequestProperty("X-OF-Tenant", store.tenantId());
        connection.setRequestProperty("X-OF-Trace-Id", traceId);
        connection.setRequestProperty("X-OF-Idempotency-Key", scan.idempotencyKey);
        connection.setRequestProperty("X-OF-Actor-Kind", "user");

        try {
            OutputStream output = connection.getOutputStream();
            output.write(buildBody(scan).toString().getBytes(UTF_8));
            output.flush();
            output.close();

            int status = connection.getResponseCode();
            if (status >= 200 && status < 300) {
                JSONObject body = readJson(connection.getInputStream());
                return body.optString("scan_id", null);
            }

            // §0.4 का त्रुटि-लिफ़ाफ़ा। `retryable` ही तय करता है कि पंक्ति दोबारा
            // भेजी जाए या मार दी जाए — HTTP कोड अकेला काफ़ी नहीं, क्योंकि 409
            // दोनों हो सकता है (सील बदली नहीं जा सकती = अंतिम; समवर्ती लेखन =
            // दोबारा भेजने योग्य)।
            JSONObject failure = readJson(connection.getErrorStream());
            JSONObject error = failure.optJSONObject("error");
            String code = error != null ? error.optString("code", "unknown") : "unknown";
            boolean retryable = error != null && error.optBoolean("retryable", false);

            if (retryable) {
                store.markFailed(scan.localId, scan.attempts, code, traceId);
            } else {
                Log.e(TAG, "scan " + scan.localId + " rejected as " + code + " (" + status + ")");
                store.markFailed(scan.localId, 8, code, traceId);
            }
            return null;
        } finally {
            connection.disconnect();
        }
    }

    /** वही आकार जो {@code RecordScanRequest} तार पर भेजता है। */
    private JSONObject buildBody(LegacyScanStore.PendingScan scan) throws JSONException {
        JSONObject body = new JSONObject();
        body.put("shipment_id", scan.shipmentId);
        body.put("scan_type", scan.scanType);
        body.put("occurred_at", scan.occurredAt);
        body.put("device_serial", scan.deviceSerial);
        if (scan.facilityId != null) {
            body.put("facility_id", scan.facilityId);
        }
        if (scan.notes != null) {
            body.put("notes", scan.notes);
        }
        return body;
    }

    private JSONObject readJson(InputStream stream) throws Exception {
        if (stream == null) {
            return new JSONObject();
        }
        BufferedReader reader = new BufferedReader(new InputStreamReader(stream, UTF_8));
        StringBuilder text = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            text.append(line);
        }
        reader.close();
        if (text.length() == 0) {
            return new JSONObject();
        }
        return new JSONObject(text.toString());
    }

    /** W3C trace-id: 32 हेक्स अक्षर। */
    private String newTraceId() {
        byte[] bytes = new byte[16];
        random.nextBytes(bytes);
        StringBuilder hex = new StringBuilder(32);
        for (byte value : bytes) {
            hex.append(Character.forDigit((value >> 4) & 0xF, 16));
            hex.append(Character.forDigit(value & 0xF, 16));
        }
        return hex.toString();
    }

    /**
     * Android 8 से आगे पृष्ठभूमि की सेवा को दिखना पड़ता है। सूचना उसी चैनल पर
     * जाती है जो {@code WarehouseScannerApp} बनाता है।
     */
    private void startInForeground() {
        Notification notification = new NotificationCompat.Builder(
                this, getString(R.string.alert_channel_id))
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getString(R.string.legacy_upload_notice))
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .build();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        // बँधने लायक कुछ नहीं; यह सेवा केवल startService से चलती है।
        return null;
    }

    @Override
    public void onDestroy() {
        executor.shutdown();
        super.onDestroy();
    }
}
