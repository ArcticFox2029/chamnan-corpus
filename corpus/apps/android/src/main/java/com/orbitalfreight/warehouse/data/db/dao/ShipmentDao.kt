package com.orbitalfreight.warehouse.data.db.dao

import androidx.room.Dao
import androidx.room.Embedded
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Relation
import androidx.room.Transaction
import com.orbitalfreight.warehouse.data.db.entity.ContainerEntity
import com.orbitalfreight.warehouse.data.db.entity.ShipmentContainerEntity
import com.orbitalfreight.warehouse.data.db.entity.ShipmentEntity
import kotlinx.coroutines.flow.Flow

/**
 * container-registry से लाए गए शिपमेंट और डिब्बों तक पहुँचने का एकमात्र रास्ता।
 *
 * यहाँ कोई भी लेखन-विधि सार्वजनिक नहीं है सिवाय [replaceShipmentSnapshot] के, और
 * वह भी पूरा स्नैपशॉट एक साथ बदलती है। कारण अनुभव से आया है: पहले अलग-अलग
 * upsert थे और एक बार शिपमेंट की स्थिति नई आ गई जबकि उसके डिब्बों की सूची पुरानी
 * रह गई — कर्मचारी को सील-जाँच वाली स्क्रीन पर वह डिब्बा दिखा जो घंटे भर पहले
 * अलग किया जा चुका था। अब या तो पूरा स्नैपशॉट बदलता है या कुछ नहीं।
 */
@Dao
interface ShipmentDao {

    /**
     * एक शिपमेंट, उसके डिब्बे और हर जोड़ी का सील नंबर — वही आकार जो
     * `GET /v1/shipments/{shipment_id}` लौटाता है (डिब्बे अंदर ही जुड़े हुए)।
     */
    data class ShipmentWithContainers(
        @Embedded val shipment: ShipmentEntity,
        @Relation(
            entity = ContainerEntity::class,
            parentColumn = "shipment_id",
            entityColumn = "container_id",
            associateBy = androidx.room.Junction(
                value = ShipmentContainerEntity::class,
                parentColumn = "shipment_id",
                entityColumn = "container_id",
            ),
        )
        val containers: List<ContainerEntity>,
    )

    @Transaction
    @Query("SELECT * FROM shipments WHERE shipment_id = :shipmentId")
    fun observeShipment(shipmentId: String): Flow<ShipmentWithContainers?>

    /**
     * संदर्भ से खोज — कर्मचारी काग़ज़ पर छपा बुकिंग संदर्भ पढ़ता है, shp_ नहीं।
     * खोज असंवेदनशील है और आंशिक भी, क्योंकि थर्मल प्रिंटर के धुँधले अक्षरों में
     * आख़िरी दो अंक अक्सर पढ़े नहीं जाते।
     */
    @Transaction
    @Query(
        """
        SELECT * FROM shipments
        WHERE reference LIKE '%' || :fragment || '%' COLLATE NOCASE
          AND status NOT IN ('delivered', 'cancelled')
        ORDER BY sla_deadline_at IS NULL, sla_deadline_at ASC
        LIMIT 20
        """,
    )
    suspend fun searchOpenShipments(fragment: String): List<ShipmentWithContainers>

    /** BIC कोड से डिब्बा — बारकोड पढ़ने के तुरंत बाद यही चलती है। */
    @Query("SELECT * FROM containers WHERE iso_code = :isoCode")
    suspend fun findContainerByIsoCode(isoCode: String): ContainerEntity?

    /**
     * उस जोड़ी की पंक्ति जिससे सील की तुलना होनी है। दो शिपमेंट एक ही डिब्बे को
     * अपने जीवनकाल में बाँट सकते हैं, इसलिए केवल container_id से खोजना ग़लत होगा।
     */
    @Query(
        """
        SELECT sc.* FROM shipment_containers sc
        JOIN shipments s ON s.shipment_id = sc.shipment_id
        WHERE sc.container_id = :containerId
          AND sc.unloaded_at IS NULL
          AND s.status NOT IN ('delivered', 'cancelled')
        ORDER BY sc.loaded_at DESC
        LIMIT 1
        """,
    )
    suspend fun findActivePairing(containerId: String): ShipmentContainerEntity?

    /**
     * पूरा स्नैपशॉट बदलती है। पुरानी जोड़ियाँ पहले हटती हैं ताकि अलग किया गया
     * डिब्बा (`DELETE /v1/shipments/{id}/containers/{container_id}`) उपकरण पर
     * ज़िंदा न रह जाए।
     */
    @Transaction
    suspend fun replaceShipmentSnapshot(
        shipment: ShipmentEntity,
        containers: List<ContainerEntity>,
        pairings: List<ShipmentContainerEntity>,
    ) {
        upsertShipment(shipment)
        upsertContainers(containers)
        deletePairingsFor(shipment.shipmentId)
        upsertPairings(pairings)
    }

    /**
     * वे शिपमेंट हटाती है जिन्हें छुए हुए एक दिन से ज़्यादा हो गया और जो बंद हो
     * चुके हैं। उपकरण की भंडारण-सीमा असली अड़चन है: एक डिपो में दिन भर में लगभग
     * नौ सौ शिपमेंट गुज़रते हैं और तीन महीने का कैश रखने की कोई वजह नहीं।
     */
    @Query(
        """
        DELETE FROM shipments
        WHERE status IN ('delivered', 'cancelled')
          AND fetched_at < :cutoffRfc3339
        """,
    )
    suspend fun pruneClosedShipments(cutoffRfc3339: String): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertShipment(shipment: ShipmentEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertContainers(containers: List<ContainerEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertPairings(pairings: List<ShipmentContainerEntity>)

    @Query("DELETE FROM shipment_containers WHERE shipment_id = :shipmentId")
    suspend fun deletePairingsFor(shipmentId: String)
}
