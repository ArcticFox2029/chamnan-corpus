-- ---------------------------------------------------------------------------
-- 0027_analytics_mv_lane_performance_daily.sql
--
-- analytics.mv_lane_performance_daily — दो materialised views में से पहली और
-- इकलौती जिसे दो अलग उपभोक्ता पढ़ते हैं: console का lane dashboard और
-- routing-service का ETA prior। दूसरी वजह से ही avg_transit_seconds जमा किया
-- जाता है, हर बार गिना नहीं जाता।
--
-- SPEC.md §2.9, §3.13। ताज़गी: OF_ANALYTICS_MV_REFRESH_CRON = '15 3 * * *'.
-- ---------------------------------------------------------------------------

BEGIN;

-- यह view पाँच schemas को जोड़ती है और यही अकेला कारण है कि database physically
-- साझा है (SPEC.md §2)। किसी सेवा को ऐसा join लिखने की अनुमति नहीं — सिर्फ़
-- analytics-pipeline का of_analytics_ro role यहाँ तक पहुँचता है।
--
-- दोनों LATERAL सबक्वेरी जानबूझकर LEFT हैं: बिना route वाली या बिना alert वाली
-- shipment भी lane में गिननी चाहिए, वरना on_time_count का हर हिसाब उन्हीं lanes
-- को इनाम देता जिनमें गड़बड़ हुई।
CREATE MATERIALIZED VIEW analytics.mv_lane_performance_daily AS
SELECT
    s.tenant_id,
    date_trunc('day', s.created_at)::date          AS business_date,
    o.unlocode                                     AS origin_unlocode,
    d.unlocode                                     AS destination_unlocode,
    l.mode                                         AS primary_mode,
    count(*)                                       AS shipment_count,
    count(*) FILTER (WHERE s.delivered_at <= s.sla_deadline_at) AS on_time_count,
    avg(extract(epoch FROM (s.delivered_at - s.created_at)))::bigint AS avg_transit_seconds,
    percentile_disc(0.95) WITHIN GROUP (
        ORDER BY extract(epoch FROM (s.delivered_at - s.created_at))
    )::bigint                                      AS p95_transit_seconds,
    sum(a.alert_count)                             AS excursion_alerts
FROM freight.shipments s
JOIN freight.facilities o ON o.facility_id = s.origin_facility_id
JOIN freight.facilities d ON d.facility_id = s.destination_facility_id
-- 'primary mode' = सबसे लंबी leg का साधन। यही वह अनुमान है जिस पर पूरी lane की
-- पहचान टिकी है; तीन leg वाले सफ़र में पहली leg अक्सर 20 km की drayage होती है
-- और उसे primary मानना हर समुद्री lane को 'road' बता देता था।
LEFT JOIN LATERAL (
    SELECT rl.mode
    FROM routing.routes r
    JOIN routing.route_legs rl ON rl.route_id = r.route_id
    WHERE r.shipment_id = s.shipment_id AND r.is_current
    ORDER BY rl.distance_m DESC
    LIMIT 1
) l ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS alert_count
    FROM telemetry.telemetry_alerts ta
    WHERE ta.shipment_id = s.shipment_id
) a ON true
WHERE s.status = 'delivered'
GROUP BY 1, 2, 3, 4, 5;

COMMENT ON MATERIALIZED VIEW analytics.mv_lane_performance_daily IS
    'GET /v1/metrics/lane-performance इसे सीधे परोसती है; routing-service का OF_ROUTING_ETA_MODEL_PATH इसी से बनता है';

-- यह unique index सिर्फ़ इसलिए है कि REFRESH MATERIALIZED VIEW CONCURRENTLY बिना
-- उसके चलता ही नहीं। 03:15 UTC पर पूरी view को लॉक कर देना console को पंद्रह
-- मिनट के लिए खाली कर देता था।
CREATE UNIQUE INDEX mv_lane_performance_daily_key
    ON analytics.mv_lane_performance_daily
       (tenant_id, business_date, origin_unlocode, destination_unlocode, primary_mode);

-- Dashboard हमेशा एक tenant की पिछली कुछ तारीख़ें माँगता है।
CREATE INDEX mv_lane_performance_recent_idx
    ON analytics.mv_lane_performance_daily (tenant_id, business_date DESC);

-- routing-service का ETA prior lane से पूछता है, tenant से नहीं — वह प्रश्न
-- tenant-निरपेक्ष है क्योंकि सड़क सबके लिए एक जैसी है।
CREATE INDEX mv_lane_performance_lane_idx
    ON analytics.mv_lane_performance_daily
       (origin_unlocode, destination_unlocode, primary_mode, business_date DESC);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0027_analytics_mv_lane_performance_daily', sha256('0027'::bytea));

COMMIT;
