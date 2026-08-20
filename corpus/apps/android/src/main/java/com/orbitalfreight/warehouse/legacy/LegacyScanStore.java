package com.orbitalfreight.warehouse.legacy;

import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Log;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;

/**
 * पुरानी स्क्रीनों की डेटाबेस परत — वही तालिकाएँ जिन पर Room चलता है, पर सीधे
 * SQL से।
 *
 * <p>यह क्लास <code>warehouse-scanner.db</code> को उसी नाम से खोलती है जिस नाम से
 * {@code WarehouseDatabase} खोलता है। दो अलग हैंडल एक ही फ़ाइल पर — यह देखने में
 * ग़लत लगता है और तीन बार हटाने की कोशिश हो चुकी है, इसलिए वजह यहीं लिखी है:</p>
 *
 * <ul>
 *   <li>अलग फ़ाइल रखने पर एक ही स्कैन दो कतारों में बँट जाता, और
 *       {@code ScanOutboxWorker} को पुरानी कतार दिखती ही नहीं — गेट पर किए गए
 *       स्कैन तब तक अटके रहते जब तक कोई पुरानी स्क्रीन दोबारा न खुले। 2025 में
 *       ठीक यही हुआ था और चार दिन के seal_check गुम मिले।</li>
 *   <li>SQLite एक ही प्रक्रिया के भीतर कई कनेक्शन संभालता है; WAL चालू है और
 *       लिखना हमेशा छोटे लेन-देन में होता है, इसलिए टकराव व्यवहार में नहीं आता।</li>
 * </ul>
 *
 * <p><b>यहाँ कोई माइग्रेशन नहीं है।</b> {@link #onCreate} और {@link #onUpgrade}
 * जान-बूझकर खाली हैं: स्कीमा का मालिक Room है, और यह क्लास केवल तभी खुलती है जब
 * फ़ाइल पहले से बन चुकी हो। ऐप का पहला रन हमेशा Compose वाली स्क्रीन से होता है,
 * क्योंकि रिंग-स्कैनर का intent भी ऐप को पहले सामान्य रूप से शुरू करता है।</p>
 */
final class LegacyScanStore extends SQLiteOpenHelper {

    private static final String TAG = "OFLegacyStore";

    /** वही नाम जो {@code WarehouseDatabase.DATABASE_NAME} में है। */
    private static final String DATABASE_NAME = "warehouse-scanner.db";

    /**
     * Room की मौजूदा स्कीमा संख्या। यह क्लास स्कीमा बदलती नहीं, पर संस्करण
     * छोटा बताने पर SQLiteOpenHelper डाउनग्रेड मानकर अपवाद फेंकता है।
     */
    private static final int DATABASE_VERSION = 4;

    /** सत्र का टोकन Kotlin वाला TokenStore यहाँ लिखता है; यहाँ केवल पढ़ा जाता है। */
    private static final String CREDENTIALS_PREFS = "of_credentials";

    private final SharedPreferences credentials;

    LegacyScanStore(Context context) {
        super(context.getApplicationContext(), DATABASE_NAME, null, DATABASE_VERSION);
        this.credentials = context.getApplicationContext()
                .getSharedPreferences(CREDENTIALS_PREFS, Context.MODE_PRIVATE);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        // स्कीमा Room बनाता है। यहाँ कुछ बनाना दो परिभाषाओं को अलग होने देगा।
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        // माइग्रेशन WarehouseDatabase.MIGRATION_* में हैं और वही अकेले चलते हैं।
    }

