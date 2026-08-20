-- ---------------------------------------------------------------------------
-- 0004_freight.sql
--
-- container-registry की छह tables। यहाँ दो बोली-भेद बड़े हैं: spatial column पर
-- MySQL SRID को column-स्तर पर बाँधता है (और SPATIAL index के लिए NOT NULL
-- माँगता है, इसलिए scan की स्थिति अलग table में गई), और partial unique index की
-- जगह फिर से generated-NULL वाली चाल है।
--
-- SPEC.md §2.3।
-- ---------------------------------------------------------------------------

CREATE TABLE freight.facilities (
    facility_id  VARCHAR(30)  NOT NULL,
    tenant_id    VARCHAR(30)  NOT NULL,
    kind         ENUM('seaport','airport','rail_terminal','warehouse','customer_site','bonded_store')
                              NOT NULL,
    name         VARCHAR(255) NOT NULL,
    country_code CHAR(2)      NOT NULL,
    unlocode     CHAR(5)      NULL,
    geofence_id  VARCHAR(30)  NOT NULL,
    region_code  VARCHAR(16)  NOT NULL,
    created_at   DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (facility_id),

    CONSTRAINT facilities_ports_need_unlocode
        CHECK (kind NOT IN ('seaport','airport','rail_terminal') OR unlocode IS NOT NULL),
    CONSTRAINT facilities_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code),

    KEY facilities_tenant_kind_idx (tenant_id, kind),
    KEY facilities_unlocode_idx (unlocode)
) ENGINE = InnoDB;

CREATE TABLE freight.containers (
    container_id     VARCHAR(30) NOT NULL,
    iso_code         CHAR(11)    NOT NULL,
    iso_size_type    CHAR(4)     NOT NULL,
    owner_carrier_id VARCHAR(30) NULL,
    tare_weight_kg   INT         NOT NULL,
    max_gross_kg     INT         NOT NULL,
    is_reefer        TINYINT(1)  NOT NULL DEFAULT 0,
    setpoint_c       DECIMAL(5,2) NULL,
    -- FK नहीं, जानबूझकर: telemetry की table partitioned है और यह जोड़ी ~4 kHz पर
    -- बदलती है।
    last_reading_id  VARCHAR(30) NULL,
    last_reading_at  DATETIME(6) NULL,
    retired_at       DATETIME(6) NULL,
    PRIMARY KEY (container_id),
    UNIQUE KEY containers_iso_code (iso_code),

    CONSTRAINT containers_iso_code_shape CHECK (iso_code REGEXP '^[A-Z]{4}[0-9]{7}$'),
    CONSTRAINT containers_setpoint_only_for_reefer
        CHECK (setpoint_c IS NULL OR is_reefer = 1),
    CONSTRAINT containers_tare_below_max
        CHECK (tare_weight_kg > 0 AND max_gross_kg > tare_weight_kg),
    CONSTRAINT containers_setpoint_in_range
        CHECK (setpoint_c IS NULL OR setpoint_c BETWEEN -40.00 AND 30.00),

    -- SPEC.md §2 की अनुमत cross-schema FK। MySQL में cross-database FK चलती है
    -- क्योंकि दोनों databases एक ही InnoDB instance में हैं — पर यह तभी सही है
    -- जब दोनों एक ही सर्वर पर रहें; अलग करने पर यह constraint गिराना पड़ेगा और
    -- जाँच fleet-service पर आ जाएगी।
    CONSTRAINT containers_owner_carrier_fk FOREIGN KEY (owner_carrier_id)
        REFERENCES fleet.carriers (carrier_id),

    KEY containers_reefer_idx (is_reefer, retired_at),
    KEY containers_last_reading_idx (last_reading_at)
) ENGINE = InnoDB;

CREATE TABLE freight.hazard_classes (
    hazard_class_code VARCHAR(8)   NOT NULL,
    un_division       VARCHAR(8)   NOT NULL,
    placard_label     VARCHAR(128) NOT NULL,
    segregation_group VARCHAR(8)   NULL,
    PRIMARY KEY (hazard_class_code),
    CONSTRAINT hazard_code_shape CHECK (hazard_class_code REGEXP '^[1-9](\\.[1-9])?$')
) ENGINE = InnoDB;

