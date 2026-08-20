-- ============================================================================
-- 0118_market_data_and_seen_set.sql
--
-- ตารางข้อมูลตลาด (อัตราแลกเปลี่ยน, ดัชนีน้ำมัน, สถิติอุปสงค์) กับ seen-set ของ event
-- ที่ทำให้ consumer ของเรา idempotent ตาม §4.19 ข้อ 1
--
-- นี่คือหมายเลข migration ที่โค้ดรุ่นนี้คาดหวัง — ค่าเดียวกับ EXPECTED_SCHEMA_MIGRATION
-- ใน `src/pricing_service/__init__.py` และเป็นตัวเลขที่ `GET /version` ตอบกลับไป
-- ถ้าสองที่ไม่ตรงกัน แปลว่า pod ถูก deploy คนละรุ่นกับฐานข้อมูล
-- ============================================================================

BEGIN;

-- อัตราแลกเปลี่ยนเก็บเป็น micro-unit จำนวนเต็ม และเก็บทิศเดียว
-- (engine กลับด้านเอง) เพื่อไม่ให้มีสองแถวที่ปัดเศษไม่ตรงกันแล้วกลายเป็นกำไรปลอมตอน round-trip
CREATE TABLE pricing.fx_rates (
    fx_rate_id     TEXT        PRIMARY KEY,                -- fxr_<ULID>
    base_currency  CHAR(3)     NOT NULL,
    quote_currency CHAR(3)     NOT NULL,
    rate_micros    BIGINT      NOT NULL,
    source         TEXT        NOT NULL,                   -- ค่าจาก OF_PRICING_FX_RATE_SOURCE
    observed_at    TIMESTAMPTZ NOT NULL,
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (base_currency, quote_currency, source, observed_at),
    CONSTRAINT fx_rate_is_positive_chk CHECK (rate_micros > 0),
    CONSTRAINT fx_pair_is_distinct_chk CHECK (base_currency <> quote_currency)
);
CREATE INDEX fx_rates_lookup_idx
    ON pricing.fx_rates (base_currency, quote_currency, observed_at DESC);

-- ดัชนีน้ำมันรายสัปดาห์ต่อภูมิภาคของ §0.6 — ค่าธรรมเนียมคิดจากส่วนต่างกับ
-- OF_PRICING_FUEL_BASELINE_INDEX_MICROS ไม่ใช่จากค่าดิบ
CREATE TABLE pricing.fuel_index_points (
    point_id     TEXT        PRIMARY KEY,                  -- fip_<ULID>
    region_code  TEXT        NOT NULL,
    source       TEXT        NOT NULL,
    effective_on DATE        NOT NULL,
    index_micros BIGINT      NOT NULL,
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (region_code, source, effective_on),
    CONSTRAINT fuel_index_is_positive_chk CHECK (index_micros > 0),
    CONSTRAINT fuel_index_region_is_known_chk CHECK (region_code IN
        ('eu-west','eu-central','na-east','na-west','apac-sg','apac-jp','latam-br','mea-ae'))
);

-- วัตถุดิบของโมเดลอุปสงค์ เติมโดยงาน Celery `pricing.ingest_demand` ที่อ่าน
-- analytics.mv_lane_performance_daily ผ่าน GET /v1/metrics/lane-performance ของ
-- analytics-pipeline — ไม่มีการ query สคีมา analytics ตรง ๆ จากที่นี่ (§7.2)
CREATE TABLE pricing.demand_observations (
    observation_id       TEXT        PRIMARY KEY,          -- dmo_<ULID>
    tenant_id            TEXT        NOT NULL,
    origin_unlocode      CHAR(5)     NOT NULL,
    destination_unlocode CHAR(5)     NOT NULL,
    business_date        DATE        NOT NULL,
    booked_count         INTEGER     NOT NULL DEFAULT 0,
    capacity_slots       INTEGER,
    quoted_count         INTEGER     NOT NULL DEFAULT 0,
    accepted_count       INTEGER     NOT NULL DEFAULT 0,
    avg_transit_seconds  BIGINT,
    recorded_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, origin_unlocode, destination_unlocode, business_date),
    CONSTRAINT demand_counts_non_negative_chk CHECK (booked_count >= 0 AND accepted_count >= 0),
    CONSTRAINT demand_capacity_is_positive_chk CHECK (capacity_slots IS NULL OR capacity_slots > 0)
);
CREATE INDEX demand_recent_idx
    ON pricing.demand_observations (origin_unlocode, destination_unlocode, business_date DESC);

CREATE TABLE pricing.repricing_runs (
    run_id             TEXT        PRIMARY KEY,            -- rpr_<ULID>
    tenant_id          TEXT        NOT NULL,
    trigger            TEXT        NOT NULL,
    rate_card_id       TEXT        REFERENCES pricing.rate_cards(rate_card_id),
    state              TEXT        NOT NULL DEFAULT 'running',
    quotes_examined    INTEGER     NOT NULL DEFAULT 0,
    quotes_superseded  INTEGER     NOT NULL DEFAULT 0,
    total_delta_minor  BIGINT      NOT NULL DEFAULT 0,
    delta_currency     CHAR(3),
    max_uplift_bp_seen INTEGER     NOT NULL DEFAULT 0,
    engine_version     TEXT        NOT NULL,
    started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at        TIMESTAMPTZ,
    last_error         TEXT,
    UNIQUE (tenant_id, trigger, started_at),
    CONSTRAINT repricing_state_is_known_chk
        CHECK (state IN ('running','succeeded','failed','partial'))
);

-- seen-set ของ event_id ตาม §4.19 ข้อ 1 ต้องอยู่นานกว่า retention ของหัวข้อที่ยาวที่สุด
-- ที่เราฟัง (90 วัน ของ of.customs.v1 และ of.billing.v1) งานกวาดอยู่ใน
-- workers/tasks_repricing.py: `pricing.prune_consumed_events`
CREATE TABLE pricing.consumed_events (
    event_id    TEXT        PRIMARY KEY,                   -- evt_<ULID> จากซอง §0.7
    event_name  TEXT        NOT NULL,
    consumed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    handler     TEXT        NOT NULL
);
CREATE INDEX consumed_events_age_idx ON pricing.consumed_events (consumed_at);

-- pricing-service เขียน platform.outbox_messages ร่วมกับเซอร์วิสอื่นโดยแยกด้วยคอลัมน์
-- producer ดัชนีบางส่วนตัวนี้ทำให้ relay ของเราไม่ต้องไถแถวของ document-service และ
-- notification-service ที่อยู่ตารางเดียวกัน
CREATE INDEX IF NOT EXISTS outbox_pending_pricing_idx
    ON platform.outbox_messages (created_at)
    WHERE producer = 'pricing-service' AND published_at IS NULL;

COMMIT;
