package com.orbitalfreight.shared.model

/**
 * ORBITALFREIGHT की पहचानें उपसर्ग सहित ULID हैं (§0.1), और यह फ़ाइल उस नियम को
 * क्लाइंट की तरफ़ भी लागू रखती है।
 *
 * उपसर्ग मान का हिस्सा है और रास्ते में कभी नहीं हटता। यह देखने में मामूली लगता
 * है पर एक असली बग रोकता है: `shp_` और `scn_` दोनों 26 अक्षर के ULID हैं, और
 * उपसर्ग हटा देने पर दोनों एक जैसे दिखते हैं — एक बार स्कैन की पहचान शिपमेंट के
 * खाने में चली गई थी और सर्वर ने उसे विधिवत `404` कहा, जिसे ऐप ने "शिपमेंट नहीं
 * मिला" दिखाया। असली कारण खोजने में दो दिन लगे।
 *
 * इसीलिए यहाँ हर पहचान का अपना अंतर्निहित प्रकार है। ये संकलन के समय ही अलग हैं
 * और चलने के समय सादे String — यानी जाँच मुफ़्त है।
 */

/** शिपमेंट — `shp_<ULID>`, `freight.shipments.shipment_id`। */
@JvmInline
value class ShipmentId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "shp_" }
}

/** डिब्बा — `cnt_<ULID>`, `freight.containers.container_id`। */
@JvmInline
value class ContainerId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "cnt_" }
}

/** स्कैन — `scn_<ULID>`; यह container-registry बनाता है, उपकरण नहीं। */
@JvmInline
value class ScanId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "scn_" }
}

/** दस्तावेज़ — `doc_<ULID>`, `platform.documents.document_id`। */
@JvmInline
value class DocumentId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "doc_" }
}

/** चेतावनी — `alr_<ULID>`, `telemetry.telemetry_alerts.alert_id`। */
@JvmInline
value class AlertId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "alr_" }
}

/** सुविधा — `fac_<ULID>`, `freight.facilities.facility_id`। */
@JvmInline
value class FacilityId(val value: String) {
    init { requirePrefix(value, PREFIX) }
    override fun toString(): String = value
    companion object { const val PREFIX = "fac_" }
}

/**
 * ULID का लंबाई-नियम: उपसर्ग के बाद ठीक 26 base32 अक्षर।
 *
 * लंबाई की जाँच इसलिए है कि कटी हुई पहचान (कहीं `substring` लग गया) उपसर्ग तो
 * रखती है पर सर्वर पर कभी नहीं मिलती, और वह विफलता `404` बनकर उपयोगकर्ता तक
 * पहुँचती है जहाँ उसका कोई अर्थ नहीं बनता।
 */
private fun requirePrefix(value: String, prefix: String) {
    require(value.startsWith(prefix)) { "expected an id starting with '$prefix', got '$value'" }
    require(value.length == prefix.length + ULID_LENGTH) {
        "malformed id '$value': ${ULID_LENGTH} base32 characters must follow '$prefix'"
    }
}

private const val ULID_LENGTH = 26

/**
 * वे दो यादृच्छिक मान जो मंच से आते हैं: idempotency कुंजी और trace-id।
 *
 * दोनों को एक ही जगह रखा गया है क्योंकि दोनों की एक ही शर्त है — मंच का
 * क्रिप्टोग्राफ़िक स्रोत, न कि `Random()`। कमज़ोर स्रोत से बनी idempotency कुंजी
 * टकरा सकती है, और टकराई हुई कुंजी का अर्थ है कि सर्वर दूसरे स्कैन को पहले का
 * दोहराव मानकर चुपचाप गिरा देगा।
 */
expect object IdempotencyKeys {

    /**
     * एक नई idempotency कुंजी। यह पंक्ति बनते समय **एक बार** बनती है और
     * पंक्ति के साथ भंडार में रहती है; हर पुनःप्रयास वही कुंजी भेजता है।
     * सर्वर उसे 24 घंटे याद रखता है (§7 नियम 5)।
     */
    fun newIdempotencyKey(): String

    /** W3C trace-id — 32 हेक्स अक्षर, कभी पूरा शून्य नहीं। */
    fun newTraceId(): String
}
