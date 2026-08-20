-- ---------------------------------------------------------------------------
-- 0021_billing_invoices_lines_payments.sql
--
-- billing-service की तीनों tables। invoice का total हमेशा अपने तीन हिस्सों के
-- बराबर रहे, यह database खुद जाँचता है; और payments की (method, external_ref)
-- uniqueness बैंक फ़ाइल दोबारा आयात होने पर दोहरी वसूली रोकती है।
--
-- SPEC.md §2.7, §3.8, §4.14, §4.15, §4.17।
-- ---------------------------------------------------------------------------

BEGIN;

-- duty_minor customs-service से आता है (GET /v1/declarations/{id}), पर यहाँ जमा
-- कर लिया जाता है: invoice जारी होते ही राशियाँ जम जाती हैं, चाहे बाद में tariff
-- बदले या declaration संशोधित हो।
--
-- hold_reason reconciliation.discrepancy.opened के kind से भरता है। billing-service
-- उस event को खाती है और reconciliation-service को वापस कभी नहीं बुलाती
-- (SPEC.md §4.17)।
CREATE TABLE billing.invoices (
    invoice_id     TEXT        PRIMARY KEY,
    tenant_id      TEXT        NOT NULL,
    shipment_id    TEXT        NOT NULL,
    invoice_number TEXT        UNIQUE,
    currency       CHAR(3)     NOT NULL,
    subtotal_minor BIGINT      NOT NULL DEFAULT 0,
    duty_minor     BIGINT      NOT NULL DEFAULT 0,
    tax_minor      BIGINT      NOT NULL DEFAULT 0,
    total_minor    BIGINT      NOT NULL DEFAULT 0,
    status         TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                     ('draft','issued','part_paid','settled','on_hold','void','written_off')),
    hold_reason    TEXT,
    issued_at      TIMESTAMPTZ,
    due_on         DATE,
    settled_at     TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT invoices_id_is_prefixed_ulid
        CHECK (invoice_id ~ '^inv_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT invoices_shipment_is_prefixed
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT invoices_currency_is_iso4217 CHECK (currency ~ '^[A-Z]{3}$'),

    -- यह जाँच पूरे billing domain की सबसे उपयोगी पंक्ति है: line जोड़ने वाला हर
    -- रास्ता total दोबारा गिनता है, और एक बार एक rounding bug ने totals को चुपचाप
    -- 1 minor unit खिसका दिया था। तब से यह constraint उसे तुरंत पकड़ता है।
    CONSTRAINT invoice_total_is_consistent
        CHECK (total_minor = subtotal_minor + duty_minor + tax_minor),

    CONSTRAINT invoices_amounts_not_negative
        CHECK (subtotal_minor >= 0 AND duty_minor >= 0 AND tax_minor >= 0),

    -- invoice_number सिर्फ़ जारी होने पर मिलता है (SPEC.md §3.8) और OF_BILLING_
    -- INVOICE_NUMBER_FORMAT से बनता है — draft पर उसका होना गिनती में छेद करता है।
    CONSTRAINT invoices_number_only_when_issued
        CHECK ((invoice_number IS NULL) = (status = 'draft')),

    CONSTRAINT invoices_issued_has_timestamp
        CHECK (status = 'draft' OR issued_at IS NOT NULL),

    CONSTRAINT invoices_hold_needs_reason
        CHECK ((status = 'on_hold') = (hold_reason IS NOT NULL)),

    CONSTRAINT invoices_settled_has_timestamp
        CHECK ((status = 'settled') = (settled_at IS NOT NULL))
);

COMMENT ON COLUMN billing.invoices.duty_minor IS
    'customs-service से आता है; billing कभी उसे वापस नहीं बुलाती — duty की अंतिम रक़म customs.declaration.cleared से आती है';
COMMENT ON COLUMN billing.invoices.hold_reason IS
    'reconciliation.discrepancy.opened का kind; OF_BILLING_HOLD_ON_DISCREPANCY_KINDS तय करता है कौन-से kinds रोकते हैं';

-- बकाया चालानों का sweep — due_on पर क्रमित, और सिर्फ़ वे जो अभी चुकी नहीं।
CREATE INDEX invoices_unsettled_idx
    ON billing.invoices (tenant_id, due_on)
    WHERE status IN ('issued','part_paid','on_hold');

-- reconciliation-service एक shipment के सारे invoices माँगती है।
CREATE INDEX invoices_shipment_idx
    ON billing.invoices (shipment_id, created_at DESC);

