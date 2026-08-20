-- ---------------------------------------------------------------------------
-- 0003_fleet.sql
--
-- fleet-service की पाँच tables। इस फ़ाइल का पूरा वज़न एक ही समस्या पर है:
-- PostgreSQL में fleet.vehicle_assignments का ओवरलैप-निषेध दो GiST EXCLUDE
-- constraints से आता है, और MySQL में EXCLUDE है ही नहीं। यहाँ वही नियम trigger
-- से लागू होता है, और उसकी सीमाएँ नीचे साफ़ लिखी हैं।
--
-- SPEC.md §2.2, §3.2।
-- ---------------------------------------------------------------------------

CREATE TABLE fleet.carriers (
    carrier_id           VARCHAR(30)  NOT NULL,
    tenant_id            VARCHAR(30)  NOT NULL,   -- logical FK → identity.tenants
    scac_code            CHAR(4)      NULL,
    name                 VARCHAR(255) NOT NULL,
    country_code         CHAR(2)      NOT NULL,
    insurance_expires_on DATE         NOT NULL,
    is_subcontractor     TINYINT(1)   NOT NULL DEFAULT 0,
    created_at           DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (carrier_id),

    -- PostgreSQL में यह `CREATE UNIQUE INDEX … WHERE scac_code IS NOT NULL` था।
    -- MySQL में साधारण UNIQUE KEY वही काम करती है क्योंकि InnoDB कई NULL को आपस
    -- में अलग मानता है — यह उन गिनी-चुनी जगहों में से एक है जहाँ MySQL कम
    -- मेहनत माँगता है, ज़्यादा नहीं।
    UNIQUE KEY carriers_scac (scac_code),

    CONSTRAINT carriers_scac_is_uppercase
        CHECK (scac_code IS NULL OR scac_code REGEXP '^[A-Z]{4}$'),

    KEY carriers_tenant_idx (tenant_id, name),
    KEY carriers_insurance_idx (insurance_expires_on)
) ENGINE = InnoDB;

CREATE TABLE fleet.vehicles (
    vehicle_id         VARCHAR(30) NOT NULL,
    carrier_id         VARCHAR(30) NOT NULL,
    plate              VARCHAR(32) NOT NULL,
    plate_country      CHAR(2)     NOT NULL,
    vehicle_class      ENUM('van','rigid','tractor','chassis','reefer_tractor','rail_wagon','barge')
                                   NOT NULL,
    max_payload_kg     INT         NOT NULL,
    telematics_unit_id VARCHAR(64) NULL,   -- telemetry.device_gateways.serial का मान
    adr_certified      TINYINT(1)  NOT NULL DEFAULT 0,
    decommissioned_at  DATETIME(6) NULL,
    PRIMARY KEY (vehicle_id),
    UNIQUE KEY vehicles_plate (plate_country, plate),

    CONSTRAINT vehicles_payload_is_sane CHECK (max_payload_kg BETWEEN 0 AND 120000),
    CONSTRAINT vehicles_carrier_fk FOREIGN KEY (carrier_id)
        REFERENCES fleet.carriers (carrier_id),

    -- partial index की जगह पूरा index; decommissioned vehicles कुल का ~8% हैं,
    -- इसलिए फ़र्क़ सहनीय है और query में `decommissioned_at IS NULL` जुड़ा रहता है।
    KEY vehicles_roster_idx (carrier_id, decommissioned_at),
    KEY vehicles_adr_idx (carrier_id, adr_certified, decommissioned_at)
) ENGINE = InnoDB;

CREATE TABLE fleet.drivers (
    driver_id          VARCHAR(30)  NOT NULL,
    carrier_id         VARCHAR(30)  NOT NULL,
    user_id            VARCHAR(30)  NULL,   -- उप-ठेके के drivers का console खाता नहीं होता
    full_name          VARCHAR(255) NOT NULL,
    licence_number     VARCHAR(64)  NOT NULL,
    licence_country    CHAR(2)      NOT NULL,
    licence_expires_on DATE         NOT NULL,
    adr_expires_on     DATE         NULL,
    phone_e164         VARCHAR(20)  NOT NULL,
    PRIMARY KEY (driver_id),
    UNIQUE KEY drivers_licence (licence_country, licence_number),
    UNIQUE KEY drivers_user_link (user_id),

    CONSTRAINT drivers_phone_is_e164 CHECK (phone_e164 REGEXP '^\\+[1-9][0-9]{6,14}$'),
    CONSTRAINT drivers_carrier_fk FOREIGN KEY (carrier_id)
        REFERENCES fleet.carriers (carrier_id),

    KEY drivers_licence_expiry_idx (licence_expires_on, carrier_id),
    KEY drivers_adr_expiry_idx (adr_expires_on)
) ENGINE = InnoDB;

