-- ---------------------------------------------------------------------------
-- 0019_customs_declarations.sql
--
-- customs.customs_declarations और उसकी line items। यह वह domain है जहाँ SPEC.md
-- §7 नियम 6 सबसे सख़्ती से लागू है: सुधार नई पंक्ति से होता है, UPDATE से नहीं —
-- amendment वही mrn रखकर status बदलती है और नई lines डालती है।
--
-- SPEC.md §2.6, §3.7, §4.12, §4.13।
-- ---------------------------------------------------------------------------

BEGIN;

-- duty_paid अकेला ऐसा column है जिसे customs-service अपनी मर्ज़ी से नहीं बदलती:
-- वह सिर्फ़ billing.invoice.settled event खाकर पलटता है (SPEC.md §4.15)। यही
-- billing ↔ customs चक्र को तोड़ता है — customs-service billing-service को कभी
-- synchronously नहीं बुलाती।
CREATE TABLE customs.customs_declarations (
    declaration_id      TEXT        PRIMARY KEY,
    tenant_id           TEXT        NOT NULL,
    shipment_id         TEXT        NOT NULL,
    crossing_id         TEXT        NOT NULL,
    customs_office_code TEXT        NOT NULL,
    broker_user_id      TEXT,
    direction           TEXT        NOT NULL CHECK (direction IN ('import','export','transit')),
    status              TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                          ('draft','submitted','under_review','held','cleared','rejected','amended')),
    mrn                 TEXT        UNIQUE,
    filed_at            TIMESTAMPTZ,
    cleared_at          TIMESTAMPTZ,
    assessed_duty_minor BIGINT,
    assessed_vat_minor  BIGINT,
    currency            CHAR(3)     NOT NULL,
    duty_paid           BOOLEAN     NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT declarations_id_is_prefixed_ulid
        CHECK (declaration_id ~ '^dcl_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT declarations_shipment_is_prefixed
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT declarations_crossing_is_prefixed
        CHECK (crossing_id ~ '^bxg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT declarations_currency_is_iso4217 CHECK (currency ~ '^[A-Z]{3}$'),

    -- MRN प्राधिकरण देता है, हम नहीं। 'cleared' बिना MRN के असंभव है और यही जाँच
    -- reconciliation-service की cleared_without_payment खोज को अर्थ देती है।
    CONSTRAINT declaration_cleared_needs_mrn
        CHECK (status <> 'cleared' OR (mrn IS NOT NULL AND cleared_at IS NOT NULL)),

    -- draft को छोड़कर हर स्थिति दाख़िले के बाद की है।
    CONSTRAINT declarations_filed_when_not_draft
        CHECK (status = 'draft' OR filed_at IS NOT NULL),

    -- राशियाँ या तो दोनों आँकी गई हैं या दोनों नहीं; अधूरा assessment billing को
    -- गलत duty_minor भेजता था।
    CONSTRAINT declarations_assessment_is_complete
        CHECK ((assessed_duty_minor IS NULL) = (assessed_vat_minor IS NULL)),

    CONSTRAINT declarations_amounts_not_negative
        CHECK (COALESCE(assessed_duty_minor, 0) >= 0 AND COALESCE(assessed_vat_minor, 0) >= 0)
);

COMMENT ON COLUMN customs.customs_declarations.duty_paid IS
    'सिर्फ़ billing.invoice.settled खाकर बदलता है; customs-service कभी billing-service को नहीं बुलाती';
COMMENT ON COLUMN customs.customs_declarations.mrn IS
    'राष्ट्रीय प्राधिकरण से स्वीकृति पर मिलता है; amendment वही mrn रखती है';

CREATE INDEX declarations_shipment_idx
    ON customs.customs_declarations (shipment_id);

-- reconciliation-service की रात वाली तीन-तरफ़ा मिलान: वे declarations जो साफ़ हो
-- गईं पर जिनका duty अभी चुकाया नहीं गया।
CREATE INDEX declarations_cleared_unpaid_idx
    ON customs.customs_declarations (tenant_id, cleared_at)
    WHERE status = 'cleared' AND duty_paid = false;

-- खुली declarations की console सूची।
CREATE INDEX declarations_open_idx
    ON customs.customs_declarations (tenant_id, status, filed_at DESC)
    WHERE status IN ('submitted','under_review','held');

CREATE INDEX declarations_office_idx
    ON customs.customs_declarations (customs_office_code, filed_at DESC);

-- Line items। tariff_id की foreign key यहाँ अभी नहीं जोड़ी जा सकती —
-- customs.tariff_schedules अगली migration में बनती है; वह forward reference 0020
-- के अंत में ALTER TABLE से जुड़ती है।
CREATE TABLE customs.declaration_line_items (
    line_id             TEXT        PRIMARY KEY,
    declaration_id      TEXT        NOT NULL
                          REFERENCES customs.customs_declarations(declaration_id) ON DELETE CASCADE,
    seq_no              SMALLINT    NOT NULL,
    hs_code             CHAR(10)    NOT NULL,
    description         TEXT        NOT NULL,
    origin_country      CHAR(2)     NOT NULL,
    quantity            NUMERIC(14,3) NOT NULL,
    unit                TEXT        NOT NULL,
    net_weight_kg       NUMERIC(12,3) NOT NULL,
    customs_value_minor BIGINT      NOT NULL,
    tariff_id           TEXT,
    duty_minor          BIGINT,
    UNIQUE (declaration_id, seq_no),

    CONSTRAINT lines_id_is_prefixed_ulid
        CHECK (line_id ~ '^lin_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- HS कोड दस अंक का होता है (छह अंतरराष्ट्रीय + चार राष्ट्रीय); अक्षर कभी नहीं।
    CONSTRAINT lines_hs_code_is_numeric CHECK (hs_code ~ '^[0-9]{10}$'),

    -- UN/ECE Rec 20 इकाइयाँ; सूची बंद रखी है ताकि tariff lookup की मात्रा-गणना
    -- अनुमान न लगाए।
    CONSTRAINT lines_unit_is_known
        CHECK (unit IN ('KGM','PCE','LTR','MTQ','MTR','TNE','SET','PR','NAR')),

    CONSTRAINT lines_quantity_is_positive CHECK (quantity > 0),
    CONSTRAINT lines_weight_not_negative CHECK (net_weight_kg >= 0),
    CONSTRAINT lines_value_not_negative CHECK (customs_value_minor >= 0),
    CONSTRAINT lines_seq_starts_at_one CHECK (seq_no >= 1)
);

COMMENT ON COLUMN customs.declaration_line_items.tariff_id IS
    'assessment के समय की ठीक वही tariff पंक्ति, जमा दी गई; बाद का बदलाव इतिहास नहीं बदल सकता';

CREATE INDEX lines_declaration_idx
    ON customs.declaration_line_items (declaration_id, seq_no);

CREATE INDEX lines_hs_code_idx
    ON customs.declaration_line_items (hs_code, origin_country);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0019_customs_declarations', sha256('0019'::bytea));

COMMIT;
