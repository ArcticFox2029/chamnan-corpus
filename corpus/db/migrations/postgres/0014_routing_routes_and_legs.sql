-- ---------------------------------------------------------------------------
-- 0014_routing_routes_and_legs.sql
--
-- routing-service की दोनों tables। routes संस्करणित हैं — replan पुरानी पंक्ति
-- मिटाता नहीं, नया version डालकर is_current पलटता है — और route_legs में वह
-- इकलौती cross-schema foreign key है जो geo.border_crossings तक जाती है।
--
-- SPEC.md §2.4, §3.5, §4.11।
-- ---------------------------------------------------------------------------

BEGIN;

-- Replan इतिहास मिटाता नहीं। यह क़ानूनी माँग है: विवाद होने पर यह दिखाना पड़ता है
-- कि उस समय की योजना क्या थी, न कि आख़िरी योजना क्या है।
--
-- shipment_id logical FK है — routing schema की मालिक routing-service है और वह
-- freight को SQL से नहीं छूती।
CREATE TABLE routing.routes (
    route_id         TEXT        PRIMARY KEY,
    shipment_id      TEXT        NOT NULL,
    version          INTEGER     NOT NULL,
    is_current       BOOLEAN     NOT NULL DEFAULT true,
    planned_by       TEXT        NOT NULL,
    strategy         TEXT        NOT NULL CHECK (strategy IN
                       ('cheapest','fastest','lowest_carbon','customs_optimised','manual')),
    total_distance_m BIGINT      NOT NULL,
    total_duration_s INTEGER     NOT NULL,
    computed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    superseded_at    TIMESTAMPTZ,
    UNIQUE (shipment_id, version),

    CONSTRAINT routes_id_is_prefixed_ulid
        CHECK (route_id ~ '^rte_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT routes_shipment_is_prefixed
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT routes_version_starts_at_one CHECK (version >= 1),
    CONSTRAINT routes_totals_are_positive
        CHECK (total_distance_m >= 0 AND total_duration_s >= 0),

    -- planned_by या तो कोई इंसान है या स्वयं सेवा; तीसरा रूप कभी नहीं होना चाहिए।
    CONSTRAINT routes_planner_shape
        CHECK (planned_by = 'svc:routing-service'
               OR planned_by ~ '^usr_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- चालू route कभी superseded नहीं हो सकता; यह जोड़ी एक बार असंगत हो गई थी और
    -- fleet-service ने मिटे हुए legs पर assignments छोड़ना बंद कर दिया था।
    CONSTRAINT routes_current_is_not_superseded
        CHECK (NOT is_current OR superseded_at IS NULL)
);

COMMENT ON TABLE routing.routes IS
    'POST /v1/routes/plan संस्करण 1 लिखती है; /replan नया संस्करण डालकर route.replanned भेजती है';

-- एक shipment पर चालू route एक ही। यही वह जाँच है जो replan के दो समानांतर
-- requests में से एक को हरा देती है।
CREATE UNIQUE INDEX routes_one_current_per_shipment
    ON routing.routes (shipment_id)
    WHERE is_current;

-- GET /v1/shipments/{shipment_id}/route सिर्फ़ चालू route माँगती है, पर इतिहास
-- वाली screen पूरा क्रम माँगती है।
CREATE INDEX routes_history_idx
    ON routing.routes (shipment_id, version DESC);

-- Legs। crossing_id असली foreign key है — SPEC.md §2 की उन चार अनुमत cross-schema
-- FKs में से एक, क्योंकि geo.border_crossings धीरे बदलने वाला reference data है
-- जिसकी पंक्तियाँ कभी मिटती नहीं।
CREATE TABLE routing.route_legs (
    leg_id            TEXT        PRIMARY KEY,
    route_id          TEXT        NOT NULL REFERENCES routing.routes(route_id) ON DELETE CASCADE,
    seq_no            SMALLINT    NOT NULL,
    mode              TEXT        NOT NULL CHECK (mode IN ('road','rail','sea','air','barge')),
    from_facility_id  TEXT        NOT NULL,
    to_facility_id    TEXT        NOT NULL,
    crossing_id       TEXT        REFERENCES geo.border_crossings(crossing_id),
    planned_depart_at TIMESTAMPTZ NOT NULL,
    planned_arrive_at TIMESTAMPTZ NOT NULL,
    actual_depart_at  TIMESTAMPTZ,
    actual_arrive_at  TIMESTAMPTZ,
    distance_m        BIGINT      NOT NULL,
    carrier_id        TEXT,
    UNIQUE (route_id, seq_no),

    CONSTRAINT legs_id_is_prefixed_ulid
        CHECK (leg_id ~ '^leg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT legs_arrive_after_depart CHECK (planned_arrive_at > planned_depart_at),
    CONSTRAINT legs_actual_arrive_after_depart
        CHECK (actual_arrive_at IS NULL OR actual_depart_at IS NULL
               OR actual_arrive_at >= actual_depart_at),
    CONSTRAINT legs_seq_starts_at_one CHECK (seq_no >= 1),
    CONSTRAINT legs_distance_not_negative CHECK (distance_m >= 0),
    CONSTRAINT legs_endpoints_differ CHECK (from_facility_id <> to_facility_id),

    -- हवाई और समुद्री legs सीमा-चौकी से नहीं गुज़रतीं; वहाँ crossing_id भरा होना
    -- planner की गलती है और declaration गलत office पर दायर हो जाती।
    CONSTRAINT legs_crossing_only_for_surface_modes
        CHECK (crossing_id IS NULL OR mode IN ('road','rail','barge'))
);

COMMENT ON COLUMN routing.route_legs.crossing_id IS
    'असली cross-schema FK → geo.border_crossings; customs-service इसी से customs_office_code उठाती है';

-- fleet.v1.FleetService/Assign एक leg पर vehicle माँगती है, इसलिए leg से route
-- तक का रास्ता सस्ता होना चाहिए।
CREATE INDEX route_legs_route_seq_idx ON routing.route_legs (route_id, seq_no);

-- OF_ROUTING_MAX_LEGS वाली सीमा के बावजूद 'अभी चल रही legs' का सवाल हर ETA batch
-- में आता है।
CREATE INDEX route_legs_open_idx
    ON routing.route_legs (route_id)
    WHERE actual_arrive_at IS NULL;

CREATE INDEX route_legs_crossing_idx
    ON routing.route_legs (crossing_id)
    WHERE crossing_id IS NOT NULL;

CREATE INDEX route_legs_carrier_idx
    ON routing.route_legs (carrier_id)
    WHERE carrier_id IS NOT NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0014_routing_routes_and_legs', sha256('0014'::bytea));

COMMIT;
