package com.orbitalfreight.warehouse.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.orbitalfreight.warehouse.data.db.dao.ScanOutboxDao
import com.orbitalfreight.warehouse.data.db.dao.ShipmentDao
import com.orbitalfreight.warehouse.data.db.entity.ContainerEntity
import com.orbitalfreight.warehouse.data.db.entity.DamagePhotoOutboxEntity
import com.orbitalfreight.warehouse.data.db.entity.ScanOutboxEntity
import com.orbitalfreight.warehouse.data.db.entity.ShipmentContainerEntity
import com.orbitalfreight.warehouse.data.db.entity.ShipmentEntity

/**
 * उपकरण का Room डेटाबेस — गोदाम स्कैनर की एकमात्र स्थायी अवस्था।
 *
 * इसमें दो तरह की तालिकाएँ हैं और उनका दर्जा बिल्कुल अलग है:
 *
 *  • **कैश** (`shipments`, `containers`, `shipment_containers`) — container-registry
 *    की प्रतिलिपि। खो जाए तो दोबारा माँग ली जाती है; कुछ नहीं बिगड़ता।
 *  • **कतार** (`scan_outbox`, `damage_photo_outbox`) — वह काम जो हो चुका है पर
 *    अभी सर्वर तक नहीं पहुँचा। यह खो गया तो हमेशा के लिए गया। इसीलिए मेनिफ़ेस्ट
 *    में बैकअप बंद है, `fallbackToDestructiveMigration` कहीं नहीं है, और हर
 *    माइग्रेशन हाथ से लिखा जाता है।
 *
 * नियम: किसी भी माइग्रेशन में कतार वाली तालिका को गिराया नहीं जा सकता, भले ही
 * स्तंभ बदलना कितना ही सुविधाजनक क्यों न लगे। नई तालिका बनाकर पंक्तियाँ उतारो,
 * फिर पुरानी हटाओ — वही जो v2 → v3 में किया गया।
 */
@Database(
    entities = [
        ShipmentEntity::class,
        ContainerEntity::class,
        ShipmentContainerEntity::class,
        ScanOutboxEntity::class,
        DamagePhotoOutboxEntity::class,
    ],
    version = 4,
    exportSchema = true,
)
abstract class WarehouseDatabase : RoomDatabase() {

    abstract fun shipmentDao(): ShipmentDao

    abstract fun scanOutboxDao(): ScanOutboxDao

    companion object {
        private const val DATABASE_NAME = "warehouse-scanner.db"

        /**
         * v1 → v2: `device_serial` जोड़ा गया।
         *
         * इससे पहले सर्वर पर हर स्कैन का `device_serial` खाली जाता था, और जब
         * Rotterdam में एक स्कैनर की घड़ी दो घंटे पीछे चली गई तो यह पता ही नहीं
         * चला कि दोषी उपकरण कौन-सा है। खाली स्ट्रिंग डिफ़ॉल्ट है, `NOT NULL`
         * नहीं — पुरानी पंक्तियों के लिए झूठा क्रमांक गढ़ना उससे भी बुरा होता।
         */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE scan_outbox ADD COLUMN device_serial TEXT NOT NULL DEFAULT ''")
            }
        }

        /**
         * v2 → v3: कतार का पुनर्निर्माण, बिना एक भी पंक्ति खोए।
         *
         * `attempts` पहले नहीं था और विफल स्कैन अनंत बार जाते रहते थे। साथ ही
         * `idempotency_key` पर UNIQUE अनुक्रमणिका जोड़ी गई। SQLite में मौजूदा
         * तालिका पर UNIQUE नहीं लगाया जा सकता, इसलिए नई तालिका बनी, पंक्तियाँ
         * उतरीं (जिनके पास कुंजी नहीं थी उन्हें local_id से गढ़ी गई कुंजी मिली),
         * फिर पुरानी हटी।
         */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE scan_outbox_new (
                        local_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        shipment_id TEXT NOT NULL,
                        container_id TEXT NOT NULL,
                        scan_type TEXT NOT NULL,
                        scanned_by_user_id TEXT NOT NULL,
                        facility_id TEXT,
                        occurred_at TEXT NOT NULL,
                        latitude REAL,
                        longitude REAL,
                        device_serial TEXT NOT NULL,
                        notes TEXT,
                        idempotency_key TEXT NOT NULL,
                        state TEXT NOT NULL DEFAULT 'pending',
                        attempts INTEGER NOT NULL DEFAULT 0,
                        remote_scan_id TEXT,
                        last_error_code TEXT,
                        last_trace_id TEXT
                    )
                    """.trimIndent(),
                )
                db.execSQL(
                    """
                    INSERT INTO scan_outbox_new (
                        local_id, shipment_id, container_id, scan_type, scanned_by_user_id,
                        facility_id, occurred_at, latitude, longitude, device_serial, notes,
                        idempotency_key, state, attempts, remote_scan_id
                    )
                    SELECT
                        local_id, shipment_id, container_id, scan_type, scanned_by_user_id,
                        facility_id, occurred_at, latitude, longitude, device_serial, notes,
                        COALESCE(NULLIF(idempotency_key, ''), 'legacy-' || local_id),
                        state, 0, remote_scan_id
                    FROM scan_outbox
                    """.trimIndent(),
                )
                db.execSQL("DROP TABLE scan_outbox")
                db.execSQL("ALTER TABLE scan_outbox_new RENAME TO scan_outbox")
                db.execSQL("CREATE INDEX index_scan_outbox_state_occurred_at ON scan_outbox (state, occurred_at)")
                db.execSQL("CREATE UNIQUE INDEX index_scan_outbox_idempotency_key ON scan_outbox (idempotency_key)")
            }
        }

        /**
         * v3 → v4: क्षति की तस्वीरों की अपनी कतार।
         *
         * पहले तस्वीर स्कैन के साथ ही multipart में जाती थी, जिसका मतलब था कि
         * बीस मेगाबाइट की एक तस्वीर पूरे बैच को रोक लेती थी। अब तस्वीर अलग चढ़ती
         * है और `owner_id` में उसी स्कैन का scn_ जाता है — यानी document-service
         * पर `owner_type = 'scan'` वाली वैध पंक्ति, जिसे वह
         * `platform.document_owner_types` से जाँचता है।
         */
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS damage_photo_outbox (
                        local_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        scan_local_id INTEGER NOT NULL,
                        owner_type TEXT NOT NULL DEFAULT 'scan',
                        owner_id TEXT,
                        kind TEXT NOT NULL DEFAULT 'damage_photo',
                        file_path TEXT NOT NULL,
                        mime_type TEXT NOT NULL DEFAULT 'image/jpeg',
                        byte_size INTEGER NOT NULL,
                        sha256_hex TEXT NOT NULL,
                        idempotency_key TEXT NOT NULL,
                        state TEXT NOT NULL DEFAULT 'pending',
                        attempts INTEGER NOT NULL DEFAULT 0,
                        document_id TEXT
                    )
                    """.trimIndent(),
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS index_damage_photo_outbox_state ON damage_photo_outbox (state)")
                db.execSQL("CREATE INDEX IF NOT EXISTS index_damage_photo_outbox_owner_id ON damage_photo_outbox (owner_id)")
            }
        }

        fun build(context: Context): WarehouseDatabase =
            Room.databaseBuilder(context.applicationContext, WarehouseDatabase::class.java, DATABASE_NAME)
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4)
                // WAL इसलिए कि वर्कर पढ़ते समय स्कैन-स्क्रीन का लेखन न रुके।
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .build()
    }
}
