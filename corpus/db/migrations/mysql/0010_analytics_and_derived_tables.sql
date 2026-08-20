-- ---------------------------------------------------------------------------
-- 0010_analytics_and_derived_tables.sql
--
-- analytics schema। यहाँ सबसे बड़ा बोली-भेद है: MySQL में materialised view है ही
-- नहीं। SPEC.md §2.9 की दोनों views यहाँ असली tables हैं, और उन्हें भरने वाली
-- procedures REFRESH ... CONCURRENTLY की जगह लेती हैं — छाया-table में भरकर
-- RENAME से अदला-बदली, ताकि पढ़ने वाले को कभी आधी भरी table न दिखे।
--
-- SPEC.md §2.9, §3.13।
-- ---------------------------------------------------------------------------

CREATE TABLE analytics.reconciliation_runs (
    run_id               VARCHAR(30) NOT NULL,
    tenant_id            VARCHAR(30) NOT NULL,
    business_date        DATE        NOT NULL,
    started_at           DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    finished_at          DATETIME(6) NULL,
    state                ENUM('running','succeeded','failed','partial') NOT NULL DEFAULT 'running',
    shipments_examined   INT         NOT NULL DEFAULT 0,
    discrepancies_opened INT         NOT NULL DEFAULT 0,
    engine_version       VARCHAR(32) NOT NULL,   -- OF_RECON_ENGINE_VERSION से
    PRIMARY KEY (run_id),
    UNIQUE KEY runs_tenant_date_engine (tenant_id, business_date, engine_version),

    CONSTRAINT runs_counters_not_negative
        CHECK (shipments_examined >= 0 AND discrepancies_opened >= 0),
    CONSTRAINT runs_finished_when_done CHECK ((state = 'running') = (finished_at IS NULL)),
    CONSTRAINT runs_finish_after_start
        CHECK (finished_at IS NULL OR finished_at >= started_at),

    KEY runs_in_flight_idx (state, started_at)
) ENGINE = InnoDB;

CREATE TABLE analytics.reconciliation_discrepancies (
    discrepancy_id  VARCHAR(30)  NOT NULL,
    run_id          VARCHAR(30)  NOT NULL,
    tenant_id       VARCHAR(30)  NOT NULL,
    shipment_id     VARCHAR(30)  NOT NULL,
    declaration_id  VARCHAR(30)  NULL,
    invoice_id      VARCHAR(30)  NULL,
    kind            ENUM('missing_declaration','missing_invoice','duty_mismatch',
                         'weight_mismatch','orphan_payment','unbilled_accessorial',
                         'cleared_without_payment') NOT NULL,
    expected_minor  BIGINT       NULL,
    observed_minor  BIGINT       NULL,
    currency        CHAR(3)      NULL,
    state           ENUM('open','acknowledged','resolved','waived') NOT NULL DEFAULT 'open',
    opened_at       DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    resolved_at     DATETIME(6)  NULL,
    resolved_by     VARCHAR(30)  NULL,
    resolution_note VARCHAR(1024) NULL,
    PRIMARY KEY (discrepancy_id),

    CONSTRAINT discrepancies_amounts_have_currency
        CHECK ((expected_minor IS NULL AND observed_minor IS NULL) OR currency IS NOT NULL),
    CONSTRAINT discrepancies_missing_kinds_are_consistent
        CHECK ((kind <> 'missing_declaration' OR declaration_id IS NULL)
           AND (kind <> 'missing_invoice'     OR invoice_id IS NULL)),
    CONSTRAINT discrepancies_resolution_is_complete
        CHECK ((state IN ('resolved','waived'))
               = (resolved_at IS NOT NULL AND resolved_by IS NOT NULL)),
    CONSTRAINT discrepancies_run_fk FOREIGN KEY (run_id)
        REFERENCES analytics.reconciliation_runs (run_id),

    KEY discrepancies_open_idx (tenant_id, kind, state),
    KEY discrepancies_invoice_idx (invoice_id, state),
    KEY discrepancies_shipment_idx (shipment_id, opened_at)
) ENGINE = InnoDB
  COMMENT = 'खुलते ही reconciliation.discrepancy.opened जाता है; billing invoice on_hold करती है';

