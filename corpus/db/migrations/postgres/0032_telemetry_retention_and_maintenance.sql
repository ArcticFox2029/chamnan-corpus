-- ---------------------------------------------------------------------------
-- 0032_telemetry_retention_and_maintenance.sql
--
-- रख-रखाव: telemetry की region partitions पर अलग-अलग retention (क़ानून हर region
-- में एक जैसा नहीं है), materialised views को CONCURRENTLY ताज़ा करने वाली
-- procedure, और outbox की सफ़ाई। ये सब ops/ के cron से बुलाए जाते हैं, अपने आप
-- नहीं चलते।
-- ---------------------------------------------------------------------------

BEGIN;

-- Retention नीति per-region है क्योंकि क़ानून per-region है: EU में सेंसर डेटा
-- 24 महीने, ब्राज़ील में 60, सिंगापुर में 12। एक वैश्विक संख्या रखना या तो क़ानून
-- तोड़ती या storage का बिल तिगुना करती।
CREATE TABLE telemetry.retention_policy (
    region_code       TEXT    PRIMARY KEY,
    readings_days     INTEGER NOT NULL,
    alerts_days       INTEGER NOT NULL,
    legal_basis       TEXT    NOT NULL,
    reviewed_on       DATE    NOT NULL,

    CONSTRAINT retention_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),
    CONSTRAINT retention_days_are_positive
        CHECK (readings_days > 0 AND alerts_days >= readings_days)
);

INSERT INTO telemetry.retention_policy VALUES
  ('eu-west',    730,  1825, 'GDPR Art. 5(1)(e) + carrier contract',        '2026-01-15'),
  ('eu-central', 730,  1825, 'GDPR Art. 5(1)(e) + carrier contract',        '2026-01-15'),
  ('na-east',    1095, 2555, 'FMCSA record-keeping',                        '2026-02-02'),
  ('na-west',    1095, 2555, 'FMCSA record-keeping',                        '2026-02-02'),
  ('apac-sg',    365,  1095, 'PDPA + customs advance ruling window',        '2025-11-30'),
  ('apac-jp',    365,  1095, 'APPI',                                        '2025-11-30'),
  ('latam-br',   1825, 1825, 'LGPD + ANTT cold-chain evidence requirement',  '2026-03-11'),
  ('mea-ae',     730,  1825, 'UAE Federal Decree-Law 45 of 2021',           '2026-01-20');

-- हर partition पर अलग DELETE चलती है ताकि एक region की सफ़ाई दूसरे की ingest को
-- न रोके। पूरी parent table पर एक DELETE चलाने की कोशिश ने आठों partitions पर
-- एक साथ lock लिया था और latam-br की ingest नौ मिनट रुकी थी।
CREATE OR REPLACE PROCEDURE telemetry.prune_readings(p_region TEXT, p_batch_size INTEGER DEFAULT 50000)
LANGUAGE plpgsql
AS $$
DECLARE
    keep_days  INTEGER;
    partition  TEXT;
    removed    INTEGER;
BEGIN
    SELECT readings_days INTO keep_days
      FROM telemetry.retention_policy WHERE region_code = p_region;

    IF keep_days IS NULL THEN
        RAISE EXCEPTION 'region % के लिए कोई retention नीति नहीं है', p_region;
    END IF;

    partition := 'telemetry.telemetry_readings_' || replace(p_region, '-', '_');

    LOOP
        EXECUTE format(
            'DELETE FROM %s WHERE ctid IN (
                 SELECT ctid FROM %s WHERE recorded_at < now() - $1 * INTERVAL ''1 day'' LIMIT $2
             )', partition, partition)
        USING keep_days, p_batch_size;

        GET DIAGNOSTICS removed = ROW_COUNT;
        EXIT WHEN removed = 0;

        -- हर batch के बाद commit: लंबी transaction autovacuum को रोक देती है और
        -- यही table उसकी सबसे ज़्यादा ज़रूरतमंद है।
        COMMIT;
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE telemetry.prune_readings IS
    'ops/ का nightly cron हर region के लिए एक बार बुलाता है; batch-दर-batch commit करती है';

-- दोनों materialised views एक ही procedure से ताज़ा होती हैं ताकि क्रम तय रहे:
-- lane performance पहले, क्योंकि routing-service का ETA model उसी पर टिका है और
-- 03:15 की खिड़की छोटी है।
CREATE OR REPLACE PROCEDURE analytics.refresh_materialised_views()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_lane_performance_daily;
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_container_utilisation_weekly;

    -- geo.border_crossings.avg_dwell_minutes को यहीं ताज़ा करते हैं: routing-service
    -- को analytics schema पढ़ने की अनुमति नहीं है, इसलिए संख्या उसकी अपनी schema
    -- में धकेली जाती है।
    UPDATE geo.border_crossings bc
       SET avg_dwell_minutes = GREATEST(0, ROUND(observed.dwell_minutes))
      FROM (
            SELECT rl.crossing_id,
                   avg(extract(epoch FROM (rl.actual_depart_at - rl.actual_arrive_at)) / 60.0)
                     AS dwell_minutes
              FROM routing.route_legs rl
             WHERE rl.crossing_id IS NOT NULL
               AND rl.actual_arrive_at IS NOT NULL
               AND rl.actual_depart_at IS NOT NULL
               AND rl.actual_arrive_at > now() - INTERVAL '28 days'
             GROUP BY rl.crossing_id
             HAVING count(*) >= 20          -- कम नमूनों पर औसत शोर है, संकेत नहीं
           ) observed
     WHERE observed.crossing_id = bc.crossing_id;
END;
$$;

-- Outbox की सफ़ाई: प्रकाशित संदेश 24 घंटे रुकते हैं ताकि किसी consumer की replay
-- की ज़रूरत पूरी हो सके, फिर हट जाते हैं। अप्रकाशित कभी नहीं हटते — वे on-call का
-- काम हैं, cron का नहीं।
CREATE OR REPLACE PROCEDURE platform.prune_outbox(p_retain_hours INTEGER DEFAULT 24)
LANGUAGE plpgsql
AS $$
DECLARE
    removed INTEGER;
BEGIN
    DELETE FROM platform.outbox_messages
     WHERE published_at IS NOT NULL
       AND published_at < now() - p_retain_hours * INTERVAL '1 hour';

    GET DIAGNOSTICS removed = ROW_COUNT;
    RAISE NOTICE 'outbox से % प्रकाशित संदेश हटाए गए', removed;
END;
$$;

-- Session की सफ़ाई। समाप्त हो चुकी sessions 90 दिन रुकती हैं क्योंकि
-- identity.session.opened का audit trail उन्हीं से मिलान करता है।
CREATE OR REPLACE PROCEDURE identity.prune_sessions()
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM identity.sessions
     WHERE expires_at < now() - INTERVAL '90 days';
END;
$$;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0032_telemetry_retention_and_maintenance', sha256('0032'::bytea));

COMMIT;
