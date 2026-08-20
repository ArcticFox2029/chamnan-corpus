package com.orbitalfreight.warehouse.data.db.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * `freight` स्कीमा की तीन तालिकाओं की उपकरण-स्तरीय प्रतिलिपि: `freight.shipments`,
 * `freight.containers` और `freight.shipment_containers`।
 *
 * यह प्रतिलिपि पूरी नहीं है और होनी भी नहीं चाहिए। गोदाम का कर्मचारी शिपमेंट का
 * घोषित मूल्य या incoterm नहीं देखता, इसलिए `declared_value_minor` जैसे स्तंभ यहाँ
 * नहीं उतारे जाते — जो कॉलम उपकरण पर नहीं है वह खोया भी नहीं जा सकता। जो कॉलम
 * उतारे गए हैं उनके नाम सर्वर वाले नामों से अक्षरशः मेल खाते हैं, ताकि किसी
 * समस्या पर उपकरण का डंप और Postgres की पंक्ति आमने-सामने रखी जा सके।
 *
 * ये पंक्तियाँ केवल पढ़ने के लिए कैश हैं। इन्हें बदलने का एकमात्र वैध रास्ता
 * container-registry है (`PATCH /v1/shipments/{shipment_id}/status`); ऐप कभी
 * स्थानीय स्थिति नहीं बदलता, वरना दो सत्य बन जाते हैं।
 */
@Entity(
    tableName = "shipments",
    indices = [Index(value = ["status"]), Index(value = ["reference"])],
)
data class ShipmentEntity(
    /** shp_<ULID> — उपसर्ग सहित, कभी काटा नहीं जाता (§0.1)। */
    @PrimaryKey
    @ColumnInfo(name = "shipment_id")
    val shipmentId: String,

    @ColumnInfo(name = "tenant_id")
    val tenantId: String,

    /** ग्राहक का अपना बुकिंग संदर्भ; कर्मचारी इसी को खोजता है, shp_ को नहीं। */
    @ColumnInfo(name = "reference")
    val reference: String,

    @ColumnInfo(name = "origin_facility_id")
    val originFacilityId: String,

    @ColumnInfo(name = "destination_facility_id")
    val destinationFacilityId: String,

    /**
     * आठ वैध मानों में से एक: draft, booked, sealed, in_transit, at_risk,
     * held_at_customs, delivered, cancelled। यहाँ TEXT ही रखा गया है, enum नहीं,
     * क्योंकि सर्वर नया मान जोड़े तो पुराना उपकरण उसे दिखा भर देगा, गिरेगा नहीं
     * (§4.19 नियम 3 की वही सोच)।
     */
    @ColumnInfo(name = "status")
    val status: String,

    @ColumnInfo(name = "sla_deadline_at")
    val slaDeadlineAt: String?,

    @ColumnInfo(name = "region_code")
    val regionCode: String,

    /** अंतिम बार container-registry से लाए जाने का समय, RFC 3339 UTC। */
    @ColumnInfo(name = "fetched_at")
    val fetchedAt: String,
)

/**
 * `freight.containers` का वह हिस्सा जो सील जाँच और क्षति रिपोर्ट के लिए ज़रूरी है।
 *
 * `last_reading_at` इसलिए रखा गया है कि कर्मचारी रीफ़र का दरवाज़ा खोलने से पहले
 * देख सके कि सेंसर कब बोला था; अगर वह समय घंटों पुराना है तो डिब्बे का तापमान
 * telemetry-ingest के हिसाब से नहीं, थर्मामीटर से जाँचना पड़ेगा।
 */
@Entity(
    tableName = "containers",
    indices = [Index(value = ["iso_code"], unique = true)],
)
data class ContainerEntity(
    /** cnt_<ULID> */
    @PrimaryKey
    @ColumnInfo(name = "container_id")
    val containerId: String,

    /** BIC कोड, ग्यारह अक्षर, डिब्बे पर छपा हुआ — जैसे MSCU3948571। */
    @ColumnInfo(name = "iso_code")
    val isoCode: String,

    /** चार अक्षर, जैसे 45R1 (40 फ़ुट हाई-क्यूब रीफ़र)। */
    @ColumnInfo(name = "iso_size_type")
    val isoSizeType: String,

    @ColumnInfo(name = "is_reefer")
    val isReefer: Boolean,

    /** केवल तभी अर्थपूर्ण जब isReefer सही हो — सर्वर पर यही CHECK लगा है। */
    @ColumnInfo(name = "setpoint_c")
    val setpointC: Double?,

    @ColumnInfo(name = "max_gross_kg")
    val maxGrossKg: Int,

    @ColumnInfo(name = "last_reading_at")
    val lastReadingAt: String?,

    /**
     * `freight.container_hazard_classes` से लिया गया प्राथमिक ख़तरा-वर्ग कोड
     * ('3', '6.1', '8' …), या null। उपकरण पर पूरी many-to-many तालिका उतारने का
     * कोई लाभ नहीं है — कर्मचारी को केवल यह जानना है कि प्लेकार्ड लगेगा या नहीं।
     */
    @ColumnInfo(name = "primary_hazard_class_code")
    val primaryHazardClassCode: String?,
)

/**
 * `freight.shipment_containers` — जोड़ी और उसका सील नंबर।
 *
 * सील नंबर जोड़ी का गुण है, न शिपमेंट का न डिब्बे का, और सील जाँच का पूरा काम
 * इसी एक कॉलम के इर्द-गिर्द घूमता है: कर्मचारी सील पढ़ता है, ऐप उसकी तुलना यहाँ
 * रखी पंक्ति से करता है, और भिन्नता मिलने पर scan_type = 'seal_check' वाला स्कैन
 * `notes` में दोनों मान लिखकर भेजा जाता है। स्थानीय पंक्ति कभी नहीं बदली जाती।
 */
@Entity(
    tableName = "shipment_containers",
    primaryKeys = ["shipment_id", "container_id"],
    foreignKeys = [
        ForeignKey(
            entity = ShipmentEntity::class,
            parentColumns = ["shipment_id"],
            childColumns = ["shipment_id"],
            onDelete = ForeignKey.CASCADE,
        ),
        ForeignKey(
            entity = ContainerEntity::class,
            parentColumns = ["container_id"],
            childColumns = ["container_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index(value = ["container_id"]), Index(value = ["seal_number"])],
)
data class ShipmentContainerEntity(
    @ColumnInfo(name = "shipment_id")
    val shipmentId: String,

    @ColumnInfo(name = "container_id")
    val containerId: String,

    @ColumnInfo(name = "seal_number")
    val sealNumber: String,

    @ColumnInfo(name = "gross_kg")
    val grossKg: Int,

    @ColumnInfo(name = "loaded_at")
    val loadedAt: String?,

    @ColumnInfo(name = "unloaded_at")
    val unloadedAt: String?,
)
