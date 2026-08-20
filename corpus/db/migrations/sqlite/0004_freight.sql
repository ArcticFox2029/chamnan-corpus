-- ---------------------------------------------------------------------------
-- 0004_freight.sql
--
-- container-registry की छह tables। inspector-android की पूरी offline कार्यप्रणाली
-- इन्हीं पर चलती है: वह containers और shipment_containers को पढ़ता है, और
-- shipment_scan_events में लिखता है — जो अकेली table है जिसमें mobile app असली
-- लेखन करता है और बाद में sync करता है।
--
-- SPEC.md §2.3।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

CREATE TABLE freight_facilities (
    facility_id  TEXT NOT NULL PRIMARY KEY,
    tenant_id    TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN
                   ('seaport','airport','rail_terminal','warehouse','customer_site','bonded_store')),
    name         TEXT NOT NULL,
    country_code TEXT NOT NULL,
    unlocode     TEXT,
    geofence_id  TEXT NOT NULL,   -- logical FK → geo_geofences
    region_code  TEXT NOT NULL REFERENCES platform_region_codes (region_code),
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    CHECK (facility_id GLOB 'fac_[0-9A-Z]*' AND length(facility_id) = 30),
    CHECK (unlocode IS NULL OR length(unlocode) = 5),
    -- बंदरगाहों का UN/LOCODE अनिवार्य है: mv_lane_performance_daily lanes उसी से
    -- बनाती है और NULL पूरी lane गिरा देता है।
    CHECK (kind NOT IN ('seaport','airport','rail_terminal') OR unlocode IS NOT NULL)
) STRICT;

CREATE INDEX freight_facilities_tenant_kind_idx ON freight_facilities (tenant_id, kind);
CREATE INDEX freight_facilities_unlocode_idx
    ON freight_facilities (unlocode)
    WHERE unlocode IS NOT NULL;