-- यहाँ बोली सचमुच आड़े आती है। PostgreSQL में:
--
--     EXCLUDE USING gist (vehicle_id WITH =, active_period WITH &&)
--
-- MySQL में न range type है, न GiST, न EXCLUDE। तीन बातें बदलनी पड़ीं:
--
--   1. active_period generated column नहीं बन सकता (range type ही नहीं), इसलिए
--      assigned_at/released_at ही रहते हैं और released_at IS NULL का मतलब
--      'अभी खुली' है।
--   2. ओवरलैप की जाँच BEFORE INSERT trigger करती है — यानी वह पहले पढ़ता है, फिर
--      लिखता है। दो समानांतर Assign में दोनों को खाली दिख सकता है।
--   3. इसीलिए fleet.v1.FleetService/Assign यहाँ पहले
--      `SELECT … FROM fleet.vehicles WHERE vehicle_id = ? FOR UPDATE` लेती है।
--      वह row lock ही असली मध्यस्थ है; trigger सिर्फ़ दूसरी परत है।
--      OF_FLEET_ASSIGNMENT_LOCK_TIMEOUT_MS उसी lock की प्रतीक्षा है।
CREATE TABLE fleet.vehicle_assignments (
    assignment_id VARCHAR(30) NOT NULL,
    vehicle_id    VARCHAR(30) NOT NULL,
    driver_id     VARCHAR(30) NOT NULL,
    shipment_id   VARCHAR(30) NOT NULL,   -- logical FK → freight.shipments
    leg_id        VARCHAR(30) NULL,       -- logical FK → routing.route_legs
    assigned_at   DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    released_at   DATETIME(6) NULL,
    assigned_by   VARCHAR(64) NOT NULL,
    PRIMARY KEY (assignment_id),

    CONSTRAINT assignments_release_after_assign
        CHECK (released_at IS NULL OR released_at > assigned_at),
    CONSTRAINT assignments_vehicle_fk FOREIGN KEY (vehicle_id)
        REFERENCES fleet.vehicles (vehicle_id),
    CONSTRAINT assignments_driver_fk FOREIGN KEY (driver_id)
        REFERENCES fleet.drivers (driver_id),

    -- ओवरलैप की जाँच इन्हीं दो indexes पर चलती है; इसलिए ये सजावट नहीं, नियम का
    -- हिस्सा हैं।
    KEY assignments_vehicle_window_idx (vehicle_id, assigned_at, released_at),
    KEY assignments_driver_window_idx  (driver_id,  assigned_at, released_at),
    KEY assignments_shipment_idx (shipment_id, assigned_at),
    KEY assignments_leg_idx (leg_id)
) ENGINE = InnoDB
  COMMENT = 'ओवरलैप-निषेध trigger + SELECT FOR UPDATE से; PostgreSQL में यह EXCLUDE constraint है';

DELIMITER $$

CREATE TRIGGER vehicle_assignments_no_overlap_bi
BEFORE INSERT ON fleet.vehicle_assignments
FOR EACH ROW
BEGIN
    DECLARE clashing INT DEFAULT 0;

    -- अंतराल [assigned_at, released_at) की टक्कर: दो अंतराल तभी टकराते हैं जब
    -- एक की शुरुआत दूसरे के अंत से पहले हो और उल्टा भी। released_at NULL का
    -- मतलब अनंत है, इसलिए COALESCE से उसे दूर की तारीख़ बना देते हैं।
    SELECT COUNT(*) INTO clashing
      FROM fleet.vehicle_assignments
     WHERE vehicle_id = NEW.vehicle_id
       AND NEW.assigned_at < COALESCE(released_at, '9999-12-31 00:00:00')
       AND assigned_at < COALESCE(NEW.released_at, '9999-12-31 00:00:00');

    IF clashing > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'vehicle_already_assigned: overlapping assignment exists';
    END IF;

    SELECT COUNT(*) INTO clashing
      FROM fleet.vehicle_assignments
     WHERE driver_id = NEW.driver_id
       AND NEW.assigned_at < COALESCE(released_at, '9999-12-31 00:00:00')
       AND assigned_at < COALESCE(NEW.released_at, '9999-12-31 00:00:00');

    IF clashing > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'driver_already_assigned: overlapping assignment exists';
    END IF;
END$$

-- released_at भरने पर भी वही जाँच ज़रूरी है, वरना एक खुली assignment को पीछे की
-- तारीख़ पर बंद करके उसके ऊपर दूसरी घुसाई जा सकती थी।
CREATE TRIGGER vehicle_assignments_no_overlap_bu
BEFORE UPDATE ON fleet.vehicle_assignments
FOR EACH ROW
BEGIN
    DECLARE clashing INT DEFAULT 0;

    IF NEW.released_at IS NOT NULL AND OLD.released_at IS NULL THEN
        SELECT COUNT(*) INTO clashing
          FROM fleet.vehicle_assignments
         WHERE vehicle_id = NEW.vehicle_id
           AND assignment_id <> NEW.assignment_id
           AND NEW.assigned_at < COALESCE(released_at, '9999-12-31 00:00:00')
           AND assigned_at < NEW.released_at;

        IF clashing > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'release would expose an overlapping assignment';
        END IF;
    END IF;
END$$

DELIMITER ;

CREATE TABLE fleet.depots (
    depot_id    VARCHAR(30)  NOT NULL,
    tenant_id   VARCHAR(30)  NOT NULL,
    name        VARCHAR(255) NOT NULL,
    geofence_id VARCHAR(30)  NOT NULL,   -- logical FK → geo.geofences
    unlocode    CHAR(5)      NULL,
    timezone    VARCHAR(64)  NOT NULL,   -- IANA नाम, offset नहीं
    region_code VARCHAR(16)  NOT NULL,
    opened_on   DATE         NOT NULL,
    closed_on   DATE         NULL,
    PRIMARY KEY (depot_id),

    CONSTRAINT depots_unlocode_shape
        CHECK (unlocode IS NULL OR unlocode REGEXP '^[A-Z]{2}[A-Z2-9]{3}$'),
    CONSTRAINT depots_closed_after_opened
        CHECK (closed_on IS NULL OR closed_on >= opened_on),
    CONSTRAINT depots_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code),

    KEY depots_region_idx (region_code, tenant_id),
    KEY depots_geofence_idx (geofence_id)
) ENGINE = InnoDB;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0003_fleet', UNHEX(SHA2('0003', 256)));
