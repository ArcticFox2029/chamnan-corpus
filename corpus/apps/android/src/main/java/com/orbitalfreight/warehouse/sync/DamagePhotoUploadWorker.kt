package com.orbitalfreight.warehouse.sync

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.orbitalfreight.warehouse.BuildConfig
import com.orbitalfreight.warehouse.data.db.dao.ScanOutboxDao
import com.orbitalfreight.warehouse.data.db.entity.DamagePhotoOutboxEntity
import com.orbitalfreight.warehouse.data.net.DocumentServiceApi
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException

/**
 * क्षति की तस्वीरें document-service तक पहुँचाने वाला वर्कर।
 *
 * यह स्कैन वाले रिले से अलग इसलिए है कि इसकी अर्थव्यवस्था अलग है: एक तस्वीर
 * तीन से आठ मेगाबाइट की होती है, और उसे बिना-मीटर वाले कनेक्शन तथा ठीक-ठाक
 * बैटरी का इंतज़ार करने देना सस्ता पड़ता है। पहले दोनों एक ही वर्कर में थे और एक
 * भारी तस्वीर पूरे बैच के स्कैन रोक लेती थी।
 *
 * क्रम की एक कड़ी बाध्यता है: तस्वीर तभी चढ़ सकती है जब उसके स्कैन का scn_ मिल
 * चुका हो, क्योंकि document-service `owner_type = 'scan'` वाले `owner_id` को
 * container-registry से पुष्टि कराकर ही blob स्वीकारती है। इसीलिए
 * [ScanOutboxDao.selectUploadablePhotos] केवल वही पंक्तियाँ लौटाती है जिनका
 * `owner_id` भर चुका है, और यह वर्कर उन्हें छोड़ देता है जिनका नहीं भरा।
 */
@HiltWorker
class DamagePhotoUploadWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val dao: ScanOutboxDao,
    private val api: DocumentServiceApi,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val pending = dao.selectUploadablePhotos(BATCH_SIZE)
        if (pending.isEmpty()) return Result.success()

        var retryNeeded = false
        for (photo in pending) {
            if (!upload(photo)) retryNeeded = true
        }
        return if (retryNeeded) Result.retry() else Result.success()
    }

    /** @return true यदि पंक्ति निपट गई (चढ़ गई या स्थायी रूप से विफल)। */
    private suspend fun upload(photo: DamagePhotoOutboxEntity): Boolean {
        val ownerId = photo.ownerId ?: return true
        val file = File(photo.filePath)

        if (!file.exists()) {
            // फ़ाइल चली गई — उपयोगकर्ता ने संग्रहण खाली किया या OS ने कैश साफ़ किया।
            // दोबारा भेजने को कुछ नहीं है; पंक्ति बंद करके आगे बढ़ो।
            dao.markPhotoFailed(photo.localId, maxAttempts = 1)
            return true
        }

        if (photo.byteSize > BuildConfig.MAX_DOCUMENT_UPLOAD_BYTES) {
            // सेवा इसे 413 देकर लौटाएगी; बैंडविड्थ ख़र्च करने का कोई अर्थ नहीं।
            // कैमरा परत पहले ही घटाकर सहेजती है, तो यहाँ पहुँचना दुर्लभ है।
            dao.markPhotoFailed(photo.localId, maxAttempts = 1)
            return true
        }

        // पहले पूछो: क्या यही तस्वीर पहले ही चढ़ चुकी है? यह तब बचाता है जब पिछली
        // बार blob चला गया था पर उत्तर रास्ते में खो गया। सेवा वैसे भी sha256 पर
        // दोहराव पकड़ती है, पर बिना कारण आठ मेगाबाइट दोबारा भेजने से यह बेहतर है।
        val existing = runCatching {
            api.findDocuments(ownerType = photo.ownerType, ownerId = ownerId, kind = photo.kind)
        }.getOrNull()?.body()?.items?.firstOrNull { it.sha256.equals(photo.sha256Hex, ignoreCase = true) }

        if (existing != null) {
            dao.markPhotoUploaded(photo.localId, existing.documentId)
            file.delete()
            return true
        }

        return try {
            val response = api.uploadDocument(
                idempotencyKey = photo.idempotencyKey,
                ownerType = photo.ownerType.asTextPart(),
                ownerId = ownerId.asTextPart(),
                kind = photo.kind.asTextPart(),
                regionCode = BuildConfig.REGION_CODE.asTextPart(),
                sha256Hex = photo.sha256Hex.asTextPart(),
                file = MultipartBody.Part.createFormData(
                    "file",
                    file.name,
                    file.asRequestBody(photo.mimeType.toMediaType()),
                ),
            )

            val body = response.body()
            if (response.isSuccessful && body != null) {
                dao.markPhotoUploaded(photo.localId, body.documentId)
                // उपकरण पर तस्वीर रखने का अब कोई कारण नहीं; document-service
                // उसे अपने क्षेत्र की बाल्टी में सहेज चुकी है।
                file.delete()
                true
            } else {
                dao.markPhotoFailed(photo.localId)
                false
            }
        } catch (io: IOException) {
            dao.markPhotoFailed(photo.localId)
            false
        }
    }

    private fun String.asTextPart(): RequestBody = toRequestBody(TEXT_PLAIN)

    companion object {
        const val UNIQUE_NAME = "of-damage-photo-upload"

        /** तस्वीरें भारी हैं; एक बार में पाँच से ज़्यादा भेजने का कोई लाभ नहीं मिला। */
        private const val BATCH_SIZE = 5

        private val TEXT_PLAIN = "text/plain".toMediaType()
    }
}
