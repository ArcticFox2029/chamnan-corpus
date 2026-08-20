-- ---------------------------------------------------------------------------
-- 0029_grants_and_row_security.sql
--
-- अनुमतियाँ। SPEC.md §7 नियम 2 ('कोई सेवा दूसरी की schema नहीं पढ़ती') यहाँ
-- database स्तर पर लागू होता है, टिप्पणी के भरोसे नहीं। साथ में ledger पर वह
-- संकीर्ण grant जो केवल INSERT और SELECT देता है — UPDATE/DELETE का grant है ही
-- नहीं, trigger दूसरी दीवार है।
-- ---------------------------------------------------------------------------

BEGIN;

-- हर सेवा को अपनी schema पर पूरा अधिकार।
GRANT USAGE ON SCHEMA identity  TO of_identity_rw;
GRANT USAGE ON SCHEMA fleet     TO of_fleet_rw;
GRANT USAGE ON SCHEMA freight   TO of_freight_rw;
GRANT USAGE ON SCHEMA routing   TO of_routing_rw;
GRANT USAGE ON SCHEMA geo       TO of_geo_rw;
GRANT USAGE ON SCHEMA telemetry TO of_telemetry_rw;
GRANT USAGE ON SCHEMA customs   TO of_customs_rw;
GRANT USAGE ON SCHEMA billing   TO of_billing_rw;
GRANT USAGE ON SCHEMA platform  TO of_platform_rw;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA identity  TO of_identity_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA fleet     TO of_fleet_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA freight   TO of_freight_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA routing   TO of_routing_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA geo       TO of_geo_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA telemetry TO of_telemetry_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA customs   TO of_customs_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA billing   TO of_billing_rw;

-- geo.border_crossings को routing-service पढ़ती है क्योंकि routing.route_legs.
-- crossing_id असली FK है और FK जाँच के लिए पढ़ना पड़ता है। यह पढ़ना SQL-स्तर का
-- join नहीं है, इसलिए नियम 2 का उल्लंघन नहीं।
GRANT SELECT ON geo.border_crossings TO of_routing_rw;

-- platform schema साझा है, पर table-दर-table मालिक अलग हैं।
GRANT SELECT, INSERT, UPDATE         ON platform.documents                 TO of_platform_rw;
GRANT SELECT                         ON platform.document_owner_types      TO of_platform_rw;
GRANT SELECT, INSERT, UPDATE         ON platform.notifications             TO of_platform_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON platform.notification_preferences  TO of_platform_rw;

-- Outbox में हर सेवा लिखती है (अपनी ही transaction में) और अपनी ही पंक्तियाँ
-- अद्यतन करती है। यह इकलौता साझा लेखन-बिंदु है और जानबूझकर है।
GRANT SELECT, INSERT, UPDATE ON platform.outbox_messages TO
    of_identity_rw, of_fleet_rw, of_freight_rw, of_routing_rw,
    of_geo_rw, of_telemetry_rw, of_customs_rw, of_billing_rw, of_platform_rw;

-- Ledger: सिर्फ़ जोड़ना और पढ़ना। UPDATE/DELETE का grant मौजूद ही नहीं — 0022 का
-- trigger दूसरी परत है, इसलिए superuser भी chain नहीं तोड़ पाता।
GRANT SELECT, INSERT ON platform.audit_ledger_entries TO of_platform_rw;
GRANT USAGE ON SEQUENCE platform.audit_ledger_entries_entry_id_seq TO of_platform_rw;
GRANT SELECT, INSERT ON platform.ledger_checkpoints   TO of_platform_rw;

-- analytics-pipeline: हर schema पर read-only। यही वह अपवाद है जिसका ज़िक्र
-- SPEC.md §2 में है और जिसकी वजह से database एक ही रखा गया।
GRANT USAGE ON SCHEMA identity, fleet, freight, routing, geo, telemetry,
                     customs, billing, platform, analytics TO of_analytics_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA identity  TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA fleet     TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA freight   TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA routing   TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA geo       TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA telemetry TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA customs   TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA billing   TO of_analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA platform  TO of_analytics_ro;

-- analytics schema उसकी अपनी है — views वही बनाती और ताज़ा करती है, और
-- reconciliation-service उसी schema की दो tables में लिखती है।
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA analytics TO of_analytics_ro;

-- ---------------------------------------------------------------------------
-- Row-level security केवल वहाँ जहाँ एक ही table को कई tenants के actor छूते हैं
-- और गलती की क़ीमत डेटा-रिसाव है। पूरे schema पर RLS लगाने की कोशिश एक बार हुई
-- थी और उसने telemetry ingest की throughput आधी कर दी — वहाँ actor हमेशा सेवा
-- खुद होती है, इसलिए वह सुरक्षा बेमानी थी।
-- ---------------------------------------------------------------------------
ALTER TABLE platform.documents      ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.notifications  ENABLE ROW LEVEL SECURITY;

-- of.tenant_id हर connection पर SET LOCAL से भरा जाता है; X-OF-Tenant header से
-- आता है और JWT के tid claim से मेल खाने पर ही (SPEC.md §0.3)।
CREATE POLICY documents_tenant_isolation ON platform.documents
    USING (tenant_id = current_setting('of.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('of.tenant_id', true));

CREATE POLICY notifications_tenant_isolation ON platform.notifications
    USING (tenant_id = current_setting('of.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('of.tenant_id', true));

-- analytics-pipeline हर tenant को देखती है; उसका काम ही cross-tenant समुच्चय है।
ALTER TABLE platform.documents     FORCE ROW LEVEL SECURITY;
CREATE POLICY documents_analytics_bypass ON platform.documents
    FOR SELECT TO of_analytics_ro USING (true);

CREATE POLICY notifications_analytics_bypass ON platform.notifications
    FOR SELECT TO of_analytics_ro USING (true);

-- भविष्य में बनने वाली tables पर भी वही अधिकार अपने आप लगें।
ALTER DEFAULT PRIVILEGES IN SCHEMA identity  GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA fleet     GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA freight   GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA routing   GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA geo       GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA customs   GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA billing   GRANT SELECT ON TABLES TO of_analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA platform  GRANT SELECT ON TABLES TO of_analytics_ro;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0029_grants_and_row_security', sha256('0029'::bytea));

COMMIT;
