-- ---------------------------------------------------------------------------
-- 0018_cross_schema_foreign_keys.sql
--
-- SPEC.md §2 की उन गिनी-चुनी foreign keys को जोड़ती है जो schema की सीमा पार
-- करती हैं। ये अलग migration में इसलिए हैं कि इन्हें जोड़ने के लिए दोनों तरफ़ की
-- tables पहले से मौजूद होनी चाहिए, और क्योंकि इनकी सूची जानबूझकर बंद है — कोई
-- पाँचवीं cross-schema FK जोड़ने का मतलब पहले SPEC.md बदलना है।
--
-- ये चारों इसलिए बची हैं कि इनके बिना चार बार orphan-cleanup की घटना हो चुकी है।
-- शर्त एक ही है: लक्ष्य धीरे बदलने वाला reference data हो जिसका owner पंक्तियाँ
-- कभी मिटाता न हो।
-- ---------------------------------------------------------------------------

BEGIN;

-- freight.containers.owner_carrier_id → fleet.carriers
--
-- Carrier पंक्तियाँ कभी DELETE नहीं होतीं (insurance इतिहास बचाना है), इसलिए
-- ON DELETE का कोई व्यवहार तय नहीं करना पड़ता; NO ACTION ही सही संकेत है — अगर
-- कोई सचमुच carrier मिटाने की कोशिश करे तो वह रुकनी चाहिए।
ALTER TABLE freight.containers
    ADD CONSTRAINT containers_owner_carrier_fk
    FOREIGN KEY (owner_carrier_id) REFERENCES fleet.carriers(carrier_id)
    ON UPDATE RESTRICT ON DELETE NO ACTION;

CREATE INDEX containers_owner_carrier_idx
    ON freight.containers (owner_carrier_id)
    WHERE owner_carrier_id IS NOT NULL;

COMMENT ON CONSTRAINT containers_owner_carrier_fk ON freight.containers IS
    'अनुमत cross-schema FK; बाक़ी हर बाहरी संदर्भ logical FK है और owning service जाँचती है';

-- routing.route_legs.crossing_id → geo.border_crossings पहले ही 0014 में घोषित
-- हो चुकी है क्योंकि geo उससे पहले बनती है; यहाँ सिर्फ़ पुष्टि के लिए दर्ज।
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'route_legs_crossing_id_fkey'
           AND conrelid = 'routing.route_legs'::regclass
    ) THEN
        RAISE EXCEPTION 'routing.route_legs → geo.border_crossings FK ग़ायब है; 0014 अधूरी चली';
    END IF;
END
$$;

-- शेष दो (geo.border_crossings.geofence_id और platform.documents.owner_type)
-- अपनी-अपनी migration में इसलिए घोषित हैं कि वे एक ही schema के भीतर हैं या
-- table बनते ही ज़रूरी थीं।

-- logical FKs की सूची एक असली table में रखते हैं, टिप्पणी में नहीं। ops/ का
-- orphan-scan script रोज़ रात इसी को पढ़कर हर जोड़ी पर anti-join चलाता है — यही
-- वह जाँच है जो FK के बदले में मिली है।
CREATE TABLE platform.logical_foreign_keys (
    child_schema     TEXT NOT NULL,
    child_table      TEXT NOT NULL,
    child_column     TEXT NOT NULL,
    parent_schema    TEXT NOT NULL,
    parent_table     TEXT NOT NULL,
    parent_column    TEXT NOT NULL,
    enforcing_service TEXT NOT NULL,
    note             TEXT,
    PRIMARY KEY (child_schema, child_table, child_column)
);

COMMENT ON TABLE platform.logical_foreign_keys IS
    'वे संदर्भ जिन्हें database नहीं, owning service जाँचती है; ops/ का nightly orphan-scan इसी सूची पर चलता है';

INSERT INTO platform.logical_foreign_keys VALUES
  ('freight',   'shipments',           'tenant_id',   'identity', 'tenants',          'tenant_id',   'container-registry', 'tenant पंक्ति identity-service की है'),
  ('fleet',     'carriers',            'tenant_id',   'identity', 'tenants',          'tenant_id',   'fleet-service',      NULL),
  ('fleet',     'depots',              'geofence_id', 'geo',      'geofences',        'geofence_id', 'fleet-service',      'ResolveGeofence से पुष्टि होती है'),
  ('fleet',     'vehicle_assignments', 'shipment_id', 'freight',  'shipments',        'shipment_id', 'fleet-service',      'Assign से पहले container-registry पूछी जाती है'),
  ('freight',   'facilities',          'geofence_id', 'geo',      'geofences',        'geofence_id', 'container-registry', NULL),
  ('routing',   'routes',              'shipment_id', 'freight',  'shipments',        'shipment_id', 'routing-service',    NULL),
  ('customs',   'customs_declarations','shipment_id', 'freight',  'shipments',        'shipment_id', 'customs-service',    NULL),
  ('customs',   'customs_declarations','crossing_id', 'geo',      'border_crossings', 'crossing_id', 'customs-service',    'customs_office_code यहीं से आता है'),
  ('billing',   'invoices',            'shipment_id', 'freight',  'shipments',        'shipment_id', 'billing-service',    NULL),
  ('telemetry', 'device_gateways',     'depot_id',    'fleet',    'depots',           'depot_id',    'telemetry-ingest',   'NULL का मतलब चलता-फिरता gateway'),
  ('telemetry', 'telemetry_alerts',    'container_id','freight',  'containers',       'container_id','telemetry-ingest',   NULL);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0018_cross_schema_foreign_keys', sha256('0018'::bytea));

COMMIT;
