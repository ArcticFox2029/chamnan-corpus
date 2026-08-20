package com.orbitalfreight.shared.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * तार पर जाने वाले वे आकार जो `freight` और `telemetry` स्कीमा से आते हैं।
 *
 * ये सर्वर की तालिकाओं की नकल हैं, पर पूरी नहीं — केवल वे स्तंभ जो किसी मोबाइल
 * स्क्रीन पर दिखते हैं या किसी अनुरोध में भेजे जाते हैं। जो यहाँ नहीं है वह
 * जान-बूझकर नहीं है, सबसे साफ़ उदाहरण `declared_value_minor`: वह
 * `freight.shipments` में है पर ग्राहक-मुखी सतह पर कभी नहीं जाता, और
 * partner-portal-api उसे अपने उत्तर से हटा भी देता है।
 *
 * नामकरण का नियम: JSON में स्तंभ का असली नाम (`snake_case`), Kotlin में
 * `camelCase`। मान — स्थिति, स्कैन-प्रकार, rule_code — कभी अनुवादित नहीं होते;
 * वे अनुबंध का हिस्सा हैं और स्थिरांक के रूप में नीचे रखे गए हैं।
 */

@Serializable
data class Shipment(
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("tenant_id") val tenantId: String,
    /** ग्राहक की अपनी बुकिंग संख्या; प्रति tenant अद्वितीय, वैश्विक रूप से नहीं। */
    val reference: String,
    @SerialName("origin_facility_id") val originFacilityId: String,
    @SerialName("destination_facility_id") val destinationFacilityId: String,
    /** `DAP`, `CIF`, `EXW` … तीन अक्षर, कभी अनुवादित नहीं। */
    val incoterm: String,
    /** [ShipmentStatus] के आठ मानों में से एक। */
    val status: String,
    @SerialName("sla_deadline_at") val slaDeadlineAt: String? = null,
    @SerialName("region_code") val regionCode: String,
    @SerialName("delivered_at") val deliveredAt: String? = null,
    /** जोड़ी की पंक्तियाँ — सील नंबर यहीं है, डिब्बे पर नहीं। */
    val containers: List<ShipmentContainer> = emptyList(),
)

@Serializable
data class ShipmentContainer(
    @SerialName("container_id") val containerId: String,
    /**
     * सील जोड़ी की संपत्ति है, न डिब्बे की न शिपमेंट की — एक ही डिब्बा अगले
     * सप्ताह दूसरी सील के साथ दूसरे शिपमेंट पर होगा।
     */
    @SerialName("seal_number") val sealNumber: String,
    @SerialName("gross_kg") val grossKg: Int,
    @SerialName("loaded_at") val loadedAt: String? = null,
    @SerialName("unloaded_at") val unloadedAt: String? = null,
    val container: Container? = null,
)

@Serializable
data class Container(
    @SerialName("container_id") val containerId: String,
    /** BIC कोड, ISO 6346 — ग्यारह अक्षर, जैसे `MSCU3948571`। */
    @SerialName("iso_code") val isoCode: String,
    /** `45R1` = 40 फुट हाई-क्यूब रीफ़र। */
    @SerialName("iso_size_type") val isoSizeType: String,
    @SerialName("is_reefer") val isReefer: Boolean = false,
    /** केवल रीफ़र पर अर्थपूर्ण; सर्वर पर CHECK भी यही कहता है। */
    @SerialName("setpoint_c") val setpointC: Double? = null,
    @SerialName("max_gross_kg") val maxGrossKg: Int,
    @SerialName("tare_weight_kg") val tareWeightKg: Int? = null,
    /**
     * अंतिम टेलीमेट्री पंक्ति का समय। यह container-registry
     * `telemetry.reading.recorded` सुनकर गरम रखता है — मोबाइल इसे केवल
     * "सेंसर ज़िंदा है या नहीं" दिखाने के लिए पढ़ता है।
     */
    @SerialName("last_reading_at") val lastReadingAt: String? = null,
    @SerialName("hazard_classes") val hazardClasses: List<HazardClass> = emptyList(),
)

@Serializable
data class HazardClass(
    /** `3`, `6.1`, `8` … `freight.hazard_classes.hazard_class_code`। */
    @SerialName("hazard_class_code") val hazardClassCode: String,
    @SerialName("is_primary") val isPrimary: Boolean = false,
)

@Serializable
data class Scan(
    @SerialName("scan_id") val scanId: String,
    @SerialName("shipment_id") val shipmentId: String,
    @SerialName("container_id") val containerId: String? = null,
    /** [ScanType] के आठ मानों में से एक। */
    @SerialName("scan_type") val scanType: String,
    @SerialName("scanned_by_user_id") val scannedByUserId: String,
    @SerialName("facility_id") val facilityId: String? = null,
    /** उपकरण की घड़ी से — यही ऑफ़लाइन स्कैन का असली समय है। */
    @SerialName("occurred_at") val occurredAt: String,
    /** सर्वर की घड़ी से; दोनों का अंतर बताता है कि स्कैन कितनी देर कतार में रहा। */
    @SerialName("recorded_at") val recordedAt: String,
    val position: Position? = null,
    @SerialName("device_serial") val deviceSerial: String? = null,
    val notes: String? = null,
)

