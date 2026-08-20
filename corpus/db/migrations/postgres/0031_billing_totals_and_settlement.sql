-- ---------------------------------------------------------------------------
-- 0031_billing_totals_and_settlement.sql
--
-- billing.invoices का subtotal/total खुद-ब-खुद अपनी lines से मेल खाता रहे, और
-- भुगतान पूरा होते ही invoice settled हो — दोनों काम trigger से, क्योंकि
-- invoice_total_is_consistent वाला CHECK अन्यथा हर line insert पर गिरता है।
--
-- SPEC.md §2.7, §3.8, §4.15।
-- ---------------------------------------------------------------------------

BEGIN;

-- subtotal_minor सिर्फ़ उन lines का जोड़ है जो duty नहीं हैं: duty_disbursement
-- वाली line का पैसा duty_minor में गिना जाता है, दोनों में नहीं। यह भेद एक बार
-- छूट गया था और हर सीमापार invoice दोगुना duty दिखा रहा था।
CREATE OR REPLACE FUNCTION billing.invoices_recompute_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    target_invoice TEXT := COALESCE(NEW.invoice_id, OLD.invoice_id);
    new_subtotal   BIGINT;
    new_duty       BIGINT;
BEGIN
    SELECT
        COALESCE(sum(amount_minor) FILTER (WHERE charge_code <> 'duty_disbursement'), 0),
        COALESCE(sum(amount_minor) FILTER (WHERE charge_code =  'duty_disbursement'), 0)
      INTO new_subtotal, new_duty
      FROM billing.invoice_lines
     WHERE invoice_id = target_invoice;

    UPDATE billing.invoices
       SET subtotal_minor = new_subtotal,
           duty_minor     = new_duty,
           total_minor    = new_subtotal + new_duty + tax_minor
     WHERE invoice_id = target_invoice;

    RETURN NULL;
END;
$$;

CREATE TRIGGER invoice_lines_totals_aiud
    AFTER INSERT OR UPDATE OR DELETE ON billing.invoice_lines
    FOR EACH ROW
    EXECUTE FUNCTION billing.invoices_recompute_totals();

-- जारी हो चुके invoice की lines बदलना मना है — सुधार credit note से होता है
-- (SPEC.md §7 नियम 6)।
CREATE OR REPLACE FUNCTION billing.invoice_lines_guard_issued()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    current_status TEXT;
BEGIN
    SELECT status INTO current_status
      FROM billing.invoices
     WHERE invoice_id = COALESCE(NEW.invoice_id, OLD.invoice_id);

    IF current_status <> 'draft' THEN
        RAISE EXCEPTION 'invoice % जारी हो चुका है; सुधार credit note से करें',
            COALESCE(NEW.invoice_id, OLD.invoice_id)
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER invoice_lines_guard_issued_biud
    BEFORE INSERT OR UPDATE OR DELETE ON billing.invoice_lines
    FOR EACH ROW
    EXECUTE FUNCTION billing.invoice_lines_guard_issued();

-- भुगतान आते ही शेष गिनना और शून्य पर पहुँचने पर settled करना, साथ ही
-- billing.invoice.settled को outbox में डालना। वही event customs-service के
-- customs.customs_declarations.duty_paid को पलटाता है — पूरे platform में duty_paid
-- बदलने का इकलौता रास्ता (SPEC.md §4.15)।
CREATE OR REPLACE FUNCTION billing.payments_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    inv          billing.invoices%ROWTYPE;
    paid_minor   BIGINT;
BEGIN
    SELECT * INTO inv FROM billing.invoices WHERE invoice_id = NEW.invoice_id FOR UPDATE;

    IF inv.status IN ('draft','void','written_off') THEN
        RAISE EXCEPTION 'invoice % की स्थिति % है; भुगतान स्वीकार नहीं', inv.invoice_id, inv.status
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.currency <> inv.currency THEN
        RAISE EXCEPTION 'भुगतान की मुद्रा % invoice की मुद्रा % से भिन्न है', NEW.currency, inv.currency
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(amount_minor), 0) INTO paid_minor
      FROM billing.payments
     WHERE invoice_id = NEW.invoice_id AND reversed_at IS NULL;

    IF paid_minor >= inv.total_minor THEN
        UPDATE billing.invoices
           SET status = 'settled', settled_at = NEW.received_at
         WHERE invoice_id = NEW.invoice_id;

        INSERT INTO platform.outbox_messages (
            message_id, producer, aggregate_type, aggregate_id,
            event_name, topic, partition_key, schema_version, payload
        ) VALUES (
            'evt_' || upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 26)),
            'billing-service', 'invoice', inv.invoice_id,
            'billing.invoice.settled', 'of.billing.v1', inv.shipment_id, 1,
            jsonb_build_object(
                'invoice_id',       inv.invoice_id,
                'tenant_id',        inv.tenant_id,
                'shipment_id',      inv.shipment_id,
                'total_minor',      inv.total_minor,
                'currency',         inv.currency,
                'settled_at',       to_char(NEW.received_at AT TIME ZONE 'UTC',
                                            'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                'final_payment_id', NEW.payment_id
            )
        );
    ELSIF paid_minor > 0 AND inv.status = 'issued' THEN
        UPDATE billing.invoices SET status = 'part_paid' WHERE invoice_id = NEW.invoice_id;
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER payments_apply_ai
    AFTER INSERT ON billing.payments
    FOR EACH ROW
    EXECUTE FUNCTION billing.payments_apply();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0031_billing_totals_and_settlement', sha256('0031'::bytea));

COMMIT;
