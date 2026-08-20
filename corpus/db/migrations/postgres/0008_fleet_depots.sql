-- ---------------------------------------------------------------------------
-- 0008_fleet_depots.sql
--
-- fleet.depots — वे भौतिक ठिकाने जहाँ edge gateway agent चलता है और जहाँ से
-- telemetry.device_gateways अपनी batches भेजते हैं। हर depot का एक geofence है,
-- जिसे geo.v1.GeoService/ResolveGeofence हल करता है।
--
-- SPEC.md §2.2।
-- ---------------------------------------------------------------------------

BEGIN;

-- geofence_id logical FK है, असली नहीं: geo schema geo-service की है और SPEC.md
-- §2 की अनुमत cross-schema FK सूची में fleet.depots नहीं है। पंक्ति बनाने से
-- पहले fleet-service geo.v1.GeoService/ResolveGeofence से पुष्टि करती है।
--
-- timezone IANA नाम है, offset नहीं — depot के खुलने के घंटे DST के साथ खिसकते
-- हैं और '+01:00' रखने पर हर मार्च में गलत हो जाते थे।
CREATE TABLE fleet.depots (
    depot_id    TEXT        PRIMARY KEY,
    tenant_id   TEXT        NOT NULL,
    name        TEXT        NOT NULL,
    geofence_id TEXT        NOT NULL,
    unlocode    CHAR(5),
    timezone    TEXT        NOT NULL,
    region_code TEXT        NOT NULL,
    opened_on   DATE        NOT NULL,
    closed_on   DATE,

    CONSTRAINT depots_id_is_prefixed_ulid
        CHECK (depot_id ~ '^dep_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT depots_geofence_is_prefixed
        CHECK (geofence_id ~ '^gfn_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- UN/LOCODE पाँच अक्षर: दो देश + तीन स्थान, हमेशा uppercase (SPEC.md §0.2)।
    CONSTRAINT depots_unlocode_shape
        CHECK (unlocode IS NULL OR unlocode ~ '^[A-Z]{2}[A-Z2-9]{3}$'),

    CONSTRAINT depots_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),

    CONSTRAINT depots_closed_after_opened
        CHECK (closed_on IS NULL OR closed_on >= opened_on)
);

COMMENT ON COLUMN fleet.depots.timezone IS
    'IANA नाम, जैसे Europe/Hamburg; notification-service के quiet hours इसी से हल होते हैं';

-- gateway.heartbeat.missed का consumer depot से region निकालकर सही on-call को
-- जगाता है, इसलिए यह जोड़ी एक साथ index होती है।
CREATE INDEX depots_region_idx
    ON fleet.depots (region_code, tenant_id)
    WHERE closed_on IS NULL;

CREATE UNIQUE INDEX depots_geofence_unique_idx
    ON fleet.depots (geofence_id)
    WHERE closed_on IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0008_fleet_depots', sha256('0008'::bytea));

COMMIT;
