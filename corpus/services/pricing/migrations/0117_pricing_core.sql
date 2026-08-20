-- ============================================================================
-- 0117_pricing_core.sql
--
-- สร้างสคีมา `pricing` กับตารางฝั่ง "ราคาตั้ง" และตารางใบเสนอราคา ซึ่งเป็นชุดตารางที่
-- pricing-service เป็นเจ้าของแต่ผู้เดียว เลขลำดับเดินต่อจากชุดของแพลตฟอร์มใน `db/migrations/`
-- (0101–0116 คือรุ่นก่อนหน้าของสคีมานี้ตอนที่ยังอยู่ในความดูแลของ billing-service)
--
-- ตารางทั้งหมดในไฟล์นี้ยึดกติกาเดียวกับ SPEC §0.2: เงินเป็นจำนวนเต็มหน่วยย่อยคู่กับ
-- คอลัมน์ currency, อัตราเป็น basis point, ระยะทางเป็นเมตร และไม่มีคอลัมน์ทศนิยมลอยตัว
-- แม้แต่คอลัมน์เดียวในสายราคา
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS pricing;

-- ชุดราคาหนึ่งชุด มีผลเป็นช่วงวันที่ ไม่เคยถูกแก้ทับ — การขึ้นราคาคือปิดช่วงเดิมแล้ว
-- insert ชุดใหม่ วิธีเดียวกับ customs.tariff_schedules ใน SPEC §2.6
CREATE TABLE pricing.rate_cards (
    rate_card_id      TEXT        PRIMARY KEY,             -- rcd_<ULID>
    tenant_id         TEXT        NOT NULL,                -- logical FK ไป identity.tenants
    carrier_id        TEXT,                                -- logical FK ไป fleet.carriers, NULL = ทุกราย
    name              TEXT        NOT NULL,
    currency          CHAR(3)     NOT NULL,
    priority          SMALLINT    NOT NULL DEFAULT 100,    -- เลขน้อยชนะเมื่อหลายชุดซ้อนกัน
    effective_from_on DATE        NOT NULL,
    effective_to_on   DATE,
    approved_by       TEXT,                                -- usr_… ผู้อนุมัติจากคอนโซล
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at        TIMESTAMPTZ,
    UNIQUE (tenant_id, name, effective_from_on),
    CONSTRAINT rate_cards_period_is_forward_chk
        CHECK (effective_to_on IS NULL OR effective_to_on > effective_from_on)
);
CREATE INDEX rate_cards_active_idx ON pricing.rate_cards (tenant_id, priority)
    WHERE retired_at IS NULL;

-- หนึ่งคู่ท่า หนึ่งโหมด ต่อหนึ่งชุดราคา ท่าอ้างด้วย UN/LOCODE ห้าตัวอักษรเหมือนที่
-- freight.facilities.unlocode ใช้ เพื่อให้จับคู่กับ analytics.mv_lane_performance_daily ได้ตรง
CREATE TABLE pricing.rate_card_lanes (
    lane_id                  TEXT     PRIMARY KEY,         -- rln_<ULID>
    rate_card_id             TEXT     NOT NULL
                               REFERENCES pricing.rate_cards(rate_card_id) ON DELETE CASCADE,
    origin_unlocode          CHAR(5)  NOT NULL,
    destination_unlocode     CHAR(5)  NOT NULL,
    mode                     TEXT     NOT NULL,            -- ตรงกับ routing.route_legs.mode
    base_minor               BIGINT   NOT NULL,
    per_km_minor             BIGINT   NOT NULL,
    minimum_charge_minor     BIGINT   NOT NULL,
    transit_days             SMALLINT NOT NULL,
    equipment_multipliers_bp JSONB    NOT NULL DEFAULT '{}'::jsonb,
    is_active                BOOLEAN  NOT NULL DEFAULT true,
    UNIQUE (rate_card_id, origin_unlocode, destination_unlocode, mode),
    CONSTRAINT lanes_endpoints_differ_chk CHECK (origin_unlocode <> destination_unlocode),
    CONSTRAINT lanes_mode_is_known_chk
        CHECK (mode IN ('road','rail','sea','air','barge'))
);
CREATE INDEX rate_card_lanes_lane_idx
    ON pricing.rate_card_lanes (origin_unlocode, destination_unlocode, mode);