-- materialised view की जगह असली table। नाम वही रखा गया है (mv_ उपसर्ग समेत)
-- ताकि analytics-pipeline का Scala कोड और contracts/ के OpenAPI दस्तावेज़ दोनों
-- बिना बदले चलें — पहचान बोली से नहीं बदलनी चाहिए।
CREATE TABLE analytics.mv_lane_performance_daily (
    tenant_id             VARCHAR(30) NOT NULL,
    business_date         DATE        NOT NULL,
    origin_unlocode       CHAR(5)     NOT NULL,
    destination_unlocode  CHAR(5)     NOT NULL,
    primary_mode          ENUM('road','rail','sea','air','barge') NOT NULL,
    shipment_count        BIGINT      NOT NULL,
    on_time_count         BIGINT      NOT NULL,
    avg_transit_seconds   BIGINT      NULL,
    p95_transit_seconds   BIGINT      NULL,
    excursion_alerts      BIGINT      NULL,
    refreshed_at          DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (tenant_id, business_date, origin_unlocode, destination_unlocode, primary_mode),
    KEY mv_lane_recent_idx (tenant_id, business_date),
    KEY mv_lane_lane_idx (origin_unlocode, destination_unlocode, primary_mode, business_date)
) ENGINE = InnoDB
  COMMENT = 'GET /v1/metrics/lane-performance; routing-service का ETA prior भी यही पढ़ता है';

CREATE TABLE analytics.mv_container_utilisation_weekly (
    container_id   VARCHAR(30) NOT NULL,
    iso_size_type  CHAR(4)     NOT NULL,
    week_start     DATE        NOT NULL,
    trips          BIGINT      NOT NULL,
    total_gross_kg BIGINT      NOT NULL,
    max_gross_kg   INT         NOT NULL,
    fill_rate_pct  DECIMAL(6,2) NULL,
    refreshed_at   DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (container_id, week_start),
    KEY mv_container_idle_idx (week_start, iso_size_type, fill_rate_pct)
) ENGINE = InnoDB;

DELIMITER $$

-- REFRESH MATERIALIZED VIEW CONCURRENTLY का विकल्प: छाया-table भरो, फिर एक
-- atomic RENAME से अदला-बदली। MySQL का RENAME TABLE कई tables को एक ही statement
-- में बदलता है और उस दौरान कोई पाठक आधी भरी table नहीं देखता — यही CONCURRENTLY
-- का असली वादा था।
CREATE PROCEDURE analytics.refresh_lane_performance()
BEGIN
    DROP TABLE IF EXISTS analytics.mv_lane_performance_daily__new;
    CREATE TABLE analytics.mv_lane_performance_daily__new
        LIKE analytics.mv_lane_performance_daily;

    INSERT INTO analytics.mv_lane_performance_daily__new
        (tenant_id, business_date, origin_unlocode, destination_unlocode, primary_mode,
         shipment_count, on_time_count, avg_transit_seconds, p95_transit_seconds, excursion_alerts)
    SELECT
        s.tenant_id,
        DATE(s.created_at)                                   AS business_date,
        o.unlocode                                           AS origin_unlocode,
        d.unlocode                                           AS destination_unlocode,
        l.mode                                               AS primary_mode,
        COUNT(*)                                             AS shipment_count,
        SUM(s.delivered_at <= s.sla_deadline_at)             AS on_time_count,
        CAST(AVG(TIMESTAMPDIFF(SECOND, s.created_at, s.delivered_at)) AS SIGNED)
                                                             AS avg_transit_seconds,
        -- MySQL में percentile_disc नहीं है। p95 यहाँ window function से निकाला
        -- जाता है, इसलिए यह अलग सबक्वेरी में है और नीचे JOIN से जुड़ता है।
        p.p95_transit_seconds,
        a.alert_count
    FROM freight.shipments s
    JOIN freight.facilities o ON o.facility_id = s.origin_facility_id
    JOIN freight.facilities d ON d.facility_id = s.destination_facility_id
    -- 'primary mode' = सबसे लंबी leg का साधन; पहली leg अक्सर 20 km की drayage
    -- होती है और उसे primary मानने पर हर समुद्री lane 'road' बन जाती थी।
    LEFT JOIN LATERAL (
        SELECT rl.mode
          FROM routing.routes r
          JOIN routing.route_legs rl ON rl.route_id = r.route_id
         WHERE r.shipment_id = s.shipment_id AND r.is_current = 1
         ORDER BY rl.distance_m DESC LIMIT 1
    ) l ON TRUE
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS alert_count
          FROM telemetry.telemetry_alerts ta
         WHERE ta.shipment_id = s.shipment_id
    ) a ON TRUE
    LEFT JOIN (
        SELECT tenant_id, business_date, origin_unlocode, destination_unlocode,
               MAX(transit_seconds) AS p95_transit_seconds
          FROM (
                SELECT s2.tenant_id,
                       DATE(s2.created_at) AS business_date,
                       o2.unlocode AS origin_unlocode,
                       d2.unlocode AS destination_unlocode,
                       TIMESTAMPDIFF(SECOND, s2.created_at, s2.delivered_at) AS transit_seconds,
                       PERCENT_RANK() OVER (
                           PARTITION BY s2.tenant_id, DATE(s2.created_at),
                                        o2.unlocode, d2.unlocode
                           ORDER BY TIMESTAMPDIFF(SECOND, s2.created_at, s2.delivered_at)
                       ) AS pr
                  FROM freight.shipments s2
                  JOIN freight.facilities o2 ON o2.facility_id = s2.origin_facility_id
                  JOIN freight.facilities d2 ON d2.facility_id = s2.destination_facility_id
                 WHERE s2.status = 'delivered'
               ) ranked
         WHERE pr <= 0.95
         GROUP BY 1, 2, 3, 4
    ) p ON p.tenant_id = s.tenant_id
       AND p.business_date = DATE(s.created_at)
       AND p.origin_unlocode = o.unlocode
       AND p.destination_unlocode = d.unlocode
    WHERE s.status = 'delivered'
    GROUP BY 1, 2, 3, 4, 5, p.p95_transit_seconds, a.alert_count;

    RENAME TABLE
        analytics.mv_lane_performance_daily      TO analytics.mv_lane_performance_daily__old,
        analytics.mv_lane_performance_daily__new TO analytics.mv_lane_performance_daily;

    DROP TABLE analytics.mv_lane_performance_daily__old;