/** तार पर सादी जोड़ी, GeoJSON नहीं — वैसी ही जैसी `shipment.scanned` में जाती है। */
@Serializable
data class Position(val lat: Double, val lon: Double)

@Serializable
data class TelemetryAlert(
    @SerialName("alert_id") val alertId: String,
    @SerialName("container_id") val containerId: String,
    /** चेतावनी उठाते समय container-registry से हल किया गया; कभी-कभी `null`। */
    @SerialName("shipment_id") val shipmentId: String? = null,
    /** [AlertRule] के आठ मानों में से एक। */
    @SerialName("rule_code") val ruleCode: String,
    /** 1 से 5; जो `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` से ऊपर है वह शिपमेंट को at_risk करता है। */
    val severity: Int,
    @SerialName("opened_at") val openedAt: String,
    @SerialName("closed_at") val closedAt: String? = null,
    @SerialName("peak_value") val peakValue: Double? = null,
    @SerialName("threshold_value") val thresholdValue: Double,
    @SerialName("first_reading_id") val firstReadingId: String,
    @SerialName("acknowledged_by") val acknowledgedBy: String? = null,
    @SerialName("acknowledged_at") val acknowledgedAt: String? = null,
) {
    val isOpen: Boolean get() = closedAt == null
}

@Serializable
data class TelemetryReading(
    @SerialName("reading_id") val readingId: String,
    @SerialName("region_code") val regionCode: String,
    @SerialName("container_id") val containerId: String,
    @SerialName("gateway_id") val gatewayId: String,
    /** सेंसर की घड़ी। */
    @SerialName("recorded_at") val recordedAt: String,
    /** telemetry-ingest की घड़ी; लंबा अंतर = गेटवे का लिंक टूटा हुआ था। */
    @SerialName("received_at") val receivedAt: String,
    @SerialName("temperature_c") val temperatureC: Double? = null,
    @SerialName("humidity_pct") val humidityPct: Double? = null,
    @SerialName("shock_g") val shockG: Double? = null,
    @SerialName("door_open") val doorOpen: Boolean? = null,
    @SerialName("battery_pct") val batteryPct: Int? = null,
    val position: Position? = null,
)

/** `freight.shipments.status` के आठ वैध मान, अक्षरशः। */
object ShipmentStatus {
    const val DRAFT = "draft"
    const val BOOKED = "booked"
    const val SEALED = "sealed"
    const val IN_TRANSIT = "in_transit"
    /** `telemetry.alert.raised` सुनकर container-registry यहाँ लाता है। */
    const val AT_RISK = "at_risk"
    const val HELD_AT_CUSTOMS = "held_at_customs"
    const val DELIVERED = "delivered"
    const val CANCELLED = "cancelled"

    /** वे स्थितियाँ जिनमें शिपमेंट अब भी चल रहा है; सूची स्क्रीन इन्हीं को ऊपर रखती है। */
    val OPEN = setOf(BOOKED, SEALED, IN_TRANSIT, AT_RISK, HELD_AT_CUSTOMS)
}

/** `freight.shipment_scan_events.scan_type` के आठ वैध मान। */
object ScanType {
    const val GATE_IN = "gate_in"
    const val GATE_OUT = "gate_out"
    const val LOAD = "load"
    const val UNLOAD = "unload"
    const val SEAL_CHECK = "seal_check"
    const val CUSTOMS_INSPECTION = "customs_inspection"
    const val DAMAGE_REPORT = "damage_report"
    /**
     * यही स्कैन billing-service के लिए चालान का द्वार खोलता है — वह
     * `shipment.scanned` में केवल इसी प्रकार पर प्रतिक्रिया देता है। इसीलिए
     * दोनों ऐप इसे तभी दिखाते हैं जब शिपमेंट सचमुच रास्ते में हो।
     */
    const val PROOF_OF_DELIVERY = "proof_of_delivery"
}

/** `telemetry.telemetry_alerts.rule_code` के आठ वैध मान। */
object AlertRule {
    const val TEMP_EXCURSION_HIGH = "temp_excursion_high"
    const val TEMP_EXCURSION_LOW = "temp_excursion_low"
    const val HUMIDITY_HIGH = "humidity_high"
    const val SHOCK_IMPACT = "shock_impact"
    const val DOOR_OPEN_IN_TRANSIT = "door_open_in_transit"
    const val BATTERY_CRITICAL = "battery_critical"
    const val GATEWAY_SILENT = "gateway_silent"
    const val GEOFENCE_BREACH = "geofence_breach"
}

/** §0.6 की बंद सूची। इसमें जोड़ना मंच-स्तरीय निर्णय है, ऐप का नहीं। */
object RegionCode {
    const val EU_WEST = "eu-west"
    const val EU_CENTRAL = "eu-central"
    const val NA_EAST = "na-east"
    const val NA_WEST = "na-west"
    const val APAC_SG = "apac-sg"
    const val APAC_JP = "apac-jp"
    const val LATAM_BR = "latam-br"
    const val MEA_AE = "mea-ae"

    val ALL = listOf(EU_WEST, EU_CENTRAL, NA_EAST, NA_WEST, APAC_SG, APAC_JP, LATAM_BR, MEA_AE)
}
