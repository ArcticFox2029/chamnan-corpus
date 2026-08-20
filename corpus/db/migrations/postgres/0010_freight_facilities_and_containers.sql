-- ---------------------------------------------------------------------------
-- 0010_freight_facilities_and_containers.sql
--
-- container-registry की दो नींव tables: freight.facilities (हर वह जगह जहाँ माल
-- रुकता है) और freight.containers (वह भौतिक डिब्बा जिसकी telemetry पूरे platform
-- का सबसे भारी write load है)।
--
-- SPEC.md §2.3।
-- ---------------------------------------------------------------------------

BEGIN;

-- Facility और depot अलग चीज़ें हैं: depot हमारा अपना ठिकाना है (fleet.depots),
-- facility कोई भी बिंदु है जहाँ shipment शुरू या ख़त्म होती है — बंदरगाह, ग्राहक
-- का गोदाम, बंधुआ भंडार।
CREATE TABLE freight.facilities (
    facility_id  TEXT        PRIMARY KEY,
    tenant_id    TEXT        NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN
                   ('seaport','airport','rail_terminal','warehouse','customer_site','bonded_store')),
    name         TEXT        NOT NULL,
    country_code CHAR(2)     NOT NULL,
    unlocode     CHAR(5),
    geofence_id  TEXT        NOT NULL,
    region_code  TEXT        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT facilities_id_is_prefixed_ulid
        CHECK (facility_id ~ '^fac_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT facilities_geofence_is_prefixed
        CHECK (geofence_id ~ '^gfn_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT facilities_unlocode_shape
        CHECK (unlocode IS NULL OR unlocode ~ '^[A-Z]{2}[A-Z2-9]{3}$'),
    CONSTRAINT facilities_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),

    -- बंदरगाहों और रेल टर्मिनलों का UN/LOCODE अनिवार्य है — analytics की
    -- mv_lane_performance_daily उसी पर lanes बनाती है, और NULL वहाँ पूरी lane
    -- गिरा देता है।
    CONSTRAINT facilities_ports_need_unlocode
        CHECK (kind NOT IN ('seaport','airport','rail_terminal') OR unlocode IS NOT NULL)
);

COMMENT ON COLUMN freight.facilities.unlocode IS
    'analytics.mv_lane_performance_daily के origin_unlocode / destination_unlocode यहीं से आते हैं';

CREATE INDEX facilities_tenant_kind_idx ON freight.facilities (tenant_id, kind);
CREATE INDEX facilities_unlocode_idx
    ON freight.facilities (unlocode)
    WHERE unlocode IS NOT NULL;

-- Container का असली नाम उसका BIC iso_code है (जैसे MSCU3948571); cnt_ULID हमारा
-- आंतरिक handle है। दोनों unique हैं, और खोजें दोनों से आती हैं।
--
-- last_reading_id / last_reading_at जानबूझकर foreign key नहीं हैं। telemetry.
-- telemetry_readings partitioned है, दूसरी सेवा की schema में है, और यह जोड़ी पूरे
-- बेड़े पर लगभग 4 kHz की दर से बदलती है — यहाँ referential जाँच रखने का मतलब पूरे
-- ingest path को serialise कर देना था।
CREATE TABLE freight.containers (
    container_id     TEXT        PRIMARY KEY,
    iso_code         CHAR(11)    NOT NULL UNIQUE,
    iso_size_type    CHAR(4)     NOT NULL,
    owner_carrier_id TEXT,                      -- असली FK 0018 में जुड़ती है
    tare_weight_kg   INTEGER     NOT NULL,
    max_gross_kg     INTEGER     NOT NULL,
    is_reefer        BOOLEAN     NOT NULL DEFAULT false,
    setpoint_c       NUMERIC(5,2),
    last_reading_id  TEXT,
    last_reading_at  TIMESTAMPTZ,
    retired_at       TIMESTAMPTZ,

    CONSTRAINT containers_id_is_prefixed_ulid
        CHECK (container_id ~ '^cnt_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- BIC कोड: चार अक्षर owner + U/J/Z श्रेणी + छह अंक (आख़िरी check digit)।
    CONSTRAINT containers_iso_code_shape
        CHECK (iso_code ~ '^[A-Z]{4}[0-9]{7}$'),

    -- ISO 6346 size/type, जैसे 45R1 = 40ft high-cube reefer।
    CONSTRAINT containers_size_type_shape
        CHECK (iso_size_type ~ '^[0-9A-Z]{4}$'),

    CONSTRAINT containers_setpoint_only_for_reefer
        CHECK (setpoint_c IS NULL OR is_reefer),

    -- खाली डिब्बा अपने अधिकतम सकल भार से हल्का ही होगा; उल्टा डेटा दो बार आयात
    -- में आ चुका है और gross weight की जाँचें चुपचाप बेमानी कर देता था।
    CONSTRAINT containers_tare_below_max
        CHECK (tare_weight_kg > 0 AND max_gross_kg > tare_weight_kg),

    -- Reefer setpoint का व्यावहारिक दायरा; इसके बाहर का मान सेंसर की गड़बड़ है।
    CONSTRAINT containers_setpoint_in_range
        CHECK (setpoint_c IS NULL OR setpoint_c BETWEEN -40.00 AND 30.00)
);

COMMENT ON COLUMN freight.containers.last_reading_at IS
    'telemetry.reading.recorded खाकर गर्म रखा जाता है (हर 20वीं reading, SPEC.md §4.8); FK नहीं है, जानबूझकर';

-- GET /v1/containers?iso_code=… सबसे आम बाहरी खोज है, पर UNIQUE index पहले से
-- उसे ढकता है। यहाँ जो चाहिए वह है 'जीवित reefers' — telemetry rules इंजन उन्हीं
-- पर setpoint की तुलना चलाता है।
CREATE INDEX containers_live_reefer_idx
    ON freight.containers (container_id)
    WHERE is_reefer AND retired_at IS NULL;

-- 'चुप पड़े डिब्बे' वाली रिपोर्ट: वे जिनकी आख़िरी reading पुरानी है।
CREATE INDEX containers_last_reading_idx
    ON freight.containers (last_reading_at NULLS FIRST)
    WHERE retired_at IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0010_freight_facilities_and_containers', sha256('0010'::bytea));

COMMIT;
