-- ---------------------------------------------------------------------------
-- 0003_fleet.sql
--
-- fleet-service की पाँच tables। driver-ios इन्हीं में से vehicles, drivers और
-- vehicle_assignments को offline रखता है — driver को अपनी अगली assignment तब भी
-- दिखनी चाहिए जब बंदरगाह में नेटवर्क न हो।
--
-- सबसे बड़ा भेद वही है जो mysql/ शाखा में था: EXCLUDE constraint नहीं है। पर
-- यहाँ हालात आसान हैं — यह cache है, और असली मध्यस्थता fleet-service के
-- PostgreSQL पर होती है। इसलिए trigger सिर्फ़ स्थानीय असंगति पकड़ता है, नियम नहीं
-- बनाता।
--
-- SPEC.md §2.2।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

CREATE TABLE fleet_carriers (
    carrier_id           TEXT    NOT NULL PRIMARY KEY,
    tenant_id            TEXT    NOT NULL,   -- logical FK → identity_tenants
    scac_code            TEXT,
    name                 TEXT    NOT NULL,
    country_code         TEXT    NOT NULL,
    insurance_expires_on TEXT    NOT NULL,   -- ISO date, '_on' उपसर्ग SPEC.md §0.2
    is_subcontractor     INTEGER NOT NULL DEFAULT 0 CHECK (is_subcontractor IN (0, 1)),
    created_at           TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    CHECK (carrier_id GLOB 'car_[0-9A-Z]*' AND length(carrier_id) = 30),
    CHECK (scac_code IS NULL OR (length(scac_code) = 4 AND scac_code GLOB '[A-Z][A-Z][A-Z][A-Z]')),
    CHECK (insurance_expires_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')
) STRICT;

-- partial unique index — SQLite में यह PostgreSQL जैसा ही चलता है।
CREATE UNIQUE INDEX fleet_carriers_scac_idx
    ON fleet_carriers (scac_code)
    WHERE scac_code IS NOT NULL;

CREATE INDEX fleet_carriers_tenant_idx ON fleet_carriers (tenant_id, name);

CREATE TABLE fleet_vehicles (
    vehicle_id         TEXT    NOT NULL PRIMARY KEY,
    carrier_id         TEXT    NOT NULL REFERENCES fleet_carriers (carrier_id),
    plate              TEXT    NOT NULL,
    plate_country      TEXT    NOT NULL,
    vehicle_class      TEXT    NOT NULL CHECK (vehicle_class IN
                         ('van','rigid','tractor','chassis','reefer_tractor','rail_wagon','barge')),
    max_payload_kg     INTEGER NOT NULL CHECK (max_payload_kg BETWEEN 0 AND 120000),
    telematics_unit_id TEXT,   -- telemetry_device_gateways.serial का मान
    adr_certified      INTEGER NOT NULL DEFAULT 0 CHECK (adr_certified IN (0, 1)),
    decommissioned_at  TEXT,

    UNIQUE (plate_country, plate),
    CHECK (vehicle_id GLOB 'veh_[0-9A-Z]*' AND length(vehicle_id) = 30)
) STRICT;

CREATE INDEX fleet_vehicles_roster_idx
    ON fleet_vehicles (carrier_id)
    WHERE decommissioned_at IS NULL;

CREATE INDEX fleet_vehicles_adr_idx
    ON fleet_vehicles (carrier_id)
    WHERE adr_certified = 1 AND decommissioned_at IS NULL;

CREATE TABLE fleet_drivers (
    driver_id          TEXT NOT NULL PRIMARY KEY,
    carrier_id         TEXT NOT NULL REFERENCES fleet_carriers (carrier_id),
    -- उप-ठेके के drivers का console खाता महीनों बाद बनता है, या कभी नहीं।
    user_id            TEXT,
    full_name          TEXT NOT NULL,
    licence_number     TEXT NOT NULL,
    licence_country    TEXT NOT NULL,
    licence_expires_on TEXT NOT NULL,
    adr_expires_on     TEXT,
    phone_e164         TEXT NOT NULL,

    UNIQUE (licence_country, licence_number),
    CHECK (driver_id GLOB 'drv_[0-9A-Z]*' AND length(driver_id) = 30),
    -- E.164: '+' के बाद 7 से 15 अंक। GLOB में गिनती नहीं होती, इसलिए लंबाई अलग
    -- से जाँची जाती है — REGEXP वाली एक पंक्ति यहाँ दो में बँटती है।
    CHECK (phone_e164 GLOB '+[1-9]*' AND length(phone_e164) BETWEEN 8 AND 16),
    CHECK (user_id IS NULL OR (user_id GLOB 'usr_[0-9A-Z]*' AND length(user_id) = 30))
) STRICT;

CREATE UNIQUE INDEX fleet_drivers_user_idx
    ON fleet_drivers (user_id)
    WHERE user_id IS NOT NULL;

CREATE INDEX fleet_drivers_licence_expiry_idx ON fleet_drivers (licence_expires_on, carrier_id);
CREATE INDEX fleet_drivers_adr_expiry_idx
    ON fleet_drivers (adr_expires_on)
    WHERE adr_expires_on IS NOT NULL;

-- TSTZRANGE नहीं है, GENERATED column के भीतर range बन ही नहीं सकता। दोनों
-- सिरे अलग columns में हैं और ओवरलैप की जाँच trigger करता है। ध्यान रहे: यह
-- नियम यहाँ *लागू* नहीं होता — असली मध्यस्थ fleet-service का PostgreSQL है।
-- यहाँ trigger का काम सिर्फ़ यह पकड़ना है कि sync ने असंगत स्थिति भेजी, ताकि
-- driver को दो assignments एक साथ न दिखें।
CREATE TABLE fleet_vehicle_assignments (
    assignment_id TEXT NOT NULL PRIMARY KEY,
    vehicle_id    TEXT NOT NULL REFERENCES fleet_vehicles (vehicle_id),
    driver_id     TEXT NOT NULL REFERENCES fleet_drivers (driver_id),
    shipment_id   TEXT NOT NULL,   -- logical FK → freight_shipments
    leg_id        TEXT,            -- logical FK → routing_route_legs
    assigned_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    released_at   TEXT,
    assigned_by   TEXT NOT NULL,

    CHECK (assignment_id GLOB 'asg_[0-9A-Z]*' AND length(assignment_id) = 30),
    CHECK (shipment_id GLOB 'shp_[0-9A-Z]*'),
    CHECK (released_at IS NULL OR released_at > assigned_at)
) STRICT;

CREATE INDEX fleet_assignments_vehicle_window_idx
    ON fleet_vehicle_assignments (vehicle_id, assigned_at, released_at);
CREATE INDEX fleet_assignments_driver_window_idx
    ON fleet_vehicle_assignments (driver_id, assigned_at, released_at);
CREATE INDEX fleet_assignments_shipment_idx
    ON fleet_vehicle_assignments (shipment_id, assigned_at);
CREATE INDEX fleet_assignments_open_idx
    ON fleet_vehicle_assignments (vehicle_id, driver_id)
    WHERE released_at IS NULL;

-- SQLite में RAISE(ABORT, …) trigger का इकलौता तरीक़ा है exception फेंकने का।
-- खुली assignment का ऊपरी सिरा NULL है, इसलिए तुलना में उसे '9999…' बना देते हैं
-- — TEXT की शाब्दिक तुलना ISO-8601 पर कालानुक्रमिक ही होती है, यही इस रूप का
-- पूरा फ़ायदा है।
CREATE TRIGGER fleet_assignments_no_overlap_bi
BEFORE INSERT ON fleet_vehicle_assignments
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM fleet_vehicle_assignments a
     WHERE a.vehicle_id = NEW.vehicle_id
       AND NEW.assigned_at < COALESCE(a.released_at, '9999-12-31T00:00:00.000Z')
       AND a.assigned_at   < COALESCE(NEW.released_at, '9999-12-31T00:00:00.000Z')
)
BEGIN
    SELECT RAISE(ABORT, 'vehicle_already_assigned: overlapping assignment in local cache');
