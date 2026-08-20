-- ---------------------------------------------------------------------------
-- 0008_billing.sql
--
-- billing-service की तीन tables और वे trigger जो totals को अपनी lines से बाँधे
-- रखते हैं। MySQL यहाँ लगभग बिना विरोध के अनुवाद हो जाता है — एक बात छोड़कर:
-- CHECK constraint को trigger के भीतर की गई UPDATE भी जाँचती है, इसलिए totals
-- की पुनर्गणना और invoice_total_is_consistent का क्रम मायने रखता है।
--
-- SPEC.md §2.7, §3.8।
-- ---------------------------------------------------------------------------

CREATE TABLE billing.invoices (
    invoice_id     VARCHAR(30) NOT NULL,
    tenant_id      VARCHAR(30) NOT NULL,
    shipment_id    VARCHAR(30) NOT NULL,   -- logical FK → freight.shipments
    invoice_number VARCHAR(64) NULL,       -- जारी होने पर ही मिलता है
    currency       CHAR(3)     NOT NULL,
    subtotal_minor BIGINT      NOT NULL DEFAULT 0,
    duty_minor     BIGINT      NOT NULL DEFAULT 0,   -- customs-service से
    tax_minor      BIGINT      NOT NULL DEFAULT 0,
    total_minor    BIGINT      NOT NULL DEFAULT 0,
    status         ENUM('draft','issued','part_paid','settled','on_hold','void','written_off')
                               NOT NULL DEFAULT 'draft',
    hold_reason    VARCHAR(64) NULL,       -- reconciliation.discrepancy.opened के kind से
    issued_at      DATETIME(6) NULL,
    due_on         DATE        NULL,
    settled_at     DATETIME(6) NULL,
    created_at     DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (invoice_id),
    UNIQUE KEY invoices_number (invoice_number),

    CONSTRAINT invoice_total_is_consistent
        CHECK (total_minor = subtotal_minor + duty_minor + tax_minor),
    CONSTRAINT invoices_amounts_not_negative
        CHECK (subtotal_minor >= 0 AND duty_minor >= 0 AND tax_minor >= 0),
    CONSTRAINT invoices_number_only_when_issued
        CHECK ((invoice_number IS NULL) = (status = 'draft')),
    CONSTRAINT invoices_hold_needs_reason
        CHECK ((status = 'on_hold') = (hold_reason IS NOT NULL)),
    CONSTRAINT invoices_settled_has_timestamp
        CHECK ((status = 'settled') = (settled_at IS NOT NULL)),
    CONSTRAINT invoices_currency_is_iso4217 CHECK (currency REGEXP '^[A-Z]{3}$'),

    KEY invoices_unsettled_idx (tenant_id, status, due_on),
    KEY invoices_shipment_idx (shipment_id, created_at)
) ENGINE = InnoDB;

CREATE TABLE billing.invoice_lines (
    invoice_line_id  VARCHAR(30)   NOT NULL,
    invoice_id       VARCHAR(30)   NOT NULL,
    seq_no           SMALLINT      NOT NULL,
    charge_code      ENUM('linehaul','fuel_surcharge','demurrage','detention','reefer_power',
                          'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')
                                   NOT NULL,
    description      VARCHAR(512)  NOT NULL,
    quantity         DECIMAL(12,3) NOT NULL DEFAULT 1,
    unit_price_minor BIGINT        NOT NULL,
    amount_minor     BIGINT        NOT NULL,
    -- चार अलग schemas में बैठे स्रोत; इसलिए कोई FK संभव नहीं।
    source_kind      ENUM('leg','alert','declaration','assignment','manual') NULL,
    source_id        VARCHAR(30)   NULL,
    PRIMARY KEY (invoice_line_id),
    UNIQUE KEY invoice_lines_seq (invoice_id, seq_no),

    CONSTRAINT invoice_lines_seq_starts_at_one CHECK (seq_no >= 1),
    CONSTRAINT invoice_lines_quantity_is_positive CHECK (quantity > 0),
    CONSTRAINT invoice_lines_source_pair_is_complete
        CHECK (source_kind IS NULL OR source_kind = 'manual' OR source_id IS NOT NULL),
    CONSTRAINT invoice_lines_invoice_fk FOREIGN KEY (invoice_id)
        REFERENCES billing.invoices (invoice_id) ON DELETE CASCADE,

    KEY invoice_lines_source_idx (source_kind, source_id)
) ENGINE = InnoDB;