    /**
     * BIC कोड से वह खुली जोड़ी निकालती है जिस पर अभी काम चल रहा है।
     *
     * <p>"खुली" का अर्थ है {@code unloaded_at} खाली — यानी डिब्बा अब भी उस
     * शिपमेंट पर लदा है। एक डिब्बा जीवनकाल में कई शिपमेंट पर जाता है, इसलिए
     * केवल {@code iso_code} से पूछना कभी पर्याप्त नहीं होता; यही चूक पुराने
     * फ़र्मवेयर में थी और सील दूसरे शिपमेंट पर दर्ज हो जाती थी।</p>
     *
     * @param isoCode ISO 6346 का ग्यारह-अक्षर कोड, बड़े अक्षरों में
     * @return जोड़ी, या {@code null} अगर स्थानीय कैश में यह डिब्बा नहीं है
     */
    Pairing findActivePairing(String isoCode) {
        SQLiteDatabase db = getReadableDatabase();
        Cursor cursor = db.rawQuery(
                "SELECT sc.shipment_id, sc.container_id, sc.seal_number, s.reference, s.status "
                        + "FROM shipment_containers sc "
                        + "JOIN containers c ON c.container_id = sc.container_id "
                        + "JOIN shipments s ON s.shipment_id = sc.shipment_id "
                        + "WHERE c.iso_code = ? AND sc.unloaded_at IS NULL "
                        + "ORDER BY sc.loaded_at DESC LIMIT 1",
                new String[]{isoCode});
        try {
            if (!cursor.moveToFirst()) {
                Log.w(TAG, "no cached pairing for iso_code " + isoCode);
                return null;
            }
            Pairing pairing = new Pairing();
            pairing.shipmentId = cursor.getString(0);
            pairing.containerId = cursor.getString(1);
            pairing.sealNumber = cursor.getString(2);
            pairing.reference = cursor.getString(3);
            pairing.status = cursor.getString(4);
            return pairing;
        } finally {
            cursor.close();
        }
    }

    /**
     * स्कैन को कतार में डालती है और उसकी स्थानीय पंक्ति-संख्या लौटाती है।
     *
     * <p>{@code idempotency_key} यहीं एक बार बनती है और पंक्ति के साथ बनी रहती
     * है। पुनःप्रयास पर नई कुंजी बनाना सबसे महँगी ग़लती होगी जो इस फ़ाइल में की
     * जा सकती है: container-registry हर नई कुंजी को नया स्कैन मानता है, और
     * एक ही सील जाँच दो बार <code>freight.shipment_scan_events</code> में उतर
     * जाती।</p>
     */
    long enqueue(String shipmentId, String containerId, String scanType, String notes) {
        ContentValues values = new ContentValues();
        values.put("shipment_id", shipmentId);
        values.put("container_id", containerId);
        values.put("scan_type", scanType);
        values.put("scanned_by_user_id", credentials.getString("user_id", "usr_unknown"));
        values.put("facility_id", credentials.getString("facility_id", null));
        values.put("occurred_at", nowRfc3339());
        values.put("device_serial", credentials.getString("device_serial", "unknown"));
        values.put("notes", notes);
        values.put("idempotency_key", UUID.randomUUID().toString());
        values.put("state", "pending");
        values.put("attempts", 0);

        // स्थिति यहाँ जान-बूझकर नहीं भरी जाती: पुरानी स्क्रीन के पास GPS नहीं है
        // (रिंग-स्कैनर में रिसीवर ही नहीं होता), और झूठी स्थिति भेजने से
        // विश्लेषण में गलत लेन बनती। खाली position स्वीकार्य है।
        long localId = getWritableDatabase().insert("scan_outbox", null, values);
        Log.i(TAG, "queued " + scanType + " for shipment " + shipmentId + " as local row " + localId);
        return localId;
    }

    /**
     * क्षति की तस्वीर को उसकी अपनी कतार में डालती है।
     *
     * <p>{@code owner_id} अभी खाली रहता है — वह scn_ तभी मिलता है जब स्कैन खुद
     * भेजा जा चुका हो। अपलोड करने वाला वर्कर उन पंक्तियों को छोड़ देता है जिनका
     * {@code owner_id} अब भी खाली है, इसलिए तस्वीर कभी अपने स्कैन से पहले
     * document-service पर नहीं पहुँचती।</p>
     */
    long enqueueDamagePhoto(long scanLocalId, String filePath, long byteSize, String sha256Hex) {
        ContentValues values = new ContentValues();
        values.put("scan_local_id", scanLocalId);
        values.put("owner_type", "scan");
        values.put("kind", "damage_photo");
        values.put("file_path", filePath);
        values.put("mime_type", "image/jpeg");
        values.put("byte_size", byteSize);
        values.put("sha256_hex", sha256Hex);
        values.put("idempotency_key", UUID.randomUUID().toString());
        values.put("state", "pending");
        values.put("attempts", 0);
        return getWritableDatabase().insert("damage_photo_outbox", null, values);
    }