END;

CREATE TRIGGER fleet_assignments_driver_no_overlap_bi
BEFORE INSERT ON fleet_vehicle_assignments
FOR EACH ROW
WHEN EXISTS (
    SELECT 1 FROM fleet_vehicle_assignments a
     WHERE a.driver_id = NEW.driver_id
       AND NEW.assigned_at < COALESCE(a.released_at, '9999-12-31T00:00:00.000Z')
       AND a.assigned_at   < COALESCE(NEW.released_at, '9999-12-31T00:00:00.000Z')
)
BEGIN
    SELECT RAISE(ABORT, 'driver_already_assigned: overlapping assignment in local cache');
END;

CREATE TABLE fleet_depots (
    depot_id    TEXT NOT NULL PRIMARY KEY,
    tenant_id   TEXT NOT NULL,
    name        TEXT NOT NULL,
    geofence_id TEXT NOT NULL,   -- logical FK → geo_geofences
    unlocode    TEXT,
    timezone    TEXT NOT NULL,   -- IANA नाम; offset रखने पर हर मार्च में गलत होता है
    region_code TEXT NOT NULL REFERENCES platform_region_codes (region_code),
    opened_on   TEXT NOT NULL,
    closed_on   TEXT,

    CHECK (depot_id GLOB 'dep_[0-9A-Z]*' AND length(depot_id) = 30),
    CHECK (unlocode IS NULL OR length(unlocode) = 5),
    CHECK (closed_on IS NULL OR closed_on >= opened_on)
) STRICT;

CREATE INDEX fleet_depots_region_idx
    ON fleet_depots (region_code, tenant_id)
    WHERE closed_on IS NULL;

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0003_fleet', '0003');
