package com.orbitalfreight.shared

import com.orbitalfreight.shared.model.IdempotencyKeys
import com.orbitalfreight.shared.model.TelemetryAlert
import com.orbitalfreight.shared.model.TelemetryReading
import io.ktor.client.request.parameter
import io.ktor.http.HttpMethod

/**
 * telemetry-ingest (§3.4, HTTP 8084) का वह छोटा हिस्सा जो मोबाइल पढ़ता है:
 * खुली चेतावनियाँ, एक डिब्बे की पंक्तियाँ, और स्वीकृति।
 *
 * **ऐप कभी टेलीमेट्री लिखता नहीं।** `POST /v1/ingest/batch` किनारे के गेटवे का
 * रास्ता है और उस पर Ed25519 हस्ताक्षर अनिवार्य है
 * (`OF_TELEMETRY_SIGNATURE_REQUIRED`); उपकरण के पास वह कुंजी है ही नहीं, और
 * होनी भी नहीं चाहिए।
 *
 * चेतावनियाँ ऐप में दो रास्तों से आती हैं और दोनों की भूमिका अलग है:
 *  • पुश — notification-service से, `telemetry.alert.raised` सुनकर। यही मुख्य
 *    रास्ता है, क्योंकि इससे उपकरण को जगाने की ज़रूरत नहीं पड़ती।
 *  • यह क्लाइंट — तब, जब उपयोगकर्ता खुद सूची खोलता है, या पुश छूट गया हो
 *    (हवाई जहाज़ मोड, बंद उपकरण)।
 */
class TelemetryAlertsClient(private val http: OrbitalHttpClient) {

    /**
     * `GET /v1/alerts` — छानकर सूची।
     *
     * @param severityMin 1..5; गोदाम की स्क्रीन डिफ़ॉल्ट रूप से 3 से नीचे कुछ
     *        नहीं दिखाती, वरना बैटरी की चेतावनियाँ असली भ्रमण को दबा देती हैं।
     */
    suspend fun alerts(
        state: String? = null,
        ruleCode: String? = null,
        containerId: String? = null,
        severityMin: Int? = null,
        limit: Int = OrbitalHttpClient.DEFAULT_PAGE_LIMIT,
        cursor: String? = null,
    ): Page<TelemetryAlert> = http.send(HttpMethod.Get, "/v1/alerts") {
        state?.let { parameter("state", it) }
        ruleCode?.let { parameter("rule_code", it) }
        containerId?.let { parameter("container_id", it) }
        severityMin?.let { parameter("severity_min", it) }
        parameter("limit", limit)
        cursor?.let { parameter("cursor", it) }
    }

    /**
     * `GET /v1/containers/{container_id}/readings` — समय-खिड़की वाली पूछ।
     *
     * यह पूछ उसी क्षेत्र के विभाजन पर जाती है जिसमें डिब्बा है
     * (`telemetry.telemetry_readings` LIST(region_code) से विभाजित है)। दूसरे
     * क्षेत्र की पंक्तियाँ माँगने पर उत्तर खाली आता है, त्रुटि नहीं — §7 नियम 7
     * का सीधा परिणाम, और इसे "बग" समझकर खोजने में समय लगाया जा चुका है।
     */
    suspend fun readings(
        containerId: String,
        fromRfc3339: String,
        toRfc3339: String,
        limit: Int = OrbitalHttpClient.DEFAULT_PAGE_LIMIT,
    ): Page<TelemetryReading> =
        http.send(HttpMethod.Get, "/v1/containers/$containerId/readings") {
            parameter("from", fromRfc3339)
            parameter("to", toRfc3339)
            parameter("limit", limit)
        }

    /**
     * `POST /v1/alerts/{alert_id}/acknowledge` — "देख लिया"।
     *
     * स्वीकृति चेतावनी बंद नहीं करती; वह `acknowledged_by` और
     * `acknowledged_at` भरती है और सूची से हटा देती है। बंद करना
     * (`POST /v1/alerts/{alert_id}/close`) तभी सही है जब भ्रमण ज़मीन पर सुलझ
     * चुका हो — रीफ़र दोबारा चालू, दरवाज़ा बंद — और वह निर्णय गोदाम का नहीं,
     * डिस्पैच का है, इसलिए वह पथ यहाँ जान-बूझकर नहीं है।
     */
    suspend fun acknowledge(
        alertId: String,
        idempotencyKey: String = IdempotencyKeys.newIdempotencyKey(),
        traceId: String? = null,
    ) = http.sendIgnoringBody(
        method = HttpMethod.Post,
        path = "/v1/alerts/$alertId/acknowledge",
        idempotencyKey = idempotencyKey,
        traceId = traceId,
    )
}
