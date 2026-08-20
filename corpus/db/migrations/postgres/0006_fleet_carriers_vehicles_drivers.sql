-- ---------------------------------------------------------------------------
-- 0006_fleet_carriers_vehicles_drivers.sql
--
-- fleet-service की तीन आधार tables: carriers, vehicles और drivers। तीनों को
-- fleet.v1.FleetService/CheckEligibility हर assignment से पहले पढ़ती है — licence
-- वैधता, ADR प्रमाणपत्र और insurance की समाप्ति यहीं से आती है।
--
-- SPEC.md §2.2।
-- ---------------------------------------------------------------------------

BEGIN;

-- Carrier का tenant_id जानबूझकर logical FK है, असली नहीं: fleet schema की मालिक
-- fleet-service है और वह identity schema को SQL से नहीं छूती (SPEC.md §7 नियम 2)।
-- यहाँ पंक्ति तभी बनती है जब identity-service ने tenant की पुष्टि कर दी हो।
CREATE TABLE fleet.carriers (
    carrier_id           TEXT        PRIMARY KEY,
    tenant_id            TEXT        NOT NULL,
    scac_code            CHAR(4),
    name                 TEXT        NOT NULL,
    country_code         CHAR(2)     NOT NULL,
    insurance_expires_on DATE        NOT NULL,
    is_subcontractor     BOOLEAN     NOT NULL DEFAULT false,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT carriers_id_is_prefixed_ulid
        CHECK (carrier_id ~ '^car_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- SCAC सिर्फ़ अमेरिकी carriers के पास होता है; बाक़ी के लिए NULL सही है, खाली
    -- string नहीं — वह UNIQUE index में टकराती।
    CONSTRAINT carriers_scac_is_uppercase
        CHECK (scac_code IS NULL OR scac_code ~ '^[A-Z]{4}$')
);

-- SCAC विश्व-स्तर पर अनूठा है पर सिर्फ़ तब जब मौजूद हो।
CREATE UNIQUE INDEX carriers_scac_unique_idx
    ON fleet.carriers (scac_code)
    WHERE scac_code IS NOT NULL;

-- Insurance समाप्ति की चेतावनी वाला nightly job केवल जीवित carriers देखता है।
CREATE INDEX carriers_insurance_expiry_idx
    ON fleet.carriers (insurance_expires_on)
    WHERE is_subcontractor = false;

CREATE INDEX carriers_tenant_idx ON fleet.carriers (tenant_id, name);

-- Vehicle की पहचान plate + plate_country है, न कि अकेला plate: वही अंक-अक्षर
-- संयोजन दो देशों में क़ानूनी रूप से मौजूद हो सकता है और सीमापार बेड़े में यह
-- रोज़ होता है।
CREATE TABLE fleet.vehicles (
    vehicle_id         TEXT        PRIMARY KEY,
    carrier_id         TEXT        NOT NULL REFERENCES fleet.carriers(carrier_id),
    plate              TEXT        NOT NULL,
    plate_country      CHAR(2)     NOT NULL,
    vehicle_class      TEXT        NOT NULL CHECK (vehicle_class IN
                         ('van','rigid','tractor','chassis','reefer_tractor','rail_wagon','barge')),
    max_payload_kg     INTEGER     NOT NULL,
    -- telemetry.device_gateways.serial से मेल खाता है, पर FK नहीं: gateway
    -- telemetry-ingest की schema में है और वह पंक्ति अक्सर vehicle के बाद बनती है।
    telematics_unit_id TEXT,
    adr_certified      BOOLEAN     NOT NULL DEFAULT false,
    decommissioned_at  TIMESTAMPTZ,
    UNIQUE (plate_country, plate),

    CONSTRAINT vehicles_id_is_prefixed_ulid
        CHECK (vehicle_id ~ '^veh_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT vehicles_payload_is_sane CHECK (max_payload_kg BETWEEN 0 AND 120000)
);

COMMENT ON COLUMN fleet.vehicles.telematics_unit_id IS
    'telemetry.device_gateways.serial का मान; cross-schema FK नहीं, SPEC.md §2 की अनुमत सूची में नहीं है';

-- GET /v1/carriers/{carrier_id}/vehicles cursor-paginated roster देती है और
-- सेवामुक्त vehicles को कभी नहीं दिखाती।
CREATE INDEX vehicles_active_roster_idx
    ON fleet.vehicles (carrier_id, vehicle_id)
    WHERE decommissioned_at IS NULL;

-- ADR वाले tractors की माँग dispatch में अलग से आती है (dangerous goods)।
CREATE INDEX vehicles_adr_idx
    ON fleet.vehicles (carrier_id)
    WHERE adr_certified AND decommissioned_at IS NULL;

-- user_id nullable है: उप-ठेके पर लिए गए drivers roster में महीनों पहले आ जाते
-- हैं और कई बार console login कभी बनता ही नहीं। इसे mandatory करना सीधे dispatch
-- रोक देता।
CREATE TABLE fleet.drivers (
    driver_id          TEXT        PRIMARY KEY,
    carrier_id         TEXT        NOT NULL REFERENCES fleet.carriers(carrier_id),
    user_id            TEXT,
    full_name          TEXT        NOT NULL,
    licence_number     TEXT        NOT NULL,
    licence_country    CHAR(2)     NOT NULL,
    licence_expires_on DATE        NOT NULL,
    adr_expires_on     DATE,
    phone_e164         TEXT        NOT NULL,
    UNIQUE (licence_country, licence_number),

    CONSTRAINT drivers_id_is_prefixed_ulid
        CHECK (driver_id ~ '^drv_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT drivers_phone_is_e164 CHECK (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
    -- driver-ios app push notifications के लिए user_id माँगता है; अगर है तो वह
    -- usr_ prefix वाला ही होना चाहिए।
    CONSTRAINT drivers_user_id_is_prefixed
        CHECK (user_id IS NULL OR user_id ~ '^usr_[0-9A-HJKMNP-TV-Z]{26}$')
);

-- OF_FLEET_LICENCE_EXPIRY_WARN_DAYS वाला job दोनों तारीख़ें एक साथ देखता है।
CREATE INDEX drivers_licence_expiry_idx
    ON fleet.drivers (licence_expires_on, carrier_id);

CREATE INDEX drivers_adr_expiry_idx
    ON fleet.drivers (adr_expires_on)
    WHERE adr_expires_on IS NOT NULL;

CREATE UNIQUE INDEX drivers_user_link_idx
    ON fleet.drivers (user_id)
    WHERE user_id IS NOT NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0006_fleet_carriers_vehicles_drivers', sha256('0006'::bytea));

COMMIT;