    /** भेजे जाने के इंतज़ार में पड़ी पंक्तियाँ, पुरानी पहले। */
    List<PendingScan> pendingScans(int limit) {
        List<PendingScan> pending = new ArrayList<PendingScan>();
        Cursor cursor = getReadableDatabase().rawQuery(
                "SELECT local_id, shipment_id, container_id, scan_type, occurred_at, "
                        + "facility_id, device_serial, notes, idempotency_key, attempts "
                        + "FROM scan_outbox WHERE state = 'pending' "
                        + "ORDER BY occurred_at ASC LIMIT ?",
                new String[]{String.valueOf(limit)});
        try {
            while (cursor.moveToNext()) {
                PendingScan scan = new PendingScan();
                scan.localId = cursor.getLong(0);
                scan.shipmentId = cursor.getString(1);
                scan.containerId = cursor.getString(2);
                scan.scanType = cursor.getString(3);
                scan.occurredAt = cursor.getString(4);
                scan.facilityId = cursor.getString(5);
                scan.deviceSerial = cursor.getString(6);
                scan.notes = cursor.getString(7);
                scan.idempotencyKey = cursor.getString(8);
                scan.attempts = cursor.getInt(9);
                pending.add(scan);
            }
        } finally {
            cursor.close();
        }
        return pending;
    }

    /** सफल प्रेषण: scn_ दर्ज करती है और पंक्ति को {@code sent} कर देती है। */
    void markSent(long localId, String remoteScanId, String traceId) {
        ContentValues values = new ContentValues();
        values.put("state", "sent");
        values.put("remote_scan_id", remoteScanId);
        values.put("last_trace_id", traceId);
        getWritableDatabase().update("scan_outbox", values, "local_id = ?",
                new String[]{String.valueOf(localId)});

        // तस्वीरें अब चढ़ सकती हैं — उन्हें वही scn_ चाहिए था।
        ContentValues owner = new ContentValues();
        owner.put("owner_id", remoteScanId);
        getWritableDatabase().update("damage_photo_outbox", owner,
                "scan_local_id = ? AND owner_id IS NULL",
                new String[]{String.valueOf(localId)});
    }

    /**
     * विफल प्रेषण: गिनती बढ़ाती है और आठवीं विफलता पर पंक्ति को {@code dead}
     * कर देती है — वही सीमा जो §4.19 में विषाक्त संदेश के लिए है।
     */
    void markFailed(long localId, int attempts, String errorCode, String traceId) {
        ContentValues values = new ContentValues();
        values.put("attempts", attempts + 1);
        values.put("last_error_code", errorCode);
        values.put("last_trace_id", traceId);
        values.put("state", attempts + 1 >= 8 ? "dead" : "pending");
        getWritableDatabase().update("scan_outbox", values, "local_id = ?",
                new String[]{String.valueOf(localId)});
    }

    String accessToken() {
        return credentials.getString("access_token", "");
    }

    String tenantId() {
        return credentials.getString("tenant_id", "");
    }

    /** RFC 3339, UTC, अंत में Z — §0.2 का तार-प्रारूप। */
    private static String nowRfc3339() {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    /** एक डिब्बे और शिपमेंट की जोड़ी, सील नंबर सहित। */
    static final class Pairing {
        String shipmentId;
        String containerId;
        String sealNumber;
        String reference;
        String status;
    }

    /** कतार में पड़ा एक स्कैन, वैसा ही जैसा तार पर जाएगा। */
    static final class PendingScan {
        long localId;
        String shipmentId;
        String containerId;
        String scanType;
        String occurredAt;
        String facilityId;
        String deviceSerial;
        String notes;
        String idempotencyKey;
        int attempts;
    }
}
