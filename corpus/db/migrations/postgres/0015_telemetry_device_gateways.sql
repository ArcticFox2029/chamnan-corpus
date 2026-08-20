-- ---------------------------------------------------------------------------
-- 0015_telemetry_device_gateways.sql
--
-- telemetry.device_gateways — depot पर चलने वाले edge agent की पहचान। हर ingest
-- batch पर उसके public_key से Ed25519 हस्ताक्षर जाँचा जाता है, और चुप्पी लंबी
-- होने पर gateway.heartbeat.missed निकलता है।
--
-- SPEC.md §2.5, §3.4, §4.10।
-- ---------------------------------------------------------------------------

BEGIN;

-- serial वह मान है जिसे firmware अपने अंदर रखता है और fleet.vehicles.
-- telematics_unit_id उसी की नक़ल है। gateway_id हमारा आंतरिक handle है और
-- serial device का — दोनों की ज़रूरत है क्योंकि हार्डवेयर बदले बिना पंजीकरण दोबारा
-- होता है।
--
-- depot_id NULL का मतलब चलता-फिरता gateway है: कुछ tractors पर सीधे लगा होता है
-- और किसी depot का नहीं होता।
CREATE TABLE telemetry.device_gateways (
    gateway_id        TEXT        PRIMARY KEY,
    serial            TEXT        NOT NULL UNIQUE,
    depot_id          TEXT,
    region_code       TEXT        NOT NULL,
    firmware_version  TEXT        NOT NULL,
    public_key        TEXT        NOT NULL,
    last_heartbeat_at TIMESTAMPTZ,
    provisioned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    decommissioned_at TIMESTAMPTZ,

    CONSTRAINT gateways_id_is_prefixed_ulid
        CHECK (gateway_id ~ '^gwy_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT gateways_depot_is_prefixed
        CHECK (depot_id IS NULL OR depot_id ~ '^dep_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- firmware/sensor-node का semver; heartbeat.missed इसे साथ भेजता है ताकि
    -- on-call तुरंत देख सके कि पूरा rollout चुप है या एक इकाई।
    CONSTRAINT gateways_firmware_is_semver
        CHECK (firmware_version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'),

    -- Ed25519 public key, base64 में 44 अक्षर। OF_TELEMETRY_SIGNATURE_REQUIRED
    -- local के अलावा हर जगह true है, इसलिए ग़लत आकार की कुंजी पूरे depot को चुप
    -- कर देती।
    CONSTRAINT gateways_public_key_shape
        CHECK (public_key ~ '^[A-Za-z0-9+/]{43}=$'),

    CONSTRAINT gateways_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae'))
);

COMMENT ON TABLE telemetry.device_gateways IS
    'edge/ का depot agent; POST /v1/gateways/{gateway_id}/heartbeat यहीं last_heartbeat_at बदलता है';
COMMENT ON COLUMN telemetry.device_gateways.public_key IS
    'Ed25519; POST /v1/ingest/batch का हर हस्ताक्षर इसी से जाँचा जाता है';

-- चुप्पी का sweep: OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES से पुराना heartbeat।
-- NULLS FIRST इसलिए कि जिस gateway ने कभी heartbeat भेजा ही नहीं वह सबसे पहले
-- दिखे — provisioning अधूरी रह जाना असली और आम गड़बड़ है।
CREATE INDEX gateways_silence_sweep_idx
    ON telemetry.device_gateways (last_heartbeat_at NULLS FIRST)
    WHERE decommissioned_at IS NULL;

CREATE INDEX gateways_depot_idx
    ON telemetry.device_gateways (depot_id)
    WHERE depot_id IS NOT NULL AND decommissioned_at IS NULL;

-- Firmware rollout की स्थिति region-दर-region देखी जाती है।
CREATE INDEX gateways_firmware_idx
    ON telemetry.device_gateways (region_code, firmware_version)
    WHERE decommissioned_at IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0015_telemetry_device_gateways', sha256('0015'::bytea));

COMMIT;
