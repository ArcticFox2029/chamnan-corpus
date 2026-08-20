-- ---------------------------------------------------------------------------
-- 0006_telemetry.sql
--
-- telemetry-ingest की tables, और इस पूरी शाखा का सबसे भारी बोली-भेद: MySQL की
-- partitioned table पर न foreign key लग सकती है, न SPATIAL index। दोनों पाबंदियाँ
-- यहाँ आकार बदलती हैं, और दोनों नीचे उसी जगह दर्ज हैं जहाँ वे काटती हैं।
--
-- SPEC.md §2.5।
-- ---------------------------------------------------------------------------

CREATE TABLE telemetry.device_gateways (
    gateway_id        VARCHAR(30)  NOT NULL,
    serial            VARCHAR(64)  NOT NULL,
    depot_id          VARCHAR(30)  NULL,   -- NULL = चलता-फिरता gateway
    region_code       VARCHAR(16)  NOT NULL,
    firmware_version  VARCHAR(32)  NOT NULL,
    public_key        CHAR(44)     NOT NULL,   -- Ed25519, base64
    last_heartbeat_at DATETIME(6)  NULL,
    provisioned_at    DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    decommissioned_at DATETIME(6)  NULL,
    PRIMARY KEY (gateway_id),
    UNIQUE KEY gateways_serial (serial),

    CONSTRAINT gateways_firmware_is_semver
        CHECK (firmware_version REGEXP '^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$'),
    CONSTRAINT gateways_public_key_shape
        CHECK (public_key REGEXP '^[A-Za-z0-9+/]{43}=$'),
    CONSTRAINT gateways_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code),

    KEY gateways_silence_sweep_idx (last_heartbeat_at, decommissioned_at),
    KEY gateways_depot_idx (depot_id),
    KEY gateways_firmware_idx (region_code, firmware_version)
) ENGINE = InnoDB;

-- Partitioning। MySQL का LIST COLUMNS स्ट्रिंग पर काम करता है, तो region-दर-region
-- विभाजन बना रहता है और SPEC.md §7 नियम 7 (data residency) निभता है। पर तीन
-- पाबंदियाँ साथ आती हैं:
--
--   1. partitioned table पर FOREIGN KEY बिलकुल नहीं लग सकती। PostgreSQL शाखा में
--      यहाँ कोई FK थी भी नहीं (जानबूझकर), इसलिए यह भेद बेअसर है — पर region_code
--      की platform.region_codes वाली FK भी नहीं लग सकी, और वह जाँच CHECK में
--      वापस आई।
--   2. हर UNIQUE key में partition column होना अनिवार्य है। dedupe वाली key में
--      region_code पहले से है, इसलिए यह अपने आप निभ गया।
--   3. SPATIAL index partitioned table पर नहीं बनता। स्थिति इसलिए यहीं column में
--      रहती है (query में उसका उपयोग हमेशा container+समय से छँटने के बाद होता
--      है, इसलिए index की कमी दिखती नहीं), पर geofence_breach नियम का बड़ा
--      spatial सवाल geo-service के अपने index से हल होता है, यहाँ से नहीं।
CREATE TABLE telemetry.telemetry_readings (
    reading_id      VARCHAR(30)  NOT NULL,
    region_code     VARCHAR(16)  NOT NULL,
    container_id    VARCHAR(30)  NOT NULL,
    gateway_id      VARCHAR(30)  NOT NULL,
    recorded_at     DATETIME(6)  NOT NULL,   -- सेंसर की घड़ी
    received_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),  -- हमारी घड़ी
    temperature_c   DECIMAL(5,2) NULL,
    humidity_pct    DECIMAL(5,2) NULL,
    shock_g         DECIMAL(6,3) NULL,
    door_open       TINYINT(1)   NULL,
    battery_pct     SMALLINT     NULL,
    position        POINT SRID 4326 NULL,
    ingest_batch_id VARCHAR(64)  NOT NULL,

    PRIMARY KEY (region_code, reading_id),
    UNIQUE KEY readings_dedupe_idx (region_code, ingest_batch_id, container_id, recorded_at),
    KEY readings_container_time_idx (container_id, recorded_at),
    KEY readings_gateway_time_idx (gateway_id, received_at),

    CONSTRAINT readings_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),
    CONSTRAINT readings_battery_is_percentage
        CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
    CONSTRAINT readings_temperature_is_physical
        CHECK (temperature_c IS NULL OR temperature_c BETWEEN -90.00 AND 90.00),
    CONSTRAINT readings_humidity_is_percentage
        CHECK (humidity_pct IS NULL OR humidity_pct BETWEEN 0.00 AND 100.00),
    CONSTRAINT readings_shock_not_negative CHECK (shock_g IS NULL OR shock_g >= 0)
) ENGINE = InnoDB
PARTITION BY LIST COLUMNS (region_code) (
    PARTITION p_eu_west    VALUES IN ('eu-west'),
    PARTITION p_eu_central VALUES IN ('eu-central'),
    PARTITION p_na_east    VALUES IN ('na-east'),
    PARTITION p_na_west    VALUES IN ('na-west'),
    PARTITION p_apac_sg    VALUES IN ('apac-sg'),
    PARTITION p_apac_jp    VALUES IN ('apac-jp'),
    PARTITION p_latam_br   VALUES IN ('latam-br'),
    PARTITION p_mea_ae     VALUES IN ('mea-ae')
);

