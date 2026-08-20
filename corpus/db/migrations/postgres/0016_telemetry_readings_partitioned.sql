-- ---------------------------------------------------------------------------
-- 0016_telemetry_readings_partitioned.sql
--
-- पूरे platform की सबसे भारी table और उसकी आठ region partitions। यहाँ partitioning
-- का कारण आकार नहीं, data residency है: latam-br की एक reading यूरोपीय storage पर
-- बैठने की क़ानूनी अनुमति नहीं रखती (SPEC.md §7 नियम 7)।
--
-- SPEC.md §2.5। यह migration अकेली ऐसी है जिसे किसी भी हाल में एक ही transaction
-- में चलाना ज़रूरी है — आधी बनी partitioned table पर ingest तुरंत गिर जाती है।
-- ---------------------------------------------------------------------------

BEGIN;

-- Partition key को primary key का हिस्सा होना ही पड़ता है — PostgreSQL की शर्त है।
-- इसीलिए PK composite है, हालाँकि reading_id अपने आप में विश्व-स्तर पर अनूठा है।
-- यह अतिरिक्त column बेकार नहीं जाता: हर query region जानती है (batch उसी region
-- के लिए आती है), इसलिए partition pruning हमेशा लगती है।
CREATE TABLE telemetry.telemetry_readings (
    reading_id      TEXT        NOT NULL,
    region_code     TEXT        NOT NULL,
    container_id    TEXT        NOT NULL,
    gateway_id      TEXT        NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    temperature_c   NUMERIC(5,2),
    humidity_pct    NUMERIC(5,2),
    shock_g         NUMERIC(6,3),
    door_open       BOOLEAN,
    battery_pct     SMALLINT CHECK (battery_pct BETWEEN 0 AND 100),
    position        geography(Point, 4326),
    ingest_batch_id TEXT        NOT NULL,
    PRIMARY KEY (region_code, reading_id),

    CONSTRAINT readings_id_is_prefixed_ulid
        CHECK (reading_id ~ '^rdg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT readings_container_is_prefixed
        CHECK (container_id ~ '^cnt_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- सेंसर की घड़ी और हमारी घड़ी अलग हैं। received_at पहले नहीं हो सकता, पर
    -- थोड़ी छूट रखी है क्योंकि gateway batch भेजते समय अपनी घड़ी stamp करता है और
    -- NTP drift कुछ सेकंड तक जाता है।
    CONSTRAINT readings_received_not_before_recorded
        CHECK (received_at >= recorded_at - INTERVAL '5 minutes'),

    -- भौतिक सीमाएँ। सेंसर की गड़बड़ में -3000 °C आ चुका है और उसने alerts इंजन का
    -- threshold तुलना गणित पूरा बिगाड़ दिया था।
    CONSTRAINT readings_temperature_is_physical
        CHECK (temperature_c IS NULL OR temperature_c BETWEEN -90.00 AND 90.00),
    CONSTRAINT readings_humidity_is_percentage
        CHECK (humidity_pct IS NULL OR humidity_pct BETWEEN 0.00 AND 100.00),
    CONSTRAINT readings_shock_not_negative
        CHECK (shock_g IS NULL OR shock_g >= 0)
) PARTITION BY LIST (region_code);

COMMENT ON TABLE telemetry.telemetry_readings IS
    'POST /v1/ingest/batch और telemetry.v1.TelemetryIngest/StreamReadings दोनों यहीं लिखते हैं';
COMMENT ON COLUMN telemetry.telemetry_readings.ingest_batch_id IS
    'दोहराव पकड़ने का handle; gateway पूरी batch दोबारा भेजते हैं और नीचे का UNIQUE उसे no-op बना देता है';

-- आठों partitions, SPEC.md §0.6 की बंद सूची के अनुसार। एक भी छूटने पर उस region
-- की batch 'no partition of relation found' के साथ गिरती है — जो सही व्यवहार है,
-- क्योंकि उसका विकल्प उसे गलत region में लिखना होता।
CREATE TABLE telemetry.telemetry_readings_eu_west
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('eu-west');
CREATE TABLE telemetry.telemetry_readings_eu_central
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('eu-central');
CREATE TABLE telemetry.telemetry_readings_na_east
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('na-east');
CREATE TABLE telemetry.telemetry_readings_na_west
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('na-west');
CREATE TABLE telemetry.telemetry_readings_apac_sg
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('apac-sg');
CREATE TABLE telemetry.telemetry_readings_apac_jp
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('apac-jp');
CREATE TABLE telemetry.telemetry_readings_latam_br
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('latam-br');
CREATE TABLE telemetry.telemetry_readings_mea_ae
    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('mea-ae');

-- Gateways connectivity टूटने के बाद पूरी batch दोबारा भेजते हैं। (batch,
-- container, सेंसर-घड़ी) पर uniqueness उस replay को दोहराव के बजाय no-op बना देती
-- है — ON CONFLICT DO NOTHING के साथ यही पूरी dedupe रणनीति है।
CREATE UNIQUE INDEX readings_dedupe_idx
    ON telemetry.telemetry_readings (region_code, ingest_batch_id, container_id, recorded_at);

-- GET /v1/containers/{container_id}/readings का समय-खिड़की वाला प्रश्न।
CREATE INDEX readings_container_time_idx
    ON telemetry.telemetry_readings (container_id, recorded_at DESC);

-- Rules इंजन उन्हीं readings को देखता है जिनमें असल में तापमान है; door_open और
-- battery वाली पंक्तियाँ अलग नियमों से गुज़रती हैं। लगभग 30% readings में
-- temperature_c NULL होता है (non-reefer डिब्बे), इसलिए partial index सचमुच छोटा
-- पड़ता है।
CREATE INDEX readings_temperature_idx
    ON telemetry.telemetry_readings (container_id, recorded_at DESC)
    WHERE temperature_c IS NOT NULL;

-- geofence_breach नियम को स्थिति चाहिए; बाक़ी नियमों को नहीं।
CREATE INDEX readings_position_gix
    ON telemetry.telemetry_readings USING gist (position)
    WHERE position IS NOT NULL;

-- Gateway-वार debugging: 'इस इकाई ने पिछले घंटे में क्या भेजा'।
CREATE INDEX readings_gateway_time_idx
    ON telemetry.telemetry_readings (gateway_id, received_at DESC);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0016_telemetry_readings_partitioned', sha256('0016'::bytea));

COMMIT;