-- ขั้นน้ำหนัก [from_kg, to_kg) — ขั้นสุดท้ายเปิดปลายด้วย to_kg IS NULL เสมอ
-- engine จะปฏิเสธชุดที่มีช่องโหว่ตั้งแต่ก่อนคิดราคา ไม่ใช่คิดเป็นศูนย์แล้วปล่อยผ่าน
CREATE TABLE pricing.rate_breaks (
    break_id      TEXT     PRIMARY KEY,                    -- rbk_<ULID>
    lane_id       TEXT     NOT NULL
                    REFERENCES pricing.rate_card_lanes(lane_id) ON DELETE CASCADE,
    from_kg       INTEGER  NOT NULL,
    to_kg         INTEGER,
    multiplier_bp INTEGER  NOT NULL,
    UNIQUE (lane_id, from_kg),
    CONSTRAINT rate_breaks_range_is_forward_chk CHECK (to_kg IS NULL OR to_kg > from_kg),
    CONSTRAINT rate_breaks_multiplier_is_positive_chk CHECK (multiplier_bp > 0)
);

-- charge_code ถูกล็อกไว้ให้ตรงกับ CHECK บน billing.invoice_lines.charge_code ทุกค่า
-- ถ้ารายการสองฝั่งไม่ตรงกัน ใบเสนอราคาจะสร้างบรรทัดที่ billing-service ปฏิเสธตอน POST
-- /v1/invoices/{invoice_id}/lines ซึ่งจะไปโผล่เป็น 422 ที่ปลายทางแทนที่จะดังตรงนี้
CREATE TABLE pricing.surcharge_rules (
    rule_id      TEXT     PRIMARY KEY,                     -- srg_<ULID>
    rate_card_id TEXT     NOT NULL
                   REFERENCES pricing.rate_cards(rate_card_id) ON DELETE CASCADE,
    charge_code  TEXT     NOT NULL,
    basis        TEXT     NOT NULL,
    amount_minor BIGINT   NOT NULL DEFAULT 0,
    rate_bp      INTEGER  NOT NULL DEFAULT 0,
    free_units   INTEGER  NOT NULL DEFAULT 0,
    cap_minor    BIGINT,
    applies_when TEXT     NOT NULL DEFAULT 'always',
    sort_order   SMALLINT NOT NULL DEFAULT 100,
    UNIQUE (rate_card_id, charge_code, applies_when),
    CONSTRAINT surcharge_charge_code_matches_billing_chk CHECK (charge_code IN
        ('linehaul','fuel_surcharge','demurrage','detention','reefer_power',
         'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')),
    CONSTRAINT surcharge_basis_is_known_chk CHECK (basis IN
        ('flat','per_container','per_leg','per_km','per_hour','per_day','percent_of_linehaul')),
    CONSTRAINT surcharge_amounts_non_negative_chk CHECK (amount_minor >= 0 AND rate_bp >= 0),
    CONSTRAINT surcharge_cap_above_amount_chk CHECK (cap_minor IS NULL OR cap_minor >= amount_minor)
);

