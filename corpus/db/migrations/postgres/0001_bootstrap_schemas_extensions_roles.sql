-- ---------------------------------------------------------------------------
-- 0001_bootstrap_schemas_extensions_roles.sql
--
-- यह migration पूरे ORBITALFREIGHT क्लस्टर की नींव रखती है: SPEC.md §2 की दसों
-- schemas, वे तीन extensions जिनके बिना बाद की एक भी migration नहीं चलेगी, और
-- of_analytics_ro role — analytics-pipeline अकेली सेवा है जिसे हर schema पढ़ने
-- की छूट है, और इसी वजह से database physically एक ही रखा गया है।
--
-- Migration order मायने रखती है: यह फ़ाइल सबसे पहले चलती है और किसी भी table को
-- नहीं छूती।
-- ---------------------------------------------------------------------------

BEGIN;

-- हर schema का एक ही owner service है (SPEC.md §2 की table देखें)। Schema बनाते
-- समय ही comment चिपका देते हैं ताकि किसी नए joiner को psql \dn+ में तुरंत दिख
-- जाए कि यह किसकी ज़मीन है।
CREATE SCHEMA IF NOT EXISTS identity;
COMMENT ON SCHEMA identity  IS 'identity-service; eu-central में ही लिखा जाता है, बाकी regions में replica';

CREATE SCHEMA IF NOT EXISTS fleet;
COMMENT ON SCHEMA fleet     IS 'fleet-service — carriers, vehicles, drivers, assignments';

CREATE SCHEMA IF NOT EXISTS freight;
COMMENT ON SCHEMA freight   IS 'container-registry — containers, shipments, scan trail';

CREATE SCHEMA IF NOT EXISTS routing;
COMMENT ON SCHEMA routing   IS 'routing-service — routes और उनके legs';

CREATE SCHEMA IF NOT EXISTS geo;
COMMENT ON SCHEMA geo       IS 'geo-service; PostGIS 3.4 यहीं install होता है';

CREATE SCHEMA IF NOT EXISTS telemetry;
COMMENT ON SCHEMA telemetry IS 'telemetry-ingest — बाकी सब से तीन order of magnitude ज़्यादा write volume';

CREATE SCHEMA IF NOT EXISTS customs;
COMMENT ON SCHEMA customs   IS 'customs-service — declarations और versioned tariffs';

CREATE SCHEMA IF NOT EXISTS billing;
COMMENT ON SCHEMA billing   IS 'billing-service — invoices, lines, payments';

CREATE SCHEMA IF NOT EXISTS platform;
COMMENT ON SCHEMA platform  IS 'साझा schema — ledger, documents, notifications, outbox; owner per-table तय होता है';

CREATE SCHEMA IF NOT EXISTS analytics;
COMMENT ON SCHEMA analytics IS 'analytics-pipeline — सिर्फ़ derived data; drop करके दोबारा बनाया जा सकता है';

-- Extensions।
--   citext     → identity.users.email केस-insensitive है पर display केस बचाना है।
--   btree_gist → fleet.vehicle_assignments और customs.tariff_schedules के EXCLUDE
--                constraints में TEXT/= को range/&& के साथ एक ही GiST index में
--                मिलाना पड़ता है; इसके बिना वे constraint बनते ही नहीं।
--   postgis    → geo.geofences.boundary, freight.shipment_scan_events.position,
--                telemetry.telemetry_readings.position — तीनों geography(4326)।
CREATE EXTENSION IF NOT EXISTS citext     WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS postgis    WITH SCHEMA geo;

-- PostGIS geo schema में है, इसलिए हर उस schema का search_path बढ़ाना पड़ता है
-- जो geography type इस्तेमाल करती है, वरना type resolution fail होती है।
ALTER DATABASE CURRENT SET search_path = "$user", public, geo;

-- of_analytics_ro — SPEC.md §2 का एकमात्र cross-schema पाठक। यह LOGIN role नहीं
-- है; असली user इसे GRANT करके पाता है (0029 देखें), ताकि credential rotation
-- privileges को न छुए।
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'of_analytics_ro') THEN
        CREATE ROLE of_analytics_ro NOLOGIN;
    END IF;
END
$$;

-- हर owning service का role। इन्हें अपनी ही schema पर पूरा अधिकार मिलता है और
-- दूसरी schema पर कुछ भी नहीं — SPEC.md §7 नियम 2 का database-स्तरीय प्रवर्तन।
DO $$
DECLARE
    svc TEXT;
BEGIN
    FOREACH svc IN ARRAY ARRAY[
        'of_identity_rw', 'of_fleet_rw', 'of_freight_rw', 'of_routing_rw',
        'of_geo_rw', 'of_telemetry_rw', 'of_customs_rw', 'of_billing_rw',
        'of_platform_rw'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = svc) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', svc);
        END IF;
    END LOOP;
END
$$;

-- schema_migrations — हर service का /version endpoint (SPEC.md §3.15) यही
-- table पढ़कर बताता है कि उसे किस migration number की उम्मीद है।
CREATE TABLE IF NOT EXISTS platform.schema_migrations (
    version     TEXT        PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    checksum    BYTEA       NOT NULL,
    applied_by  TEXT        NOT NULL DEFAULT current_user
);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0001_bootstrap_schemas_extensions_roles', sha256('0001'::bytea))
ON CONFLICT (version) DO NOTHING;

COMMIT;