INSERT INTO freight.hazard_classes VALUES
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

-- PostgreSQL: `CREATE UNIQUE INDEX … ON (container_id) WHERE is_primary`.
-- यहाँ वही काम primary_marker से — जो is_primary सच होने पर container_id रखती
-- है और बाक़ी पंक्तियों पर NULL, और NULL आपस में नहीं टकराते।
CREATE TABLE freight.container_hazard_classes (
    container_id      VARCHAR(30) NOT NULL,
    hazard_class_code VARCHAR(8)  NOT NULL,
    is_primary        TINYINT(1)  NOT NULL DEFAULT 0,
    declared_at       DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    primary_marker VARCHAR(30) GENERATED ALWAYS AS (
        CASE WHEN is_primary = 1 THEN container_id END
    ) STORED,

    PRIMARY KEY (container_id, hazard_class_code),
    UNIQUE KEY container_one_primary_hazard (primary_marker),

    CONSTRAINT chc_container_fk FOREIGN KEY (container_id)
        REFERENCES freight.containers (container_id) ON DELETE CASCADE,
    CONSTRAINT chc_class_fk FOREIGN KEY (hazard_class_code)
        REFERENCES freight.hazard_classes (hazard_class_code),

    KEY chc_by_class_idx (hazard_class_code)
) ENGINE = InnoDB;

CREATE TABLE freight.shipments (
    shipment_id             VARCHAR(30)  NOT NULL,
    tenant_id               VARCHAR(30)  NOT NULL,
    reference               VARCHAR(128) NOT NULL,
    origin_facility_id      VARCHAR(30)  NOT NULL,
    destination_facility_id VARCHAR(30)  NOT NULL,
    incoterm                CHAR(3)      NOT NULL,
    status                  ENUM('draft','booked','sealed','in_transit','at_risk',
                                 'held_at_customs','delivered','cancelled')
                                         NOT NULL DEFAULT 'draft',
    sla_deadline_at         DATETIME(6)  NULL,
    -- BIGINT minor units, कभी float नहीं (SPEC.md §0.2)।
    declared_value_minor    BIGINT       NOT NULL DEFAULT 0,
    currency                CHAR(3)      NOT NULL,
    region_code             VARCHAR(16)  NOT NULL,
    created_at              DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    delivered_at            DATETIME(6)  NULL,
    PRIMARY KEY (shipment_id),
    UNIQUE KEY shipments_tenant_reference (tenant_id, reference),

    CONSTRAINT shipments_endpoints_differ
        CHECK (origin_facility_id <> destination_facility_id),
    CONSTRAINT shipments_currency_is_iso4217 CHECK (currency REGEXP '^[A-Z]{3}$'),
    CONSTRAINT shipments_value_not_negative CHECK (declared_value_minor >= 0),
    CONSTRAINT shipments_delivered_has_timestamp
        CHECK ((status = 'delivered') = (delivered_at IS NOT NULL)),

    CONSTRAINT shipments_origin_fk FOREIGN KEY (origin_facility_id)
        REFERENCES freight.facilities (facility_id),
    CONSTRAINT shipments_destination_fk FOREIGN KEY (destination_facility_id)
        REFERENCES freight.facilities (facility_id),
    CONSTRAINT shipments_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code),

    KEY shipments_open_idx (tenant_id, status),
    KEY shipments_sla_watch_idx (sla_deadline_at, delivered_at),
    KEY shipments_lane_idx (origin_facility_id, destination_facility_id)
) ENGINE = InnoDB
  COMMENT = 'स्थिति बदलने का इकलौता रास्ता PATCH /v1/shipments/{id}/status है';

