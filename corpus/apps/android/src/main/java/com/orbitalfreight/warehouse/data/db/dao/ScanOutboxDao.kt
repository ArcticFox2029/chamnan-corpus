package com.orbitalfreight.warehouse.data.db.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import com.orbitalfreight.warehouse.data.db.entity.DamagePhotoOutboxEntity
import com.orbitalfreight.warehouse.data.db.entity.ScanOutboxEntity
import kotlinx.coroutines.flow.Flow

/**
 * ऑफ़लाइन कतार का पूरा नियंत्रण। स्कैन और क्षति-तस्वीरें दोनों यहीं से निकलती हैं।
 *
 * इस DAO का सबसे महत्वपूर्ण नियम विधियों के नाम में नहीं, उनके क्रम में है:
 * वर्कर पहले [claimPendingScans] चलाता है, जो पंक्तियों को एक ही लेन-देन में
 * `sending` कर देता है, और उसके बाद ही नेटवर्क छूता है। इससे दो वर्कर एक ही
 * पंक्ति नहीं उठा सकते। पहले यह `SELECT` फिर `UPDATE` था और WorkManager के दो
 * समवर्ती चलने पर एक ही स्कैन दो बार गया था — सर्वर ने X-OF-Idempotency-Key पर
 * दूसरा रोक तो लिया, पर लॉग में हर रात सैकड़ों 409 आते थे।
 */
@Dao
interface ScanOutboxDao {

    @Insert
    suspend fun enqueueScan(scan: ScanOutboxEntity): Long

    @Insert
    suspend fun enqueuePhoto(photo: DamagePhotoOutboxEntity): Long

    /**
     * स्कैन और उसकी तस्वीर एक ही लेन-देन में डालती है, ठीक उसी वजह से जिस वजह से
     * सर्वर स्थिति-परिवर्तन और उसका आउटबॉक्स संदेश एक साथ लिखता है (§7 नियम 3)।
     * आधा लिखा जाना — स्कैन कतार में, तस्वीर नहीं — क्षति की रिपोर्ट को बिना
     * सबूत के छोड़ देता, और वही रिपोर्ट बाद में बीमा दावे का आधार बनती है।
     */
    @Transaction
    suspend fun enqueueDamageReport(scan: ScanOutboxEntity, photoPath: String, byteSize: Long, sha256Hex: String, photoIdempotencyKey: String) {
        val scanLocalId = enqueueScan(scan)
        enqueuePhoto(
            DamagePhotoOutboxEntity(
                scanLocalId = scanLocalId,
                filePath = photoPath,
                byteSize = byteSize,
                sha256Hex = sha256Hex,
                idempotencyKey = photoIdempotencyKey,
            ),
        )
    }

    /**
     * अगले बैच को `sending` चिह्नित करके लौटाती है। सबसे पुराना पहले, ताकि
     * एक ही शिपमेंट के gate_in और gate_out क्रम में पहुँचें — तार पर क्रम की
     * एकमात्र गारंटी partition_key = shipment_id है, और वह तभी काम करती है जब
     * हम खुद उलटे क्रम में न भेजें।
     */
    @Transaction
    suspend fun claimPendingScans(limit: Int): List<ScanOutboxEntity> {
        val claimed = selectPendingScans(limit)
        if (claimed.isNotEmpty()) {
            markScansSending(claimed.map { it.localId })
        }
        return claimed
    }

    @Query(
        """
        SELECT * FROM scan_outbox
        WHERE state = 'pending'
        ORDER BY occurred_at ASC, local_id ASC
        LIMIT :limit
        """,
    )
    suspend fun selectPendingScans(limit: Int): List<ScanOutboxEntity>

    @Query("UPDATE scan_outbox SET state = 'sending' WHERE local_id IN (:localIds)")
    suspend fun markScansSending(localIds: List<Long>)

    /**
     * सफल प्रेषण। scn_ यहीं उतरता है और साथ ही उस स्कैन से जुड़ी तस्वीर का
     * `owner_id` भर जाता है — तस्वीर वाला वर्कर इसी क्षण से उसे उठाने योग्य मानता है।
     */
    @Transaction
    suspend fun markScanSent(localId: Long, remoteScanId: String) {
        markScanSentInternal(localId, remoteScanId)
        attachOwnerToPhotos(localId, remoteScanId)
    }

