-- ---------------------------------------------------------------------------
-- 0005_routing_and_geo.sql
--
-- routing-service और geo-service की tables। geo.geofences का POLYGON MySQL में
-- SRID 4326 पर बँधा है, पर PostGIS के geography जैसा नहीं है — दूरी की गणना
-- ST_Distance_Sphere से होती है, और buffer_m का प्रयोग ST_DWithin के बजाय
-- स्पष्ट दूरी-तुलना से। यह geo-service के C++ कोड में दिखता है, यहाँ नहीं।
--
-- SPEC.md §2.4।
-- ---------------------------------------------------------------------------

CREATE TABLE geo.geofences (
    geofence_id         VARCHAR(30)  NOT NULL,
    tenant_id           VARCHAR(30)  NULL,   -- NULL = साझा fence (बंदरगाह, सीमा)
    name                VARCHAR(255) NOT NULL,
    kind                ENUM('facility','depot','border_zone','restricted','customer_site','corridor')
                                     NOT NULL,
    -- SPATIAL KEY की शर्त: NOT NULL। यहाँ वह स्वाभाविक है — बिना बहुभुज के
    -- geofence का कोई अर्थ नहीं।
    boundary            POLYGON SRID 4326 NOT NULL,
    buffer_m            INT          NOT NULL DEFAULT 50,
    dwell_alert_minutes INT          NULL,
    created_at          DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    retired_at          DATETIME(6)  NULL,
    PRIMARY KEY (geofence_id),
    SPATIAL KEY geofences_boundary_gix (boundary),

    CONSTRAINT geofences_buffer_is_sane CHECK (buffer_m BETWEEN 0 AND 5000),
    CONSTRAINT geofences_dwell_is_positive
        CHECK (dwell_alert_minutes IS NULL OR dwell_alert_minutes > 0),
    CONSTRAINT geofences_restricted_is_global
        CHECK (kind <> 'restricted' OR tenant_id IS NULL),

    KEY geofences_tenant_kind_idx (tenant_id, kind, retired_at)
) ENGINE = InnoDB
  COMMENT = 'geo.v1.GeoService/ResolveGeofence परिणाम trace-दर-trace 30 सेकंड cache करती है';

-- modes_allowed TEXT[] नहीं, JSON। सदस्यता की खोज के लिए एक multi-valued index
-- चाहिए — MySQL 8.0.17+ में `CAST(... AS CHAR(8) ARRAY)` वाला index वही काम
-- करता है जो PostgreSQL का GIN करता था।
CREATE TABLE geo.border_crossings (
    crossing_id         VARCHAR(30) NOT NULL,
    from_country        CHAR(2)     NOT NULL,
    to_country          CHAR(2)     NOT NULL,
    unlocode            CHAR(5)     NOT NULL,
    customs_office_code VARCHAR(32) NOT NULL,
    geofence_id         VARCHAR(30) NOT NULL,
    modes_allowed       JSON        NOT NULL,
    avg_dwell_minutes   INT         NOT NULL,   -- analytics-pipeline रोज़ रात ताज़ा करती है
    open_24h            TINYINT(1)  NOT NULL DEFAULT 1,
    PRIMARY KEY (crossing_id),
    UNIQUE KEY crossings_pair (from_country, to_country, unlocode),

    CONSTRAINT crossing_countries_differ CHECK (from_country <> to_country),
    CONSTRAINT crossings_dwell_is_positive CHECK (avg_dwell_minutes >= 0),
    CONSTRAINT crossings_modes_is_array
        CHECK (JSON_TYPE(modes_allowed) = 'ARRAY' AND JSON_LENGTH(modes_allowed) > 0),
    CONSTRAINT crossings_geofence_fk FOREIGN KEY (geofence_id)
        REFERENCES geo.geofences (geofence_id),

    KEY crossings_dwell_idx (from_country, to_country, avg_dwell_minutes),
    KEY crossings_office_idx (customs_office_code),
    KEY crossings_modes_mv ((CAST(modes_allowed AS CHAR(8) ARRAY)))
) ENGINE = InnoDB;

