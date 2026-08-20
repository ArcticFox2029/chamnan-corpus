-- ---------------------------------------------------------------------------
-- 0007_fleet_vehicle_assignments.sql
--
-- fleet.vehicle_assignments — वह table जिसका पूरा अस्तित्व दो GiST exclusion
-- constraints के लिए है। "एक vehicle एक समय पर एक ही shipment पर" का नियम यहीं,
-- database में, तय होता है; fleet.v1.FleetService/Assign असल में इसी constraint
-- से टकराकर हार या जीत तय करती है।
--
-- SPEC.md §2.2, §3.2। OF_FLEET_ASSIGNMENT_LOCK_TIMEOUT_MS वही प्रतीक्षा है जो
-- Assign यहाँ lock पर बिताती है।
-- ---------------------------------------------------------------------------

BEGIN;

-- नियम application में नहीं रखा जा सकता था क्योंकि दो अलग writers हैं: dispatch
-- console और driver-ios app। दोनों के बीच race असली थी और उसने एक ही trailer को
-- दो shipments पर भेज दिया था।
--
-- active_period generated column है ताकि assigned_at/released_at और range कभी
-- अलग न पड़ें; '[)' सीमा इसलिए कि एक assignment ठीक उसी क्षण खत्म होकर अगली शुरू
-- कर सकती है बिना टकराए।
CREATE TABLE fleet.vehicle_assignments (
    assignment_id TEXT        PRIMARY KEY,
    vehicle_id    TEXT        NOT NULL REFERENCES fleet.vehicles(vehicle_id),
    driver_id     TEXT        NOT NULL REFERENCES fleet.drivers(driver_id),
    -- logical FK → freight.shipments; container-registry की schema है, हम उसे
    -- SQL से नहीं छूते।
    shipment_id   TEXT        NOT NULL,
    -- logical FK → routing.route_legs; route.replanned आने पर fleet-service उन
    -- assignments को छोड़ देती है जिनका leg_id अब मौजूद नहीं (SPEC.md §4.11)।
    leg_id        TEXT,
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at   TIMESTAMPTZ,
    assigned_by   TEXT        NOT NULL,
    active_period TSTZRANGE   GENERATED ALWAYS AS
                    (tstzrange(assigned_at, released_at, '[)')) STORED,

    CONSTRAINT assignments_id_is_prefixed_ulid
        CHECK (assignment_id ~ '^asg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT assignments_shipment_is_prefixed
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT assignments_release_after_assign
        CHECK (released_at IS NULL OR released_at > assigned_at),

    -- असली मध्यस्थ। btree_gist के बिना TEXT column को && के साथ एक ही index में
    -- नहीं रखा जा सकता — इसीलिए 0001 उसे install करती है।
    EXCLUDE USING gist (vehicle_id WITH =, active_period WITH &&),
    EXCLUDE USING gist (driver_id  WITH =, active_period WITH &&)
);

COMMENT ON TABLE fleet.vehicle_assignments IS
    'fleet.v1.FleetService/Assign का लक्ष्य; टक्कर पर 409 vehicle_already_assigned लौटता है';
COMMENT ON COLUMN fleet.vehicle_assignments.active_period IS
    'assigned_at से released_at तक; खुली assignment का ऊपरी सिरा infinity है और वही सारे conflicts पकड़ता है';

-- GET /v1/assignments?shipment_id=… सबसे आम प्रश्न है, और billing-service
-- fleet.assignment.released खाकर यही खोज दोहराती है।
CREATE INDEX assignments_shipment_idx
    ON fleet.vehicle_assignments (shipment_id, assigned_at DESC);

-- ?active=true वाला filter — खुली assignments कुल का 2% से कम होती हैं।
CREATE INDEX assignments_open_idx
    ON fleet.vehicle_assignments (vehicle_id, driver_id)
    WHERE released_at IS NULL;

-- route.replanned आने पर fleet-service उन्हीं legs को देखती है जो अभी खुली हैं।
CREATE INDEX assignments_leg_idx
    ON fleet.vehicle_assignments (leg_id)
    WHERE leg_id IS NOT NULL AND released_at IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0007_fleet_vehicle_assignments', sha256('0007'::bytea));

COMMIT;