CREATE TABLE freight_containers (
    container_id     TEXT    NOT NULL PRIMARY KEY,
    iso_code         TEXT    NOT NULL UNIQUE,
    iso_size_type    TEXT    NOT NULL,
    -- SPEC.md §2 की अनुमत cross-schema FK। SQLite में सब कुछ एक ही फ़ाइल में है,
    -- इसलिए यह यहाँ साधारण FK बन जाती है — बोली ने इसे आसान किया, कठिन नहीं।
    owner_carrier_id TEXT    REFERENCES fleet_carriers (carrier_id),
    tare_weight_kg   INTEGER NOT NULL,
    max_gross_kg     INTEGER NOT NULL,
    is_reefer        INTEGER NOT NULL DEFAULT 0 CHECK (is_reefer IN (0, 1)),
    -- NUMERIC(5,2) नहीं है। STRICT mode में REAL ही एकमात्र भिन्नांक रूप है, और
    -- तापमान वह इकलौती जगह है जहाँ float स्वीकार्य है — पैसा कभी नहीं (SPEC.md §0.2)।
    setpoint_c       REAL,
    last_reading_id  TEXT,
    last_reading_at  TEXT,
    retired_at       TEXT,

    CHECK (container_id GLOB 'cnt_[0-9A-Z]*' AND length(container_id) = 30),
    -- BIC: चार अक्षर + सात अंक।
    CHECK (length(iso_code) = 11
           AND iso_code GLOB '[A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CHECK (length(iso_size_type) = 4),
    CHECK (setpoint_c IS NULL OR is_reefer = 1),
    CHECK (setpoint_c IS NULL OR setpoint_c BETWEEN -40.0 AND 30.0),
    CHECK (tare_weight_kg > 0 AND max_gross_kg > tare_weight_kg)
) STRICT;

CREATE INDEX freight_containers_reefer_idx
    ON freight_containers (container_id)
    WHERE is_reefer = 1 AND retired_at IS NULL;

CREATE INDEX freight_containers_last_reading_idx
    ON freight_containers (last_reading_at)
    WHERE retired_at IS NULL;

CREATE TABLE freight_hazard_classes (
    hazard_class_code TEXT NOT NULL PRIMARY KEY,
    un_division       TEXT NOT NULL,
    placard_label     TEXT NOT NULL,
    segregation_group TEXT
) STRICT;

INSERT INTO freight_hazard_classes VALUES
  ('1.4','1.4','Explosives, minor hazard','A'),
  ('2.1','2.1','Flammable gas','B'),
  ('2.2','2.2','Non-flammable, non-toxic gas',NULL),
  ('2.3','2.3','Toxic gas','C'),
  ('3','3','Flammable liquid','B'),
  ('4.1','4.1','Flammable solid','B'),
  ('5.1','5.1','Oxidiser','D'),
  ('6.1','6.1','Toxic substance','C'),
  ('8','8','Corrosive','E'),
  ('9','9','Miscellaneous dangerous goods',NULL);

CREATE TABLE freight_container_hazard_classes (
    container_id      TEXT    NOT NULL REFERENCES freight_containers (container_id) ON DELETE CASCADE,
    hazard_class_code TEXT    NOT NULL REFERENCES freight_hazard_classes (hazard_class_code),
    is_primary        INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
    declared_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (container_id, hazard_class_code)
) STRICT;

-- partial unique index; MySQL शाखा में इसके लिए generated column चाहिए थी।
CREATE UNIQUE INDEX freight_container_one_primary_hazard
    ON freight_container_hazard_classes (container_id)
    WHERE is_primary = 1;

CREATE INDEX freight_container_hazard_by_class_idx
    ON freight_container_hazard_classes (hazard_class_code);

CREATE TABLE freight_shipments (
    shipment_id             TEXT    NOT NULL PRIMARY KEY,
    tenant_id               TEXT    NOT NULL,
    reference               TEXT    NOT NULL,
    origin_facility_id      TEXT    NOT NULL REFERENCES freight_facilities (facility_id),
    destination_facility_id TEXT    NOT NULL REFERENCES freight_facilities (facility_id),
    incoterm                TEXT    NOT NULL,
    status                  TEXT    NOT NULL DEFAULT 'draft' CHECK (status IN
                              ('draft','booked','sealed','in_transit','at_risk','held_at_customs',
                               'delivered','cancelled')),
    sla_deadline_at         TEXT,
    -- INTEGER minor units — SQLite का INTEGER 64-bit है, इसलिए BIGINT का अलग रूप
    -- चाहिए ही नहीं।
    declared_value_minor    INTEGER NOT NULL DEFAULT 0 CHECK (declared_value_minor >= 0),
    currency                TEXT    NOT NULL,
    region_code             TEXT    NOT NULL REFERENCES platform_region_codes (region_code),
    created_at              TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    delivered_at            TEXT,

    UNIQUE (tenant_id, reference),
    CHECK (shipment_id GLOB 'shp_[0-9A-Z]*' AND length(shipment_id) = 30),
    CHECK (origin_facility_id <> destination_facility_id),
    CHECK (length(incoterm) = 3 AND incoterm GLOB '[A-Z][A-Z][A-Z]'),
    CHECK (length(currency) = 3 AND currency GLOB '[A-Z][A-Z][A-Z]'),
    CHECK ((status = 'delivered') = (delivered_at IS NOT NULL))
) STRICT;

CREATE INDEX freight_shipments_open_idx
    ON freight_shipments (tenant_id, status)
    WHERE status NOT IN ('delivered','cancelled');

CREATE INDEX freight_shipments_sla_idx
    ON freight_shipments (sla_deadline_at)
    WHERE sla_deadline_at IS NOT NULL AND delivered_at IS NULL;

CREATE INDEX freight_shipments_lane_idx
    ON freight_shipments (origin_facility_id, destination_facility_id);

CREATE TABLE freight_shipment_containers (
    shipment_id  TEXT    NOT NULL REFERENCES freight_shipments (shipment_id) ON DELETE CASCADE,
    container_id TEXT    NOT NULL REFERENCES freight_containers (container_id),
    seal_number  TEXT    NOT NULL,
    gross_kg     INTEGER NOT NULL CHECK (gross_kg > 0),
    loaded_at    TEXT,
    unloaded_at  TEXT,
    PRIMARY KEY (shipment_id, container_id),
    CHECK (unloaded_at IS NULL OR loaded_at IS NULL OR unloaded_at >= loaded_at)
) STRICT;

CREATE INDEX freight_shipment_containers_by_container_idx
    ON freight_shipment_containers (container_id, loaded_at);

CREATE INDEX freight_shipment_containers_in_transit_idx
    ON freight_shipment_containers (container_id)
    WHERE loaded_at IS NOT NULL AND unloaded_at IS NULL;

-- Scan trail — inspector-android की इकलौती लेखन-table। geography नहीं है, इसलिए
-- स्थिति दो REAL columns में है; बड़े spatial सवाल यहाँ पूछे ही नहीं जाते
-- (वे geo.v1.GeoService/PointInFence के हैं), पर 0005 का R*Tree index उन कुछ
-- स्थानीय सवालों को सँभालता है जो app पूछता है।
--
-- sync_state वह column है जो PostgreSQL शाखा में मौजूद ही नहीं — यह विशुद्ध रूप
-- से offline-first की ज़रूरत है और सर्वर पर जाते समय गिरा दिया जाता है।
CREATE TABLE freight_shipment_scan_events (
    scan_id            TEXT NOT NULL PRIMARY KEY,
    shipment_id        TEXT NOT NULL REFERENCES freight_shipments (shipment_id),
    container_id       TEXT REFERENCES freight_containers (container_id),
    scan_type          TEXT NOT NULL CHECK (scan_type IN
                         ('gate_in','gate_out','load','unload','seal_check','customs_inspection',
                          'damage_report','proof_of_delivery')),
    scanned_by_user_id TEXT NOT NULL,
    facility_id        TEXT REFERENCES freight_facilities (facility_id),
    occurred_at        TEXT NOT NULL,
    recorded_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    position_lat       REAL,
    position_lon       REAL,
    device_serial      TEXT,
    notes              TEXT,

    sync_state         TEXT NOT NULL DEFAULT 'pending'
                            CHECK (sync_state IN ('pending','sending','synced','rejected')),
    sync_attempts      INTEGER NOT NULL DEFAULT 0,
    sync_error         TEXT,

    CHECK (scan_id GLOB 'scn_[0-9A-Z]*' AND length(scan_id) = 30),
    CHECK (recorded_at >= occurred_at),
    CHECK ((position_lat IS NULL) = (position_lon IS NULL)),
    CHECK (position_lat IS NULL OR (position_lat BETWEEN -90.0 AND 90.0)),
    CHECK (position_lon IS NULL OR (position_lon BETWEEN -180.0 AND 180.0)),
    CHECK (scan_type <> 'proof_of_delivery'
           OR (container_id IS NOT NULL AND facility_id IS NOT NULL))
) STRICT;

CREATE INDEX freight_scan_events_shipment_idx
    ON freight_shipment_scan_events (shipment_id, occurred_at DESC);

CREATE INDEX freight_scan_events_container_idx
    ON freight_shipment_scan_events (container_id, occurred_at DESC)
    WHERE container_id IS NOT NULL;

-- sync worker का इकलौता प्रश्न। यह index PostgreSQL शाखा में है ही नहीं, क्योंकि
-- वहाँ sync जैसी कोई चीज़ नहीं होती।
CREATE INDEX freight_scan_events_sync_idx
    ON freight_shipment_scan_events (recorded_at)
    WHERE sync_state IN ('pending','sending');

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0004_freight', '0004');