-- ใบเสนอราคา — shipment_id เป็น NULL ได้เพราะฝ่ายขายขอราคาก่อนจะมี shipment จริงเสมอ
-- superseded_by_quote_id ทำให้การคิดราคาใหม่เป็นการ "เพิ่มแถว" ตามกติกา §7.6
CREATE TABLE pricing.quotes (
    quote_id             TEXT        PRIMARY KEY,          -- quo_<ULID>
    tenant_id            TEXT        NOT NULL,
    shipment_id          TEXT,                             -- logical FK ไป freight.shipments
    rate_card_id         TEXT        NOT NULL REFERENCES pricing.rate_cards(rate_card_id),
    lane_id              TEXT        REFERENCES pricing.rate_card_lanes(lane_id),
    route_id             TEXT,                             -- logical FK ไป routing.routes
    route_version        INTEGER,
    strategy             TEXT        NOT NULL DEFAULT 'cheapest',
    status               TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                           ('draft','issued','accepted','expired','superseded','rejected')),
    currency             CHAR(3)     NOT NULL,
    subtotal_minor       BIGINT      NOT NULL DEFAULT 0,
    duty_estimate_minor  BIGINT      NOT NULL DEFAULT 0,
    tax_estimate_minor   BIGINT      NOT NULL DEFAULT 0,
    total_minor          BIGINT      NOT NULL DEFAULT 0,
    billable_distance_m  BIGINT      NOT NULL DEFAULT 0,
    chargeable_weight_kg INTEGER     NOT NULL DEFAULT 0,
    demand_uplift_bp     INTEGER     NOT NULL DEFAULT 0,
    fx_rate_micros       BIGINT,
    fx_rate_recorded_at  TIMESTAMPTZ,
    fx_source            TEXT,
    rating_inputs        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    issued_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until_at       TIMESTAMPTZ NOT NULL,
    accepted_at          TIMESTAMPTZ,
    accepted_by          TEXT,
    superseded_by_quote_id TEXT      REFERENCES pricing.quotes(quote_id),
    invoice_id           TEXT,                             -- logical FK ไป billing.invoices
    idempotency_key      TEXT,
    trace_id             CHAR(32),
    engine_version       TEXT        NOT NULL,
    UNIQUE (tenant_id, idempotency_key),
    CONSTRAINT quote_total_is_consistent_chk
        CHECK (total_minor = subtotal_minor + duty_estimate_minor + tax_estimate_minor),
    CONSTRAINT quote_validity_is_forward_chk CHECK (valid_until_at > issued_at),
    CONSTRAINT quote_accepted_needs_timestamp_chk
        CHECK (status <> 'accepted' OR accepted_at IS NOT NULL)
);
CREATE INDEX quotes_open_for_shipment_idx ON pricing.quotes (shipment_id)
    WHERE status IN ('issued','accepted');

-- หนึ่งบรรทัดที่ billing-service คัดลอกไปเป็นหนึ่งแถวใน billing.invoice_lines ได้ตรง ๆ
-- quantity_milli เก็บจำนวนคูณพัน เพราะปลายทางเป็น NUMERIC(12,3) และการส่งทศนิยมลอยตัว
-- ระหว่างทางคือจุดที่เศษสตางค์เคยหายไปหนึ่งครั้งในรอบปิดบัญชีเดือนมีนาคม
CREATE TABLE pricing.quote_lines (
    quote_line_id    TEXT     PRIMARY KEY,                 -- qln_<ULID>
    quote_id         TEXT     NOT NULL
                       REFERENCES pricing.quotes(quote_id) ON DELETE CASCADE,
    seq_no           SMALLINT NOT NULL,
    charge_code      TEXT     NOT NULL,
    description      TEXT     NOT NULL,
    quantity_milli   INTEGER  NOT NULL DEFAULT 1000,
    unit_price_minor BIGINT   NOT NULL,
    amount_minor     BIGINT   NOT NULL,
    source_kind      TEXT,
    source_id        TEXT,
    rule_id          TEXT     REFERENCES pricing.surcharge_rules(rule_id),
    UNIQUE (quote_id, seq_no),
    CONSTRAINT quote_lines_charge_code_matches_billing_chk CHECK (charge_code IN
        ('linehaul','fuel_surcharge','demurrage','detention','reefer_power',
         'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')),
    CONSTRAINT quote_lines_source_kind_matches_billing_chk CHECK (source_kind IS NULL OR
        source_kind IN ('leg','alert','declaration','assignment','manual'))
);
CREATE INDEX quote_lines_quote_idx ON pricing.quote_lines (quote_id);

COMMIT;