-- रोके गए चालानों की अलग screen; on_hold कुल का 1% से भी कम है।
CREATE INDEX invoices_on_hold_idx
    ON billing.invoices (tenant_id, hold_reason)
    WHERE status = 'on_hold';

-- source_kind/source_id की जोड़ी जानबूझकर बिना FK के है: स्रोत चार अलग schemas
-- में हैं जिनके मालिक चार अलग सेवाएँ हैं (leg → routing, alert → telemetry,
-- declaration → customs, assignment → fleet)। एक भी FK यहाँ रखने का मतलब
-- billing-service को उन schemas में झाँकने की अनुमति देना होता।
CREATE TABLE billing.invoice_lines (
    invoice_line_id  TEXT     PRIMARY KEY,
    invoice_id       TEXT     NOT NULL REFERENCES billing.invoices(invoice_id) ON DELETE CASCADE,
    seq_no           SMALLINT NOT NULL,
    charge_code      TEXT     NOT NULL CHECK (charge_code IN
                       ('linehaul','fuel_surcharge','demurrage','detention','reefer_power',
                        'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')),
    description      TEXT     NOT NULL,
    quantity         NUMERIC(12,3) NOT NULL DEFAULT 1,
    unit_price_minor BIGINT   NOT NULL,
    amount_minor     BIGINT   NOT NULL,
    source_kind      TEXT     CHECK (source_kind IN
                       ('leg','alert','declaration','assignment','manual')),
    source_id        TEXT,
    UNIQUE (invoice_id, seq_no),

    CONSTRAINT invoice_lines_id_is_prefixed_ulid
        CHECK (invoice_line_id ~ '^ivl_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT invoice_lines_seq_starts_at_one CHECK (seq_no >= 1),
    CONSTRAINT invoice_lines_quantity_is_positive CHECK (quantity > 0),

    -- 'manual' के अलावा हर स्रोत के पास id होनी चाहिए; वरना reconciliation उस line
    -- को unbilled_accessorial से जोड़ नहीं पाती।
    CONSTRAINT invoice_lines_source_pair_is_complete
        CHECK (source_kind IS NULL OR source_kind = 'manual' OR source_id IS NOT NULL)
);

CREATE INDEX invoice_lines_invoice_idx ON billing.invoice_lines (invoice_id, seq_no);

-- reconciliation-service उल्टी दिशा में पूछती है: 'क्या इस alert का बिल बना?'
CREATE INDEX invoice_lines_source_idx
    ON billing.invoice_lines (source_kind, source_id)
    WHERE source_id IS NOT NULL;

-- (method, external_ref) की uniqueness ही एकमात्र चीज़ है जो बैंक की statement
-- फ़ाइल दोबारा आयात होने पर दोहरी वसूली रोकती है। यह असल में हुआ था: एक SEPA
-- फ़ाइल दो बार चढ़ी और 340 invoices अधिक-भुगतान में चले गए।
CREATE TABLE billing.payments (
    payment_id   TEXT        PRIMARY KEY,
    invoice_id   TEXT        NOT NULL REFERENCES billing.invoices(invoice_id),
    method       TEXT        NOT NULL CHECK (method IN ('sepa_dd','swift','card','credit_note','cash')),
    amount_minor BIGINT      NOT NULL CHECK (amount_minor > 0),
    currency     CHAR(3)     NOT NULL,
    received_at  TIMESTAMPTZ NOT NULL,
    external_ref TEXT,
    reversed_at  TIMESTAMPTZ,
    UNIQUE (method, external_ref),

    CONSTRAINT payments_id_is_prefixed_ulid
        CHECK (payment_id ~ '^pay_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT payments_currency_is_iso4217 CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payments_reversal_after_receipt
        CHECK (reversed_at IS NULL OR reversed_at >= received_at),

    -- नक़द के अलावा हर तरीक़े का बाहरी संदर्भ होता है; उसके बिना मिलान असंभव है।
    CONSTRAINT payments_external_ref_required
        CHECK (method = 'cash' OR external_ref IS NOT NULL)
);

CREATE INDEX payments_invoice_idx ON billing.payments (invoice_id, received_at);

-- reconciliation की orphan_payment खोज: वे भुगतान जो पलटे नहीं और जिनका invoice
-- अब भी बकाया दिखता है।
CREATE INDEX payments_live_idx
    ON billing.payments (received_at DESC)
    WHERE reversed_at IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0021_billing_invoices_lines_payments', sha256('0021'::bytea));

COMMIT;