CREATE TABLE freight.shipment_containers (
    shipment_id  VARCHAR(30) NOT NULL,
    container_id VARCHAR(30) NOT NULL,
    seal_number  VARCHAR(64) NOT NULL,
    gross_kg     INT         NOT NULL,
    loaded_at    DATETIME(6) NULL,
    unloaded_at  DATETIME(6) NULL,
    PRIMARY KEY (shipment_id, container_id),

    CONSTRAINT sc_gross_is_positive CHECK (gross_kg > 0),
    CONSTRAINT sc_unload_after_load
        CHECK (unloaded_at IS NULL OR loaded_at IS NULL OR unloaded_at >= loaded_at),
    CONSTRAINT sc_shipment_fk FOREIGN KEY (shipment_id)
        REFERENCES freight.shipments (shipment_id) ON DELETE CASCADE,
    CONSTRAINT sc_container_fk FOREIGN KEY (container_id)
        REFERENCES freight.containers (container_id),

    KEY sc_by_container_idx (container_id, loaded_at)
) ENGINE = InnoDB;

-- Spatial: MySQL में geography type नहीं है। POINT को SRID 4326 पर बाँधा गया है
-- (`SRID 4326` column attribute), जिससे ST_Distance मीटर लौटाता है — वही जो
-- PostGIS का geography देता है। पर SPATIAL INDEX के लिए column NOT NULL होना
-- अनिवार्य है, और अधिकांश scans बिना स्थिति के आती हैं (गोदाम के अंदर GPS नहीं
-- मिलता)। इसलिए स्थिति अलग table में रखी गई है और वहाँ वह NOT NULL है।
CREATE TABLE freight.shipment_scan_events (
    scan_id            VARCHAR(30)  NOT NULL,
    shipment_id        VARCHAR(30)  NOT NULL,
    container_id       VARCHAR(30)  NULL,
    scan_type          ENUM('gate_in','gate_out','load','unload','seal_check',
                            'customs_inspection','damage_report','proof_of_delivery') NOT NULL,
    scanned_by_user_id VARCHAR(30)  NOT NULL,
    facility_id        VARCHAR(30)  NULL,
    occurred_at        DATETIME(6)  NOT NULL,
    recorded_at        DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    device_serial      VARCHAR(64)  NULL,
    notes              TEXT         NULL,
    PRIMARY KEY (scan_id),

    CONSTRAINT scans_recorded_after_occurred CHECK (recorded_at >= occurred_at),
    CONSTRAINT scans_pod_needs_context
        CHECK (scan_type <> 'proof_of_delivery'
               OR (container_id IS NOT NULL AND facility_id IS NOT NULL)),

    CONSTRAINT scans_shipment_fk FOREIGN KEY (shipment_id)
        REFERENCES freight.shipments (shipment_id),
    CONSTRAINT scans_container_fk FOREIGN KEY (container_id)
        REFERENCES freight.containers (container_id),
    CONSTRAINT scans_facility_fk FOREIGN KEY (facility_id)
        REFERENCES freight.facilities (facility_id),

    KEY scan_events_shipment_idx (shipment_id, occurred_at),
    KEY scan_events_pod_idx (scan_type, shipment_id, occurred_at),
    KEY scan_events_container_idx (container_id, occurred_at)
) ENGINE = InnoDB;

-- स्थिति वाली सहायक table — सिर्फ़ उन scans के लिए जिनमें GPS मिला। एक-से-शून्य
-- या एक संबंध, इसलिए PK वही scan_id है।
CREATE TABLE freight.shipment_scan_positions (
    scan_id  VARCHAR(30) NOT NULL,
    position POINT SRID 4326 NOT NULL,
    accuracy_m SMALLINT UNSIGNED NULL,
    PRIMARY KEY (scan_id),
    SPATIAL KEY scan_position_gix (position),
    CONSTRAINT scan_position_fk FOREIGN KEY (scan_id)
        REFERENCES freight.shipment_scan_events (scan_id) ON DELETE CASCADE
) ENGINE = InnoDB
  COMMENT = 'geo.v1.GeoService/SnapToRoad इन्हीं बिंदुओं को साफ़ करती है';

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0004_freight', UNHEX(SHA2('0004', 256)));
