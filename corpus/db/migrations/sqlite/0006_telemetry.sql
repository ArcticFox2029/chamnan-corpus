-- ---------------------------------------------------------------------------
-- 0006_telemetry.sql
--
-- telemetry-ingest की tables। edge/ का depot agent इसी फ़ाइल पर सबसे ज़्यादा
-- निर्भर है: readings यहाँ जमा होती हैं जब तक upstream पहुँच में न आए, फिर
-- POST /v1/ingest/batch से जाती हैं और स्थानीय प्रति हट जाती है।
--
-- सबसे बड़ा भेद: SQLite में partitioning है ही नहीं। region_code column बना
-- रहता है (SPEC.md §7 नियम 7 इसी पर टिका है), पर विभाजन भौतिक नहीं है — और
-- ज़रूरत भी नहीं, क्योंकि हर depot agent की फ़ाइल पहले से अपने region की है। यही
-- वह जगह है जहाँ भौतिक विभाजन की भूमिका फ़ाइल-प्रति-उपकरण ने ले ली है।
--
-- SPEC.md §2.5।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

CREATE TABLE telemetry_device_gateways (
    gateway_id        TEXT NOT NULL PRIMARY KEY,
    serial            TEXT NOT NULL UNIQUE,
    depot_id          TEXT,   -- logical FK → fleet_depots; NULL = चलता-फिरता
    region_code       TEXT NOT NULL REFERENCES platform_region_codes (region_code),
    firmware_version  TEXT NOT NULL,   -- firmware/sensor-node का semver
    public_key        TEXT NOT NULL,   -- Ed25519, base64
    last_heartbeat_at TEXT,
    provisioned_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    decommissioned_at TEXT,

    CHECK (gateway_id GLOB 'gwy_[0-9A-Z]*' AND length(gateway_id) = 30),
    CHECK (depot_id IS NULL OR depot_id GLOB 'dep_[0-9A-Z]*'),
    CHECK (length(public_key) = 44 AND public_key LIKE '%='),
    -- semver का पूरा REGEXP यहाँ संभव नहीं; लंबाई और आकार की मोटी जाँच ही है।
    CHECK (firmware_version GLOB '[0-9]*.[0-9]*.[0-9]*')
) STRICT;

CREATE INDEX telemetry_gateways_silence_idx
    ON telemetry_device_gateways (last_heartbeat_at)
    WHERE decommissioned_at IS NULL;

CREATE INDEX telemetry_gateways_depot_idx
    ON telemetry_device_gateways (depot_id)
    WHERE depot_id IS NOT NULL;

-- Readings। partition नहीं, पर PRIMARY KEY वही composite रखा गया है ताकि सर्वर
-- और agent की पंक्तियाँ एक ही आकार की रहें और sync का कोड दोनों तरफ़ एक हो।
--
-- spool_state वह column है जो PostgreSQL शाखा में नहीं है — यह depot agent की
-- अपनी ज़रूरत है और batch भेजते समय गिरा दिया जाता है।
CREATE TABLE telemetry_telemetry_readings (
    reading_id      TEXT NOT NULL,
    region_code     TEXT NOT NULL REFERENCES platform_region_codes (region_code),
    container_id    TEXT NOT NULL,
    gateway_id      TEXT NOT NULL,
    recorded_at     TEXT NOT NULL,   -- सेंसर की घड़ी
    received_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    temperature_c   REAL,
    humidity_pct    REAL,
    shock_g         REAL,
    door_open       INTEGER CHECK (door_open IS NULL OR door_open IN (0, 1)),
    battery_pct     INTEGER CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
    position_lat    REAL,
    position_lon    REAL,
    ingest_batch_id TEXT NOT NULL,

    spool_state     TEXT NOT NULL DEFAULT 'pending'
                         CHECK (spool_state IN ('pending','sending','sent')),

    PRIMARY KEY (region_code, reading_id),

    CHECK (reading_id GLOB 'rdg_[0-9A-Z]*' AND length(reading_id) = 30),
    CHECK (container_id GLOB 'cnt_[0-9A-Z]*'),
    CHECK (temperature_c IS NULL OR temperature_c BETWEEN -90.0 AND 90.0),
    CHECK (humidity_pct IS NULL OR humidity_pct BETWEEN 0.0 AND 100.0),
    CHECK (shock_g IS NULL OR shock_g >= 0),
    CHECK ((position_lat IS NULL) = (position_lon IS NULL))
) STRICT;

-- वही dedupe key जो सर्वर पर है। gateway connectivity लौटने पर पूरी batch दोबारा
-- भेजता है, और यह uniqueness उस replay को दोहराव के बजाय no-op बना देती है।
CREATE UNIQUE INDEX telemetry_readings_dedupe_idx
    ON telemetry_telemetry_readings (region_code, ingest_batch_id, container_id, recorded_at);

