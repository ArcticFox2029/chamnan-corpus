-- ---------------------------------------------------------------------------
-- 0026_analytics_reconciliation.sql
--
-- reconciliation-service की रात वाली तीन-तरफ़ा मिलान का भंडार: runs और उनसे खुली
-- discrepancies। पंक्तियाँ analytics schema में हैं पर लिखती reconciliation-service
-- है — यही एकमात्र जगह है जहाँ analytics schema derived-only नहीं रहता।
--
-- SPEC.md §2.9, §3.14, §4.17।
-- ---------------------------------------------------------------------------

BEGIN;

-- UNIQUE (tenant_id, business_date, engine_version) का मक़सद यह है कि इंजन का
-- नया संस्करण उसी दिन को दोबारा जाँच सके बिना पुराना परिणाम मिटाए — तुलना ही
-- असली मूल्य है जब कोई नया नियम जुड़ता है।
CREATE TABLE analytics.reconciliation_runs (
    run_id               TEXT        PRIMARY KEY,
    tenant_id            TEXT        NOT NULL,
    business_date        DATE        NOT NULL,
    started_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at          TIMESTAMPTZ,
    state                TEXT        NOT NULL DEFAULT 'running'
                           CHECK (state IN ('running','succeeded','failed','partial')),
    shipments_examined   INTEGER     NOT NULL DEFAULT 0,
    discrepancies_opened INTEGER     NOT NULL DEFAULT 0,
    engine_version       TEXT        NOT NULL,
    UNIQUE (tenant_id, business_date, engine_version),

    CONSTRAINT runs_id_is_prefixed_ulid
        CHECK (run_id ~ '^rec_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT runs_counters_not_negative
        CHECK (shipments_examined >= 0 AND discrepancies_opened >= 0),
    CONSTRAINT runs_finished_when_done
        CHECK ((state = 'running') = (finished_at IS NULL)),
    CONSTRAINT runs_finish_after_start
        CHECK (finished_at IS NULL OR finished_at >= started_at)
);

COMMENT ON COLUMN analytics.reconciliation_runs.engine_version IS
    'OF_RECON_ENGINE_VERSION से आता है; एक ही दिन दो संस्करणों से जाँचा जा सकता है';

-- POST /v1/runs से पहले 'क्या यह दिन पहले ही चल चुका' की जाँच।
CREATE INDEX runs_tenant_date_idx
    ON analytics.reconciliation_runs (tenant_id, business_date DESC);

-- अटकी हुई runs — रात का job विफल होने पर सुबह की पहली खोज।
CREATE INDEX runs_in_flight_idx
    ON analytics.reconciliation_runs (started_at)
    WHERE state = 'running';

-- discrepancy वह जगह है जहाँ तीन सेवाओं का सच आपस में नहीं मिलता। declaration_id
-- और invoice_id दोनों nullable हैं क्योंकि missing_declaration और missing_invoice
-- का पूरा मतलब ही उनकी अनुपस्थिति है।
CREATE TABLE analytics.reconciliation_discrepancies (
    discrepancy_id  TEXT        PRIMARY KEY,
    run_id          TEXT        NOT NULL REFERENCES analytics.reconciliation_runs(run_id),
    tenant_id       TEXT        NOT NULL,
    shipment_id     TEXT        NOT NULL,
    declaration_id  TEXT,
    invoice_id      TEXT,
    kind            TEXT        NOT NULL CHECK (kind IN
                      ('missing_declaration','missing_invoice','duty_mismatch','weight_mismatch',
                       'orphan_payment','unbilled_accessorial','cleared_without_payment')),
    expected_minor  BIGINT,
    observed_minor  BIGINT,
    currency        CHAR(3),
    state           TEXT        NOT NULL DEFAULT 'open'
                      CHECK (state IN ('open','acknowledged','resolved','waived')),
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    resolved_by     TEXT,
    resolution_note TEXT,

    CONSTRAINT discrepancies_id_is_prefixed_ulid
        CHECK (discrepancy_id ~ '^dsc_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT discrepancies_shipment_is_prefixed
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- राशि हो तो मुद्रा भी (SPEC.md §0.2); बिना मुद्रा की रक़म billing-service के
    -- hold तर्क में चुपचाप शून्य बन जाती थी।
    CONSTRAINT discrepancies_amounts_have_currency
        CHECK ((expected_minor IS NULL AND observed_minor IS NULL) OR currency IS NOT NULL),

    -- missing_declaration में declaration_id का होना अपने ही kind का खंडन है।
    CONSTRAINT discrepancies_missing_kinds_are_consistent
        CHECK ((kind <> 'missing_declaration' OR declaration_id IS NULL)
           AND (kind <> 'missing_invoice'     OR invoice_id IS NULL)),

    CONSTRAINT discrepancies_resolution_is_complete
        CHECK ((state IN ('resolved','waived')) = (resolved_at IS NOT NULL AND resolved_by IS NOT NULL))
);

COMMENT ON TABLE analytics.reconciliation_discrepancies IS
    'खुलते ही reconciliation.discrepancy.opened जाता है; billing-service invoice को on_hold कर देती है';

-- GET /v1/discrepancies?state=open&kind= — console का मुख्य प्रश्न।
CREATE INDEX discrepancies_open_idx
    ON analytics.reconciliation_discrepancies (tenant_id, kind)
    WHERE state = 'open';

CREATE INDEX discrepancies_run_idx
    ON analytics.reconciliation_discrepancies (run_id, kind);

-- billing-service उल्टी दिशा में पूछती है: 'इस invoice पर कोई खुली discrepancy है?'
CREATE INDEX discrepancies_invoice_idx
    ON analytics.reconciliation_discrepancies (invoice_id)
    WHERE invoice_id IS NOT NULL AND state IN ('open','acknowledged');

CREATE INDEX discrepancies_shipment_idx
    ON analytics.reconciliation_discrepancies (shipment_id, opened_at DESC);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0026_analytics_reconciliation', sha256('0026'::bytea));

COMMIT;
