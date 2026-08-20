-- ---------------------------------------------------------------------------
-- 0005_geo_and_routing.sql
--
-- geo-service और routing-service की tables, और इस पूरी शाखा का सबसे दिलचस्प
-- बोली-भेद: SQLite में spatial type नहीं है, पर उसका अपना R*Tree virtual table
-- module है। बहुभुज WKT के रूप में TEXT में रहता है (उसे geo-service ही समझता
-- है), और उसका bounding box R*Tree में — जिससे 'यह बिंदु किन fences के आसपास
-- है' वाला सवाल app में भी मिलीसेकंड में हल हो जाता है, बिना नेटवर्क के।
--
-- SPEC.md §2.4।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

CREATE TABLE geo_geofences (
    geofence_id         TEXT    NOT NULL PRIMARY KEY,
    tenant_id           TEXT,   -- NULL = साझा fence (बंदरगाह, सीमा-क्षेत्र)
    name                TEXT    NOT NULL,
    kind                TEXT    NOT NULL CHECK (kind IN
                          ('facility','depot','border_zone','restricted','customer_site','corridor')),
    -- geography(Polygon, 4326) की जगह WKT। SQLite इसे केवल एक स्ट्रिंग मानता है;
    -- अर्थ geo-service के C++ कोड में है। यहाँ सिर्फ़ यह जाँचते हैं कि यह दिखने
    -- में बहुभुज है, ताकि खाली या कटा-फटा WKT sync से न घुसे।
    boundary_wkt        TEXT    NOT NULL,
    buffer_m            INTEGER NOT NULL DEFAULT 50 CHECK (buffer_m BETWEEN 0 AND 5000),
    dwell_alert_minutes INTEGER CHECK (dwell_alert_minutes IS NULL OR dwell_alert_minutes > 0),
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    retired_at          TEXT,

    CHECK (geofence_id GLOB 'gfn_[0-9A-Z]*' AND length(geofence_id) = 30),
    CHECK (boundary_wkt GLOB 'POLYGON*' AND length(boundary_wkt) > 20),
    CHECK (kind <> 'restricted' OR tenant_id IS NULL)
) STRICT;

CREATE INDEX geo_geofences_tenant_kind_idx
    ON geo_geofences (tenant_id, kind)
    WHERE retired_at IS NULL;

CREATE INDEX geo_geofences_global_idx
    ON geo_geofences (kind)
    WHERE tenant_id IS NULL AND retired_at IS NULL;

-- GiST spatial index का स्थानापन्न। R*Tree virtual table सिर्फ़ bounding box
-- रखता है, इसलिए यह मोटी छँटाई है — असली point-in-polygon geo-service करती है
-- (या app में एक छोटा ray-casting)। rowid को geofence_id से जोड़ने के लिए एक
-- सहायक mapping चाहिए, क्योंकि R*Tree की कुंजी INTEGER ही हो सकती है।
CREATE VIRTUAL TABLE geo_geofence_bbox USING rtree (
    id,          -- geo_geofence_rowids.rowid से मेल खाता है
    min_lon, max_lon,
    min_lat, max_lat
);

CREATE TABLE geo_geofence_rowids (
    rowid_key   INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    geofence_id TEXT    NOT NULL UNIQUE REFERENCES geo_geofences (geofence_id) ON DELETE CASCADE
) STRICT;

-- fence हटते ही उसका bounding box भी जाना चाहिए, वरना R*Tree में मुर्दा प्रविष्टि
-- बची रहती है और PointInFence उस पर उम्मीदवार लौटाता रहता है।
CREATE TRIGGER geo_geofence_bbox_cleanup_ad
AFTER DELETE ON geo_geofence_rowids
FOR EACH ROW
BEGIN
    DELETE FROM geo_geofence_bbox WHERE id = OLD.rowid_key;
END;

CREATE TABLE geo_border_crossings (
    crossing_id         TEXT    NOT NULL PRIMARY KEY,
    from_country        TEXT    NOT NULL,
    to_country          TEXT    NOT NULL,
    unlocode            TEXT    NOT NULL,
    customs_office_code TEXT    NOT NULL,   -- customs_customs_declarations पर उद्धृत
    geofence_id         TEXT    NOT NULL REFERENCES geo_geofences (geofence_id),
    -- TEXT[] नहीं है → JSON array।
    modes_allowed       TEXT    NOT NULL,
    avg_dwell_minutes   INTEGER NOT NULL CHECK (avg_dwell_minutes >= 0),
    open_24h            INTEGER NOT NULL DEFAULT 1 CHECK (open_24h IN (0, 1)),

    UNIQUE (from_country, to_country, unlocode),
    CHECK (crossing_id GLOB 'bxg_[0-9A-Z]*' AND length(crossing_id) = 30),
    CHECK (from_country <> to_country),
    CHECK (length(unlocode) = 5),
    CHECK (json_valid(modes_allowed)
           AND json_type(modes_allowed) = 'array'
           AND json_array_length(modes_allowed) > 0)
) STRICT;

