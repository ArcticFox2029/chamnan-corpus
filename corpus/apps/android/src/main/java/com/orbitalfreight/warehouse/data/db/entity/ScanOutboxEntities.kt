package com.orbitalfreight.warehouse.data.db.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * उपकरण का अपना outbox — वही विचार जो सर्वर पर `platform.outbox_messages` है, पर
 * उलटी दिशा में।
 *
 * कर्मचारी जब स्कैन करता है तो एक ही लेन-देन में दो बातें होती हैं: स्कैन यहाँ
 * लिखा जाता है और UI आगे बढ़ जाता है। नेटवर्क का उस क्षण से कोई लेना-देना नहीं।
 * बाद में [com.orbitalfreight.warehouse.sync.ScanOutboxWorker] पंक्तियाँ उठाकर
 * `POST /v1/containers/{container_id}/scans` पर भेजता है।
 *
 * तीन कॉलम इस तालिका की पूरी वजह हैं:
 *
 *  • [idempotencyKey] — पंक्ति बनते समय एक बार तय होता है और पुनःप्रयासों में
 *    कभी नहीं बदलता। यही `X-OF-Idempotency-Key` बनकर जाता है, और यही कारण है कि
 *    टाइमआउट के बाद दोबारा भेजने से दो scn_ नहीं बनते।
 *  • [occurredAt] — घटना का समय, उपकरण की घड़ी से। सर्वर `recorded_at` अपने आप
 *    भरता है; दोनों का अंतर ही बताता है कि स्कैन कितनी देर ऑफ़लाइन पड़ा रहा।
 *    OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S से बड़ा अंतर सर्वर पर चिह्नित होता है,
 *    अस्वीकृत नहीं।
 *  • [attempts] — आठ के बाद पंक्ति `state = 'dead'` हो जाती है और सहायता-डेस्क को
 *    दिखती है, ठीक वैसे ही जैसे विषाक्त संदेश `<topic>.dlq` में जाता है (§4.19)।
 */
@Entity(
    tableName = "scan_outbox",
    indices = [
        Index(value = ["state", "occurred_at"]),
        Index(value = ["idempotency_key"], unique = true),
    ],
)
data class ScanOutboxEntity(
    /**
     * स्थानीय पंक्ति की पहचान। यह scn_ नहीं है — scn_ container-registry बनाता है
     * और सफल प्रेषण पर [remoteScanId] में उतरता है।
     */
    @PrimaryKey(autoGenerate = true)
    @ColumnInfo(name = "local_id")
    val localId: Long = 0,

    @ColumnInfo(name = "shipment_id")
    val shipmentId: String,

    @ColumnInfo(name = "container_id")
    val containerId: String,

    /**
     * आठ वैध मान: gate_in, gate_out, load, unload, seal_check,
     * customs_inspection, damage_report, proof_of_delivery.
     */
    @ColumnInfo(name = "scan_type")
    val scanType: String,

    /** usr_<ULID> — वह कर्मचारी जिसका सत्र उस समय खुला था। */
    @ColumnInfo(name = "scanned_by_user_id")
    val scannedByUserId: String,

    /** fac_<ULID> — उपकरण के प्रावधान के समय तय हुआ गोदाम। */
    @ColumnInfo(name = "facility_id")
    val facilityId: String?,

    @ColumnInfo(name = "occurred_at")
    val occurredAt: String,

    @ColumnInfo(name = "latitude")
    val latitude: Double?,

    @ColumnInfo(name = "longitude")
    val longitude: Double?,

    /** उपकरण का क्रमांक; सर्वर पर `device_serial` में जाता है। */
    @ColumnInfo(name = "device_serial")
    val deviceSerial: String,

    /**
     * सील-भिन्नता या क्षति का संक्षिप्त विवरण। यह मुक्त पाठ है और कर्मचारी की
     * भाषा में हो सकता है; ORBITALFREIGHT इसका अनुवाद नहीं करता।
     */
    @ColumnInfo(name = "notes")
    val notes: String?,

    @ColumnInfo(name = "idempotency_key")
    val idempotencyKey: String,

    /** pending | sending | sent | dead */
    @ColumnInfo(name = "state")
    val state: String = STATE_PENDING,

    @ColumnInfo(name = "attempts")
    val attempts: Int = 0,

    /** सर्वर का scn_<ULID>, सफल प्रेषण के बाद। */
    @ColumnInfo(name = "remote_scan_id")
    val remoteScanId: String? = null,

    /** अंतिम विफलता का §0.4 वाला `code`, जैसे shipment_already_sealed। */
    @ColumnInfo(name = "last_error_code")
    val lastErrorCode: String? = null,

    /** अंतिम प्रयास का `X-OF-Trace-Id`; सहायता-डेस्क इसी से लॉग खोजती है। */
    @ColumnInfo(name = "last_trace_id")
    val lastTraceId: String? = null,
) {
    companion object {
        const val STATE_PENDING = "pending"
        const val STATE_SENDING = "sending"
        const val STATE_SENT = "sent"
        const val STATE_DEAD = "dead"

        /** §4.19 नियम 4 जितने ही प्रयास, उसी सोच से। */
        const val MAX_ATTEMPTS = 8
    }
}

