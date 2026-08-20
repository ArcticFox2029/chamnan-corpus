-- ---------------------------------------------------------------------------
-- 0030_freight_shipment_status_machine.sql
--
-- freight.shipments की स्थिति-मशीन को database में उतारती है, और हर बदलाव के साथ
-- platform.outbox_messages में shipment.status.changed की पंक्ति उसी transaction
-- में डालती है — SPEC.md §7 नियम 3 का शाब्दिक पालन।
--
-- CHECK constraint बता सकता है कि स्थिति वैध है, पर यह नहीं कि *यह* बदलाव वैध
-- था। वह जानकारी सिर्फ़ (पुरानी, नई) जोड़ी में है, इसलिए trigger चाहिए।
-- ---------------------------------------------------------------------------

BEGIN;

-- अनुमत संक्रमणों की सारणी। इसे code में रखना आज़माया गया था और तीन अलग जगहों
-- (Kotlin handler, partner-portal का proxy, एक data-fix script) में तीन अलग
-- संस्करण मिले। अब सच एक ही जगह है।
CREATE TABLE freight.shipment_status_transitions (
    from_status TEXT NOT NULL,
    to_status   TEXT NOT NULL,
    is_terminal BOOLEAN NOT NULL DEFAULT false,
    note        TEXT,
    PRIMARY KEY (from_status, to_status)
);

COMMENT ON TABLE freight.shipment_status_transitions IS
    'PATCH /v1/shipments/{shipment_id}/status की वैधता यहीं से जाँची जाती है';

INSERT INTO freight.shipment_status_transitions (from_status, to_status, is_terminal, note) VALUES
  ('draft',          'booked',          false, 'सामान्य आगे की चाल'),
  ('draft',          'cancelled',       true,  NULL),
  ('booked',         'sealed',          false, 'सील लगते ही containers जुड़/हट नहीं सकते'),
  ('booked',         'cancelled',       true,  NULL),
  ('sealed',         'in_transit',      false, 'पहली gate_out scan पर'),
  ('sealed',         'cancelled',       true,  'सील तोड़नी पड़ती है; audit entry अनिवार्य'),
  ('in_transit',     'at_risk',         false, 'telemetry.alert.raised से, synchronously नहीं'),
  ('in_transit',     'held_at_customs', false, 'customs.declaration.filed के बाद निरीक्षण'),
  ('in_transit',     'delivered',       true,  'proof_of_delivery scan पर'),
  ('at_risk',        'in_transit',      false, 'alert बंद होने पर वापसी'),
  ('at_risk',        'held_at_customs', false, NULL),
  ('at_risk',        'delivered',       true,  NULL),
  ('held_at_customs','in_transit',      false, 'customs.declaration.cleared के बाद'),
  ('held_at_customs','at_risk',         false, NULL),
  ('held_at_customs','cancelled',       true,  'ज़ब्ती या अस्वीकृति');

-- यह trigger दो काम करता है और दोनों एक ही transaction में होने चाहिए: संक्रमण
-- की वैधता जाँचना, और event को outbox में रखना। अगर दूसरा अलग transaction में
-- होता तो एक क्रैश स्थिति बदल देता पर event कभी न जाता — बिलकुल वही समस्या जिसे
-- outbox pattern हल करने आया है।
CREATE OR REPLACE FUNCTION freight.shipments_guard_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    allowed BOOLEAN;
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    SELECT true INTO allowed
      FROM freight.shipment_status_transitions
     WHERE from_status = OLD.status AND to_status = NEW.status;

    IF allowed IS NULL THEN
        RAISE EXCEPTION 'shipment % : % → % अनुमत संक्रमण नहीं है',
            OLD.shipment_id, OLD.status, NEW.status
            USING ERRCODE = 'check_violation',
                  HINT = 'freight.shipment_status_transitions देखें';
    END IF;

    -- सील लगने के बाद containers जुड़ या हट नहीं सकते; वह जाँच
    -- POST /v1/shipments/{id}/containers में है, पर उसे यहाँ दोहराना सस्ता है।
    IF NEW.status = 'sealed' AND NOT EXISTS (
        SELECT 1 FROM freight.shipment_containers WHERE shipment_id = NEW.shipment_id
    ) THEN
        RAISE EXCEPTION 'shipment % में एक भी container नहीं है, सील नहीं लग सकती', NEW.shipment_id
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO platform.outbox_messages (
        message_id, producer, aggregate_type, aggregate_id,
        event_name, topic, partition_key, schema_version, payload
    ) VALUES (
        'evt_' || upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 26)),
        'container-registry', 'shipment', NEW.shipment_id,
        'shipment.status.changed', 'of.freight.v1', NEW.shipment_id, 2,
        jsonb_build_object(
            'shipment_id', NEW.shipment_id,
            'tenant_id',   NEW.tenant_id,
            'from_status', OLD.status,
            'to_status',   NEW.status,
            'reason_code', coalesce(current_setting('of.reason_code', true), 'unspecified'),
            'changed_by',  coalesce(current_setting('of.actor_id', true), 'svc:container-registry'),
            'changed_at',  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        )
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER shipments_status_bu
    BEFORE UPDATE OF status ON freight.shipments
    FOR EACH ROW
    EXECUTE FUNCTION freight.shipments_guard_status();

-- सील लगने के बाद जोड़-घटाव रोकना। ON DELETE CASCADE अब भी shipment मिटने पर
-- चलता है, पर shipment मिटती नहीं — cancelled होती है।
CREATE OR REPLACE FUNCTION freight.shipment_containers_guard_seal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_status TEXT;
    target_shipment TEXT := COALESCE(NEW.shipment_id, OLD.shipment_id);
BEGIN
    SELECT status INTO current_status
      FROM freight.shipments WHERE shipment_id = target_shipment;

    IF current_status IN ('sealed','in_transit','at_risk','held_at_customs','delivered') THEN
        RAISE EXCEPTION 'shipment % सील हो चुकी है और container स्वीकार नहीं कर सकती', target_shipment
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER shipment_containers_seal_biud
    BEFORE INSERT OR UPDATE OR DELETE ON freight.shipment_containers
    FOR EACH ROW
    EXECUTE FUNCTION freight.shipment_containers_guard_seal();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0030_freight_shipment_status_machine', sha256('0030'::bytea));

COMMIT;
