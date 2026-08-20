-- ---------------------------------------------------------------------------
-- 0013_freight_shipment_containers_and_scans.sql
--
-- shipment और container का जोड़ (seal उसी जोड़ का गुण है, किसी एक पक्ष का नहीं)
-- तथा scan trail। scan trail व्यवहार में append-only है और उसकी छेड़छाड़-रोधी
-- नक़ल platform.audit_ledger_entries में जाती है।
--
-- SPEC.md §2.3, §3.3, §4.4।
-- ---------------------------------------------------------------------------

BEGIN;

-- Payload वाला many-to-many: एक shipment कई containers रखती है और एक container
-- अपने जीवनकाल में कई shipments पर जाता है। seal_number किसी एक पक्ष का गुण नहीं
-- है — वह इसी जोड़ी का है, इसलिए join table पर बैठता है।
CREATE TABLE freight.shipment_containers (
    shipment_id  TEXT        NOT NULL REFERENCES freight.shipments(shipment_id) ON DELETE CASCADE,
    container_id TEXT        NOT NULL REFERENCES freight.containers(container_id),
    seal_number  TEXT        NOT NULL,
    gross_kg     INTEGER     NOT NULL,
    loaded_at    TIMESTAMPTZ,
    unloaded_at  TIMESTAMPTZ,
    PRIMARY KEY (shipment_id, container_id),

    CONSTRAINT shipment_containers_gross_is_positive CHECK (gross_kg > 0),
    CONSTRAINT shipment_containers_unload_after_load
        CHECK (unloaded_at IS NULL OR loaded_at IS NULL OR unloaded_at >= loaded_at)
);

COMMENT ON COLUMN freight.shipment_containers.seal_number IS
    'OF_FREIGHT_SEAL_FORMAT_REGEX इसका आकार जाँचता है; sealed होने के बाद बदला नहीं जा सकता';

-- 'यह डिब्बा अभी किस shipment पर है' — telemetry-ingest यही सवाल
-- freight.v1.ContainerLookup/ResolveShipmentForContainer के ज़रिए हर alert पर
-- पूछती है, इसलिए उल्टी दिशा का index अनिवार्य है।
CREATE INDEX shipment_containers_by_container_idx
    ON freight.shipment_containers (container_id, loaded_at DESC);

-- खुले (लदे पर अनलोड न हुए) डिब्बे — यही 'idle box' रिपोर्ट का आधार है।
CREATE INDEX shipment_containers_in_transit_idx
    ON freight.shipment_containers (container_id)
    WHERE loaded_at IS NOT NULL AND unloaded_at IS NULL;

-- Scan trail। व्यवहार में append-only है (container-registry में कोई UPDATE
-- रास्ता नहीं), पर hash-chained नहीं — छेड़छाड़-रोधी प्रति
-- platform.audit_ledger_entries में जाती है और वही क़ानूनी रिकॉर्ड है।
--
-- occurred_at और recorded_at अलग हैं क्योंकि depot inspector का Android app
-- offline भी काम करता है: scan जहाज़ पर होती है, upload घंटों बाद।
CREATE TABLE freight.shipment_scan_events (
    scan_id            TEXT        PRIMARY KEY,
    shipment_id        TEXT        NOT NULL REFERENCES freight.shipments(shipment_id),
    container_id       TEXT        REFERENCES freight.containers(container_id),
    scan_type          TEXT        NOT NULL CHECK (scan_type IN
                         ('gate_in','gate_out','load','unload','seal_check','customs_inspection',
                          'damage_report','proof_of_delivery')),
    scanned_by_user_id TEXT        NOT NULL,
    facility_id        TEXT        REFERENCES freight.facilities(facility_id),
    occurred_at        TIMESTAMPTZ NOT NULL,
    recorded_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    position           geography(Point, 4326),
    device_serial      TEXT,
    notes              TEXT,

    CONSTRAINT scans_id_is_prefixed_ulid
        CHECK (scan_id ~ '^scn_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- upload हमेशा घटना के बाद होता है; उल्टा मतलब उपकरण की घड़ी गड़बड़ है।
    -- OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S इसी अंतर की ऊपरी सीमा तय करता है,
    -- पर वह नीति है — यह जाँच सिर्फ़ असंभव को रोकती है।
    CONSTRAINT scans_recorded_after_occurred CHECK (recorded_at >= occurred_at),

    -- proof_of_delivery ही billing को खोलता है (SPEC.md §4.4), इसलिए उसके लिए
    -- container और facility दोनों का होना अनिवार्य है।
    CONSTRAINT scans_pod_needs_context
        CHECK (scan_type <> 'proof_of_delivery' OR (container_id IS NOT NULL AND facility_id IS NOT NULL))
);

COMMENT ON TABLE freight.shipment_scan_events IS
    'POST /v1/containers/{container_id}/scans यहाँ लिखती है और shipment.scanned प्रकाशित करती है';

-- GET /v1/shipments/{shipment_id}/scans — नया पहले।
CREATE INDEX scan_events_shipment_idx
    ON freight.shipment_scan_events (shipment_id, occurred_at DESC);

-- billing-service सिर्फ़ proof_of_delivery पर प्रतिक्रिया देती है; बाक़ी 95% scans
-- उसके सवाल में आनी ही नहीं चाहिए।
CREATE INDEX scan_events_pod_idx
    ON freight.shipment_scan_events (shipment_id, occurred_at DESC)
    WHERE scan_type = 'proof_of_delivery';

CREATE INDEX scan_events_container_idx
    ON freight.shipment_scan_events (container_id, occurred_at DESC)
    WHERE container_id IS NOT NULL;

-- geo.v1.GeoService/SnapToRoad इन बिंदुओं को साफ़ करती है इससे पहले कि वे
-- analytics.mv_lane_performance_daily तक पहुँचें।
CREATE INDEX scan_events_position_gix
    ON freight.shipment_scan_events USING gist (position)
    WHERE position IS NOT NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0013_freight_shipment_containers_and_scans', sha256('0013'::bytea));

COMMIT;