CREATE TABLE billing.payments (
    payment_id   VARCHAR(30) NOT NULL,
    invoice_id   VARCHAR(30) NOT NULL,
    method       ENUM('sepa_dd','swift','card','credit_note','cash') NOT NULL,
    amount_minor BIGINT      NOT NULL,
    currency     CHAR(3)     NOT NULL,
    received_at  DATETIME(6) NOT NULL,
    external_ref VARCHAR(128) NULL,
    reversed_at  DATETIME(6) NULL,
    PRIMARY KEY (payment_id),
    -- बैंक फ़ाइल दोबारा चढ़ने पर दोहरी वसूली रोकने वाली इकलौती जाँच।
    UNIQUE KEY payments_external (method, external_ref),

    CONSTRAINT payments_amount_is_positive CHECK (amount_minor > 0),
    CONSTRAINT payments_currency_is_iso4217 CHECK (currency REGEXP '^[A-Z]{3}$'),
    CONSTRAINT payments_reversal_after_receipt
        CHECK (reversed_at IS NULL OR reversed_at >= received_at),
    CONSTRAINT payments_external_ref_required
        CHECK (method = 'cash' OR external_ref IS NOT NULL),
    CONSTRAINT payments_invoice_fk FOREIGN KEY (invoice_id)
        REFERENCES billing.invoices (invoice_id),

    KEY payments_invoice_idx (invoice_id, received_at)
) ENGINE = InnoDB;

DELIMITER $$

-- duty_disbursement वाली line duty_minor में गिनी जाती है, subtotal में नहीं —
-- दोनों में गिनने पर हर सीमापार invoice दोगुना duty दिखाता था।
CREATE PROCEDURE billing.recompute_invoice_totals(IN p_invoice_id VARCHAR(30))
BEGIN
    DECLARE new_subtotal BIGINT DEFAULT 0;
    DECLARE new_duty     BIGINT DEFAULT 0;

    SELECT
        COALESCE(SUM(CASE WHEN charge_code <> 'duty_disbursement' THEN amount_minor ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN charge_code =  'duty_disbursement' THEN amount_minor ELSE 0 END), 0)
      INTO new_subtotal, new_duty
      FROM billing.invoice_lines
     WHERE invoice_id = p_invoice_id;

    UPDATE billing.invoices
       SET subtotal_minor = new_subtotal,
           duty_minor     = new_duty,
           total_minor    = new_subtotal + new_duty + tax_minor
     WHERE invoice_id = p_invoice_id;
END$$

CREATE TRIGGER invoice_lines_totals_ai
AFTER INSERT ON billing.invoice_lines
FOR EACH ROW
BEGIN
    CALL billing.recompute_invoice_totals(NEW.invoice_id);
END$$

CREATE TRIGGER invoice_lines_totals_au
AFTER UPDATE ON billing.invoice_lines
FOR EACH ROW
BEGIN
    CALL billing.recompute_invoice_totals(NEW.invoice_id);
END$$

CREATE TRIGGER invoice_lines_totals_ad
AFTER DELETE ON billing.invoice_lines
FOR EACH ROW
BEGIN
    CALL billing.recompute_invoice_totals(OLD.invoice_id);
END$$

-- जारी हो चुके invoice की lines अपरिवर्तनीय हैं; सुधार credit note से।
CREATE TRIGGER invoice_lines_guard_issued_bi
BEFORE INSERT ON billing.invoice_lines
FOR EACH ROW
BEGIN
    DECLARE current_status VARCHAR(16);
    SELECT status INTO current_status FROM billing.invoices WHERE invoice_id = NEW.invoice_id;
    IF current_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'invoice already issued; correct with a credit note';
    END IF;
END$$

DELIMITER ;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0008_billing', UNHEX(SHA2('0008', 256)));