CREATE INDEX telemetry_readings_container_time_idx
    ON telemetry_telemetry_readings (container_id, recorded_at DESC);

-- agent का इकलौता निकास-प्रश्न: 'अभी तक न भेजी गई readings, पुरानी पहले'।
CREATE INDEX telemetry_readings_spool_idx
    ON telemetry_telemetry_readings (recorded_at)
    WHERE spool_state = 'pending';

CREATE TABLE telemetry_telemetry_alerts (
    alert_id         TEXT    NOT NULL PRIMARY KEY,
    container_id     TEXT    NOT NULL,
    shipment_id      TEXT,   -- खाली डिब्बे का कोई shipment नहीं होता
    rule_code        TEXT    NOT NULL CHECK (rule_code IN
                       ('temp_excursion_high','temp_excursion_low','humidity_high','shock_impact',
                        'door_open_in_transit','battery_critical','gateway_silent','geofence_breach')),
    severity         INTEGER NOT NULL CHECK (severity BETWEEN 1 AND 5),
    opened_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    closed_at        TEXT,
    peak_value       REAL,
    threshold_value  REAL    NOT NULL,
    first_reading_id TEXT    NOT NULL,
    acknowledged_by  TEXT,
    acknowledged_at  TEXT,

    CHECK (alert_id GLOB 'alr_[0-9A-Z]*' AND length(alert_id) = 30),
    CHECK (first_reading_id GLOB 'rdg_[0-9A-Z]*'),
    CHECK (closed_at IS NULL OR closed_at >= opened_at),
    CHECK ((acknowledged_by IS NULL) = (acknowledged_at IS NULL)),
    CHECK (rule_code IN ('gateway_silent','door_open_in_transit') OR peak_value IS NOT NULL)
) STRICT;

CREATE INDEX telemetry_alerts_open_idx
    ON telemetry_telemetry_alerts (container_id)
    WHERE closed_at IS NULL;

CREATE INDEX telemetry_alerts_triage_idx
    ON telemetry_telemetry_alerts (rule_code, severity DESC, opened_at DESC)
    WHERE closed_at IS NULL;

CREATE INDEX telemetry_alerts_shipment_idx
    ON telemetry_telemetry_alerts (shipment_id, opened_at DESC)
    WHERE shipment_id IS NOT NULL;

-- Retention: PostgreSQL शाखा में यह procedure थी। SQLite में stored procedure
-- नहीं हैं, इसलिए नीति यहाँ table में है और सफ़ाई edge agent चलाता है — वह भेजी
-- जा चुकी readings को 48 घंटे बाद हटाता है, न कि region की पूरी क़ानूनी अवधि तक
-- रखता है। क़ानूनी प्रति सर्वर पर है, यहाँ नहीं।
CREATE TABLE telemetry_retention_policy (
    region_code   TEXT    NOT NULL PRIMARY KEY REFERENCES platform_region_codes (region_code),
    readings_days INTEGER NOT NULL CHECK (readings_days > 0),
    alerts_days   INTEGER NOT NULL,
    local_spool_hours INTEGER NOT NULL DEFAULT 48,
    legal_basis   TEXT    NOT NULL,
    reviewed_on   TEXT    NOT NULL,
    CHECK (alerts_days >= readings_days)
) STRICT;

INSERT INTO telemetry_retention_policy
    (region_code, readings_days, alerts_days, local_spool_hours, legal_basis, reviewed_on) VALUES
  ('eu-west',    730,  1825, 48,  'GDPR Art. 5(1)(e) + carrier contract', '2026-01-15'),
  ('eu-central', 730,  1825, 48,  'GDPR Art. 5(1)(e) + carrier contract', '2026-01-15'),
  ('na-east',    1095, 2555, 48,  'FMCSA record-keeping', '2026-02-02'),
  ('na-west',    1095, 2555, 48,  'FMCSA record-keeping', '2026-02-02'),
  ('apac-sg',    365,  1095, 24,  'PDPA + customs advance ruling window', '2025-11-30'),
  ('apac-jp',    365,  1095, 24,  'APPI', '2025-11-30'),
  -- latam-br में spool लंबा है क्योंकि अंदरूनी depots पर link दिनों तक नहीं आता।
  ('latam-br',   1825, 1825, 168, 'LGPD + ANTT cold-chain evidence requirement', '2026-03-11'),
  ('mea-ae',     730,  1825, 48,  'UAE Federal Decree-Law 45 of 2021', '2026-01-20');

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0006_telemetry', '0006');