CREATE TABLE telemetry.telemetry_alerts (
    alert_id         VARCHAR(30)   NOT NULL,
    container_id     VARCHAR(30)   NOT NULL,
    shipment_id      VARCHAR(30)   NULL,   -- खाली डिब्बे का कोई shipment नहीं होता
    rule_code        ENUM('temp_excursion_high','temp_excursion_low','humidity_high',
                          'shock_impact','door_open_in_transit','battery_critical',
                          'gateway_silent','geofence_breach') NOT NULL,
    severity         TINYINT       NOT NULL,
    opened_at        DATETIME(6)   NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    closed_at        DATETIME(6)   NULL,
    peak_value       DECIMAL(10,3) NULL,
    threshold_value  DECIMAL(10,3) NOT NULL,
    first_reading_id VARCHAR(30)   NOT NULL,
    acknowledged_by  VARCHAR(30)   NULL,
    acknowledged_at  DATETIME(6)   NULL,
    PRIMARY KEY (alert_id),

    CONSTRAINT alerts_severity_range CHECK (severity BETWEEN 1 AND 5),
    CONSTRAINT alerts_close_after_open CHECK (closed_at IS NULL OR closed_at >= opened_at),
    CONSTRAINT alerts_ack_is_complete
        CHECK ((acknowledged_by IS NULL) = (acknowledged_at IS NULL)),
    CONSTRAINT alerts_peak_required_for_measured_rules
        CHECK (rule_code IN ('gateway_silent','door_open_in_transit') OR peak_value IS NOT NULL),

    KEY alerts_open_idx (container_id, closed_at),
    KEY alerts_triage_idx (rule_code, severity, opened_at),
    KEY alerts_shipment_idx (shipment_id, opened_at)
) ENGINE = InnoDB
  COMMENT = 'telemetry.alert.raised यहीं से निकलता है; container-registry उसे खाकर shipment at_risk करती है';

-- Retention नीति per-region — क़ानून हर region में अलग है।
CREATE TABLE telemetry.retention_policy (
    region_code   VARCHAR(16)  NOT NULL,
    readings_days INT          NOT NULL,
    alerts_days   INT          NOT NULL,
    legal_basis   VARCHAR(255) NOT NULL,
    reviewed_on   DATE         NOT NULL,
    PRIMARY KEY (region_code),
    CONSTRAINT retention_days_are_positive
        CHECK (readings_days > 0 AND alerts_days >= readings_days),
    CONSTRAINT retention_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code)
) ENGINE = InnoDB;

INSERT INTO telemetry.retention_policy VALUES
  ('eu-west',    730,  1825, 'GDPR Art. 5(1)(e) + carrier contract', '2026-01-15'),
  ('eu-central', 730,  1825, 'GDPR Art. 5(1)(e) + carrier contract', '2026-01-15'),
  ('na-east',    1095, 2555, 'FMCSA record-keeping', '2026-02-02'),
  ('na-west',    1095, 2555, 'FMCSA record-keeping', '2026-02-02'),
  ('apac-sg',    365,  1095, 'PDPA + customs advance ruling window', '2025-11-30'),
  ('apac-jp',    365,  1095, 'APPI', '2025-11-30'),
  ('latam-br',   1825, 1825, 'LGPD + ANTT cold-chain evidence requirement', '2026-03-11'),
  ('mea-ae',     730,  1825, 'UAE Federal Decree-Law 45 of 2021', '2026-01-20');

DELIMITER $$

-- PostgreSQL शाखा में यह batch-दर-batch DELETE करने वाली procedure थी। MySQL में
-- partition drop-and-recreate सस्ता होता, पर region partition स्थायी है (region
-- कभी हटता नहीं), इसलिए यहाँ भी DELETE ही है — बस LIMIT के साथ, ताकि लंबी
-- transaction ingest को न रोके।
CREATE PROCEDURE telemetry.prune_readings(IN p_region VARCHAR(16), IN p_batch_size INT)
BEGIN
    DECLARE keep_days INT;
    DECLARE removed INT DEFAULT 1;

    SELECT readings_days INTO keep_days
      FROM telemetry.retention_policy WHERE region_code = p_region;

    IF keep_days IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no retention policy for region';
    END IF;

    WHILE removed > 0 DO
        DELETE FROM telemetry.telemetry_readings
         WHERE region_code = p_region
           AND recorded_at < DATE_SUB(UTC_TIMESTAMP(6), INTERVAL keep_days DAY)
         LIMIT p_batch_size;

        SET removed = ROW_COUNT();
        DO SLEEP(0.05);   -- ingest को साँस लेने की जगह
    END WHILE;
END$$

DELIMITER ;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0006_telemetry', UNHEX(SHA2('0006', 256)));