END$$

CREATE PROCEDURE analytics.refresh_container_utilisation()
BEGIN
    DROP TABLE IF EXISTS analytics.mv_container_utilisation_weekly__new;
    CREATE TABLE analytics.mv_container_utilisation_weekly__new
        LIKE analytics.mv_container_utilisation_weekly;

    INSERT INTO analytics.mv_container_utilisation_weekly__new
        (container_id, iso_size_type, week_start, trips, total_gross_kg, max_gross_kg, fill_rate_pct)
    SELECT
        c.container_id,
        c.iso_size_type,
        DATE(DATE_SUB(sc.loaded_at, INTERVAL WEEKDAY(sc.loaded_at) DAY)) AS week_start,
        COUNT(DISTINCT sc.shipment_id) AS trips,
        SUM(sc.gross_kg)               AS total_gross_kg,
        MAX(c.max_gross_kg)            AS max_gross_kg,
        -- NULLIF ज़रूरी है: सेवामुक्ति से ठीक पहले वाले सप्ताह में कोई trip नहीं
        -- होती और भाजक शून्य हो जाता है।
        ROUND(100.0 * SUM(sc.gross_kg) /
              NULLIF(COUNT(DISTINCT sc.shipment_id) * MAX(c.max_gross_kg), 0), 2) AS fill_rate_pct
    FROM freight.containers c
    JOIN freight.shipment_containers sc ON sc.container_id = c.container_id
    WHERE sc.loaded_at IS NOT NULL AND c.retired_at IS NULL
    GROUP BY 1, 2, 3;

    RENAME TABLE
        analytics.mv_container_utilisation_weekly      TO analytics.mv_container_utilisation_weekly__old,
        analytics.mv_container_utilisation_weekly__new TO analytics.mv_container_utilisation_weekly;

    DROP TABLE analytics.mv_container_utilisation_weekly__old;
END$$

-- geo.border_crossings.avg_dwell_minutes को यहीं ताज़ा करते हैं: routing-service
-- को analytics schema पढ़ने की अनुमति नहीं है, इसलिए संख्या उसकी अपनी schema में
-- धकेली जाती है।
CREATE PROCEDURE analytics.refresh_crossing_dwell()
BEGIN
    UPDATE geo.border_crossings bc
      JOIN (
            SELECT rl.crossing_id,
                   AVG(TIMESTAMPDIFF(SECOND, rl.actual_arrive_at, rl.actual_depart_at)) / 60.0
                     AS dwell_minutes
              FROM routing.route_legs rl
             WHERE rl.crossing_id IS NOT NULL
               AND rl.actual_arrive_at IS NOT NULL
               AND rl.actual_depart_at IS NOT NULL
               AND rl.actual_arrive_at > DATE_SUB(UTC_TIMESTAMP(6), INTERVAL 28 DAY)
             GROUP BY rl.crossing_id
            HAVING COUNT(*) >= 20   -- कम नमूनों पर औसत शोर है, संकेत नहीं
           ) observed ON observed.crossing_id = bc.crossing_id
       SET bc.avg_dwell_minutes = GREATEST(0, ROUND(observed.dwell_minutes));
END$$

DELIMITER ;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0010_analytics_and_derived_tables', UNHEX(SHA2('0010', 256)));