CREATE INDEX geo_crossings_pair_dwell_idx
    ON geo_border_crossings (from_country, to_country, avg_dwell_minutes);

CREATE INDEX geo_crossings_office_idx ON geo_border_crossings (customs_office_code);

-- GIN का कोई स्थानापन्न नहीं है। JSON array में खोज के लिए एक निकाली हुई
-- (extracted) table रखते हैं जिसे trigger भरता है — यही SQLite में
-- 'array पर index' का व्यावहारिक रूप है।
CREATE TABLE geo_border_crossing_modes (
    crossing_id TEXT NOT NULL REFERENCES geo_border_crossings (crossing_id) ON DELETE CASCADE,
    mode        TEXT NOT NULL CHECK (mode IN ('road','rail','sea','air','barge')),
    PRIMARY KEY (crossing_id, mode)
) STRICT;

CREATE INDEX geo_crossing_modes_by_mode_idx ON geo_border_crossing_modes (mode);

CREATE TRIGGER geo_crossings_extract_modes_ai
AFTER INSERT ON geo_border_crossings
FOR EACH ROW
BEGIN
    INSERT INTO geo_border_crossing_modes (crossing_id, mode)
    SELECT NEW.crossing_id, value FROM json_each(NEW.modes_allowed);
END;

CREATE TRIGGER geo_crossings_extract_modes_au
AFTER UPDATE OF modes_allowed ON geo_border_crossings
FOR EACH ROW
BEGIN
    DELETE FROM geo_border_crossing_modes WHERE crossing_id = NEW.crossing_id;
    INSERT INTO geo_border_crossing_modes (crossing_id, mode)
    SELECT NEW.crossing_id, value FROM json_each(NEW.modes_allowed);
END;

CREATE TABLE routing_routes (
    route_id         TEXT    NOT NULL PRIMARY KEY,
    shipment_id      TEXT    NOT NULL,   -- logical FK → freight_shipments
    version          INTEGER NOT NULL CHECK (version >= 1),
    is_current       INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
    planned_by       TEXT    NOT NULL,
    strategy         TEXT    NOT NULL CHECK (strategy IN
                       ('cheapest','fastest','lowest_carbon','customs_optimised','manual')),
    total_distance_m INTEGER NOT NULL CHECK (total_distance_m >= 0),
    total_duration_s INTEGER NOT NULL CHECK (total_duration_s >= 0),
    computed_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    superseded_at    TEXT,

    UNIQUE (shipment_id, version),
    CHECK (route_id GLOB 'rte_[0-9A-Z]*' AND length(route_id) = 30),
    CHECK (planned_by = 'svc:routing-service' OR planned_by GLOB 'usr_[0-9A-Z]*'),
    CHECK (is_current = 0 OR superseded_at IS NULL)
) STRICT;

CREATE UNIQUE INDEX routing_routes_one_current_per_shipment
    ON routing_routes (shipment_id)
    WHERE is_current = 1;

CREATE INDEX routing_routes_history_idx ON routing_routes (shipment_id, version DESC);

CREATE TABLE routing_route_legs (
    leg_id            TEXT    NOT NULL PRIMARY KEY,
    route_id          TEXT    NOT NULL REFERENCES routing_routes (route_id) ON DELETE CASCADE,
    seq_no            INTEGER NOT NULL CHECK (seq_no >= 1),
    mode              TEXT    NOT NULL CHECK (mode IN ('road','rail','sea','air','barge')),
    from_facility_id  TEXT    NOT NULL,
    to_facility_id    TEXT    NOT NULL,
    crossing_id       TEXT    REFERENCES geo_border_crossings (crossing_id),
    planned_depart_at TEXT    NOT NULL,
    planned_arrive_at TEXT    NOT NULL,
    actual_depart_at  TEXT,
    actual_arrive_at  TEXT,
    distance_m        INTEGER NOT NULL CHECK (distance_m >= 0),
    carrier_id        TEXT,

    UNIQUE (route_id, seq_no),
    CHECK (leg_id GLOB 'leg_[0-9A-Z]*' AND length(leg_id) = 30),
    CHECK (planned_arrive_at > planned_depart_at),
    CHECK (actual_arrive_at IS NULL OR actual_depart_at IS NULL
           OR actual_arrive_at >= actual_depart_at),
    CHECK (from_facility_id <> to_facility_id),
    -- हवाई और समुद्री legs सीमा-चौकी से नहीं गुज़रतीं।
    CHECK (crossing_id IS NULL OR mode IN ('road','rail','barge'))
) STRICT;

CREATE INDEX routing_route_legs_open_idx
    ON routing_route_legs (route_id)
    WHERE actual_arrive_at IS NULL;

CREATE INDEX routing_route_legs_crossing_idx
    ON routing_route_legs (crossing_id)
    WHERE crossing_id IS NOT NULL;

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0005_geo_and_routing', '0005');