-- routing.routes का `CREATE UNIQUE INDEX … WHERE is_current` फिर वही चाल माँगता
-- है: current_marker सिर्फ़ चालू route पर shipment_id रखती है।
CREATE TABLE routing.routes (
    route_id         VARCHAR(30) NOT NULL,
    shipment_id      VARCHAR(30) NOT NULL,   -- logical FK → freight.shipments
    version          INT         NOT NULL,
    is_current       TINYINT(1)  NOT NULL DEFAULT 1,
    planned_by       VARCHAR(64) NOT NULL,
    strategy         ENUM('cheapest','fastest','lowest_carbon','customs_optimised','manual') NOT NULL,
    total_distance_m BIGINT      NOT NULL,
    total_duration_s INT         NOT NULL,
    computed_at      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    superseded_at    DATETIME(6) NULL,

    current_marker VARCHAR(30) GENERATED ALWAYS AS (
        CASE WHEN is_current = 1 THEN shipment_id END
    ) STORED,

    PRIMARY KEY (route_id),
    UNIQUE KEY routes_shipment_version (shipment_id, version),
    UNIQUE KEY routes_one_current_per_shipment (current_marker),

    CONSTRAINT routes_version_starts_at_one CHECK (version >= 1),
    CONSTRAINT routes_totals_are_positive
        CHECK (total_distance_m >= 0 AND total_duration_s >= 0),
    CONSTRAINT routes_current_is_not_superseded
        CHECK (is_current = 0 OR superseded_at IS NULL),

    KEY routes_history_idx (shipment_id, version)
) ENGINE = InnoDB
  COMMENT = 'replan इतिहास मिटाता नहीं; route.replanned में previous_version भी जाता है';

CREATE TABLE routing.route_legs (
    leg_id            VARCHAR(30) NOT NULL,
    route_id          VARCHAR(30) NOT NULL,
    seq_no            SMALLINT    NOT NULL,
    mode              ENUM('road','rail','sea','air','barge') NOT NULL,
    from_facility_id  VARCHAR(30) NOT NULL,
    to_facility_id    VARCHAR(30) NOT NULL,
    crossing_id       VARCHAR(30) NULL,
    planned_depart_at DATETIME(6) NOT NULL,
    planned_arrive_at DATETIME(6) NOT NULL,
    actual_depart_at  DATETIME(6) NULL,
    actual_arrive_at  DATETIME(6) NULL,
    distance_m        BIGINT      NOT NULL,
    carrier_id        VARCHAR(30) NULL,
    PRIMARY KEY (leg_id),
    UNIQUE KEY route_legs_seq (route_id, seq_no),

    CONSTRAINT legs_arrive_after_depart CHECK (planned_arrive_at > planned_depart_at),
    CONSTRAINT legs_actual_arrive_after_depart
        CHECK (actual_arrive_at IS NULL OR actual_depart_at IS NULL
               OR actual_arrive_at >= actual_depart_at),
    CONSTRAINT legs_seq_starts_at_one CHECK (seq_no >= 1),
    CONSTRAINT legs_distance_not_negative CHECK (distance_m >= 0),
    CONSTRAINT legs_endpoints_differ CHECK (from_facility_id <> to_facility_id),
    CONSTRAINT legs_crossing_only_for_surface_modes
        CHECK (crossing_id IS NULL OR mode IN ('road','rail','barge')),

    CONSTRAINT legs_route_fk FOREIGN KEY (route_id)
        REFERENCES routing.routes (route_id) ON DELETE CASCADE,
    -- SPEC.md §2 की अनुमत cross-schema FK; ऊपर containers → carriers वाली टिप्पणी
    -- यहाँ भी लागू है।
    CONSTRAINT legs_crossing_fk FOREIGN KEY (crossing_id)
        REFERENCES geo.border_crossings (crossing_id),

    KEY route_legs_open_idx (route_id, actual_arrive_at),
    KEY route_legs_carrier_idx (carrier_id)
) ENGINE = InnoDB;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0005_routing_and_geo', UNHEX(SHA2('0005', 256)));