    @Query(
        """
        UPDATE scan_outbox
        SET state = 'sent', remote_scan_id = :remoteScanId, last_error_code = NULL
        WHERE local_id = :localId
        """,
    )
    suspend fun markScanSentInternal(localId: Long, remoteScanId: String)

    @Query("UPDATE damage_photo_outbox SET owner_id = :scanId WHERE scan_local_id = :scanLocalId")
    suspend fun attachOwnerToPhotos(scanLocalId: Long, scanId: String)

    /**
     * विफलता। आठवें प्रयास पर पंक्ति `dead` हो जाती है और उसके बाद कभी नहीं उठती;
     * उसे सहायता-डेस्क ही निकालती है। `retryable = false` वाली त्रुटि पर वर्कर
     * सीधे [markScanDead] बुलाता है — sealed शिपमेंट अगले प्रयास में खुल नहीं जाएगा।
     */
    @Query(
        """
        UPDATE scan_outbox
        SET state = CASE WHEN attempts + 1 >= :maxAttempts THEN 'dead' ELSE 'pending' END,
            attempts = attempts + 1,
            last_error_code = :errorCode,
            last_trace_id = :traceId
        WHERE local_id = :localId
        """,
    )
    suspend fun markScanFailed(localId: Long, errorCode: String?, traceId: String?, maxAttempts: Int = ScanOutboxEntity.MAX_ATTEMPTS)

    @Query(
        """
        UPDATE scan_outbox
        SET state = 'dead', attempts = attempts + 1, last_error_code = :errorCode, last_trace_id = :traceId
        WHERE local_id = :localId
        """,
    )
    suspend fun markScanDead(localId: Long, errorCode: String?, traceId: String?)

    /** केवल वे तस्वीरें जिनका स्कैन जा चुका है और जिन्हें scn_ मिल गया है। */
    @Query(
        """
        SELECT * FROM damage_photo_outbox
        WHERE state = 'pending' AND owner_id IS NOT NULL
        ORDER BY local_id ASC
        LIMIT :limit
        """,
    )
    suspend fun selectUploadablePhotos(limit: Int): List<DamagePhotoOutboxEntity>

    @Query(
        """
        UPDATE damage_photo_outbox
        SET state = 'sent', document_id = :documentId
        WHERE local_id = :localId
        """,
    )
    suspend fun markPhotoUploaded(localId: Long, documentId: String)

    @Query(
        """
        UPDATE damage_photo_outbox
        SET state = CASE WHEN attempts + 1 >= :maxAttempts THEN 'dead' ELSE 'pending' END,
            attempts = attempts + 1
        WHERE local_id = :localId
        """,
    )
    suspend fun markPhotoFailed(localId: Long, maxAttempts: Int = ScanOutboxEntity.MAX_ATTEMPTS)

    /** UI का बैज — कर्मचारी को दिखता है कि कितने स्कैन अभी उपकरण पर ही हैं। */
    @Query("SELECT COUNT(*) FROM scan_outbox WHERE state IN ('pending', 'sending')")
    fun observeQueueDepth(): Flow<Int>

    @Query("SELECT COUNT(*) FROM scan_outbox WHERE state = 'dead'")
    fun observeDeadCount(): Flow<Int>

    /**
     * भेजे जा चुके स्कैन सात दिन बाद हटते हैं। पहले तुरंत हटते थे, पर तब
     * सहायता-डेस्क "मैंने वह डिब्बा स्कैन किया था" वाली शिकायत की जाँच नहीं कर
     * पाती थी — अब उपकरण पर हफ़्ते भर का trace_id सहित रिकॉर्ड बचा रहता है।
     */
    @Query("DELETE FROM scan_outbox WHERE state = 'sent' AND occurred_at < :cutoffRfc3339")
    suspend fun pruneSentScans(cutoffRfc3339: String): Int
}