/**
 * क्षति की तस्वीरें, जो document-service पर `POST /v1/documents` से चढ़ती हैं।
 *
 * इन्हें स्कैन की कतार से अलग रखा गया है क्योंकि दोनों की अर्थव्यवस्था अलग है:
 * स्कैन कुछ सौ बाइट का है और तुरंत जाना चाहिए, तस्वीर कई मेगाबाइट की है और
 * बिना-मीटर वाले कनेक्शन का इंतज़ार कर सकती है। दोनों को एक ही वर्कर में रखने पर
 * एक भारी तस्वीर पूरे बैच के स्कैन रोक लेती थी।
 *
 * [ownerType] हमेशा `scan` होता है और [ownerId] वह scn_ जो स्कैन भेजे जाने पर
 * मिला — इसीलिए तस्वीर कभी अपने स्कैन से पहले नहीं चढ़ सकती, और वर्कर उन पंक्तियों
 * को छोड़ देता है जिनका ownerId अब भी खाली है।
 */
@Entity(
    tableName = "damage_photo_outbox",
    indices = [Index(value = ["state"]), Index(value = ["owner_id"])],
)
data class DamagePhotoOutboxEntity(
    @PrimaryKey(autoGenerate = true)
    @ColumnInfo(name = "local_id")
    val localId: Long = 0,

    /** उस स्कैन की स्थानीय पंक्ति, जब तक scn_ नहीं मिल जाता। */
    @ColumnInfo(name = "scan_local_id")
    val scanLocalId: Long,

    /** `platform.document_owner_types` की शब्दावली से — यहाँ हमेशा 'scan'। */
    @ColumnInfo(name = "owner_type")
    val ownerType: String = "scan",

    /** scn_<ULID>, स्कैन भेजे जाने के बाद भरा जाता है। */
    @ColumnInfo(name = "owner_id")
    val ownerId: String? = null,

    /** `platform.documents.kind` का वैध मान — यहाँ हमेशा 'damage_photo'। */
    @ColumnInfo(name = "kind")
    val kind: String = "damage_photo",

    @ColumnInfo(name = "file_path")
    val filePath: String,

    @ColumnInfo(name = "mime_type")
    val mimeType: String = "image/jpeg",

    @ColumnInfo(name = "byte_size")
    val byteSize: Long,

    /**
     * स्थानीय रूप से गिना गया SHA-256, हेक्स में। document-service इसी से
     * दोहराव पकड़ता है (§1.2 का Diamond B) — वही तस्वीर दोबारा भेजने पर वह
     * नया blob नहीं लिखता, पुराना doc_ लौटा देता है।
     */
    @ColumnInfo(name = "sha256_hex")
    val sha256Hex: String,

    @ColumnInfo(name = "idempotency_key")
    val idempotencyKey: String,

    @ColumnInfo(name = "state")
    val state: String = ScanOutboxEntity.STATE_PENDING,

    @ColumnInfo(name = "attempts")
    val attempts: Int = 0,

    /** doc_<ULID>, चढ़ जाने के बाद। इसके बाद स्थानीय फ़ाइल हटाई जा सकती है। */
    @ColumnInfo(name = "document_id")
    val documentId: String? = null,
)
