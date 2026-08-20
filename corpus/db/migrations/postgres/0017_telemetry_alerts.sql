-- ---------------------------------------------------------------------------
-- 0017_telemetry_alerts.sql
--
-- telemetry.telemetry_alerts — वह table जिससे telemetry.alert.raised निकलता है,
-- और उसी event के ज़रिए container-registry shipment को at_risk में डालती है बिना
-- telemetry-ingest को synchronously बुलाए (SPEC.md §1.2 का टूटा हुआ चक्र)।
--
-- SPEC.md §2.5, §3.4, §4.9।
-- ---------------------------------------------------------------------------

BEGIN;

-- shipment_id nullable है क्योंकि alert उठाते समय container-registry की
-- freight.v1.ContainerLookup/ResolveShipmentForContainer असफल हो सकती है — खाली
-- पड़े डिब्बे की battery भी critical होती है और उसका कोई shipment नहीं होता।
-- Alert को इसलिए रोक देना गलत होगा।
--
-- threshold_value NOT NULL है पर peak_value नहीं: gateway_silent जैसे नियम में
-- कोई मापा हुआ शिखर होता ही नहीं।
CREATE TABLE telemetry.telemetry_alerts (
    alert_id         TEXT        PRIMARY KEY,
    container_id     TEXT        NOT NULL,
    shipment_id      TEXT,
    rule_code        TEXT        NOT NULL CHECK (rule_code IN
                       ('temp_excursion_high','temp_excursion_low','humidity_high','shock_impact',
                        'door_open_in_transit','battery_critical','gateway_silent','geofence_breach')),
    severity         SMALLINT    NOT NULL CHECK (severity BETWEEN 1 AND 5),
    opened_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at        TIMESTAMPTZ,
    peak_value       NUMERIC(10,3),
    threshold_value  NUMERIC(10,3) NOT NULL,
    first_reading_id TEXT        NOT NULL,
    acknowledged_by  TEXT,
    acknowledged_at  TIMESTAMPTZ,

    CONSTRAINT alerts_id_is_prefixed_ulid
        CHECK (alert_id ~ '^alr_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT alerts_first_reading_is_prefixed
        CHECK (first_reading_id ~ '^rdg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT alerts_close_after_open
        CHECK (closed_at IS NULL OR closed_at >= opened_at),

    -- POST /v1/alerts/{alert_id}/acknowledge दोनों column एक साथ भरता है; एक ही
    -- भरा मिलना हमेशा किसी अधूरे migration का निशान रहा है।
    CONSTRAINT alerts_ack_is_complete
        CHECK ((acknowledged_by IS NULL) = (acknowledged_at IS NULL)),

    -- gateway_silent नियम container के बजाय gateway पर उठता है, इसलिए वहाँ शिखर
    -- मान नहीं होता; बाक़ी सात नियमों में होता है।
    CONSTRAINT alerts_peak_required_for_measured_rules
        CHECK (rule_code IN ('gateway_silent','door_open_in_transit') OR peak_value IS NOT NULL)
);

COMMENT ON TABLE telemetry.telemetry_alerts IS
    'alert उठते ही telemetry.alert.raised जाता है; container-registry उसे खाकर shipment को at_risk करती है';
COMMENT ON COLUMN telemetry.telemetry_alerts.severity IS
    'OF_FREIGHT_AUTO_AT_RISK_SEVERITY इससे तुलना करके तय करता है कि shipment at_risk होगी या नहीं';

-- खुले alerts ही console पर दिखते हैं और वही कुल का 1% से कम हैं।
CREATE INDEX alerts_open_idx
    ON telemetry.telemetry_alerts (container_id)
    WHERE closed_at IS NULL;

-- GET /v1/alerts?state=&rule_code=&severity_min= — यह filter जोड़ी सबसे आम है।
CREATE INDEX alerts_triage_idx
    ON telemetry.telemetry_alerts (rule_code, severity DESC, opened_at DESC)
    WHERE closed_at IS NULL;

-- बिना स्वीकृति वाले गंभीर alerts की escalation notification-service चलाती है।
CREATE INDEX alerts_unacknowledged_idx
    ON telemetry.telemetry_alerts (opened_at)
    WHERE acknowledged_at IS NULL AND closed_at IS NULL AND severity >= 4;

-- billing-service alert को accessorial charge (reefer_power, demurrage) में बदलने
-- के लिए shipment से ढूँढ़ती है।
CREATE INDEX alerts_shipment_idx
    ON telemetry.telemetry_alerts (shipment_id, opened_at DESC)
    WHERE shipment_id IS NOT NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0017_telemetry_alerts', sha256('0017'::bytea));

COMMIT;
