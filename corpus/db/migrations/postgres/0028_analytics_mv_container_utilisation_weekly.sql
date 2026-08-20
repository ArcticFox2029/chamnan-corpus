-- ---------------------------------------------------------------------------
-- 0028_analytics_mv_container_utilisation_weekly.sql
--
-- दूसरी materialised view — साप्ताहिक, और console की 'idle box' रिपोर्ट को
-- खिलाती है। सवाल सीधा है: कौन-से डिब्बे किराए पर हैं पर चल नहीं रहे।
--
-- SPEC.md §2.9, §3.13।
-- ---------------------------------------------------------------------------

BEGIN;

-- fill_rate_pct में nullif() ज़रूरी है: retired होने से ठीक पहले वाले सप्ताह में
-- कोई trip नहीं होती और भाजक शून्य हो जाता। पहले वह पूरी refresh को गिरा देता
-- था, और चूँकि refresh रात में चलती है, रिपोर्ट सुबह ख़ाली मिलती थी।
--
-- max(c.max_gross_kg) एक GROUP BY की मजबूरी है, गणित की नहीं — container की
-- क्षमता स्थिर है, पर वह GROUP BY में नहीं है इसलिए aggregate चाहिए।
CREATE MATERIALIZED VIEW analytics.mv_container_utilisation_weekly AS
SELECT
    c.container_id,
    c.iso_size_type,
    date_trunc('week', sc.loaded_at)::date        AS week_start,
    count(DISTINCT sc.shipment_id)                AS trips,
    sum(sc.gross_kg)                              AS total_gross_kg,
    max(c.max_gross_kg)                           AS max_gross_kg,
    round(100.0 * sum(sc.gross_kg) /
          nullif(count(DISTINCT sc.shipment_id) * max(c.max_gross_kg), 0), 2) AS fill_rate_pct
FROM freight.containers c
JOIN freight.shipment_containers sc ON sc.container_id = c.container_id
WHERE sc.loaded_at IS NOT NULL AND c.retired_at IS NULL
GROUP BY 1, 2, 3;

COMMENT ON MATERIALIZED VIEW analytics.mv_container_utilisation_weekly IS
    'GET /v1/metrics/container-utilisation; retired डिब्बे बाहर रहते हैं क्योंकि उनका किराया नहीं चलता';

-- CONCURRENTLY की शर्त, ऊपर वाली view जैसी ही।
CREATE UNIQUE INDEX mv_container_utilisation_weekly_key
    ON analytics.mv_container_utilisation_weekly (container_id, week_start);

-- 'idle box' रिपोर्ट का असली प्रश्न: इस सप्ताह सबसे कम भरे डिब्बे, आकार-प्रकार
-- के हिसाब से — 20ft और 45ft reefer की तुलना करना बेमानी है।
CREATE INDEX mv_container_utilisation_idle_idx
    ON analytics.mv_container_utilisation_weekly (week_start DESC, iso_size_type, fill_rate_pct);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0028_analytics_mv_container_utilisation_weekly', sha256('0028'::bytea));

COMMIT;
