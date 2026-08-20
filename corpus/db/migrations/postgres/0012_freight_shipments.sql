-- ---------------------------------------------------------------------------
-- 0012_freight_shipments.sql
--
-- freight.shipments — पूरे platform की केंद्रीय इकाई। routing, customs, billing
-- और reconciliation सब इसी id के इर्द-गिर्द बने हैं, और SPEC.md §4 की एकमात्र
-- ordering guarantee यही है कि shipment_id पर keyed हर event क्रम में आता है।
--
-- SPEC.md §2.3। स्थिति बदलने का इकलौता क़ानूनी रास्ता
-- PATCH /v1/shipments/{shipment_id}/status है।
-- ---------------------------------------------------------------------------

BEGIN;

-- status की सूची बंद है और उसका क्रम मायने रखता है: draft → booked → sealed →
-- in_transit → delivered, बीच में at_risk और held_at_customs दोनों वापसी योग्य
-- अवस्थाएँ हैं। at_risk telemetry.alert.raised खाकर लगती है, held_at_customs
-- customs.declaration.filed के बाद।
--
-- declared_value_minor + currency की जोड़ी SPEC.md §0.2 का नियम है — कोई भी राशि
-- अपनी मुद्रा के बिना नहीं रहती, और कभी float नहीं होती।
CREATE TABLE freight.shipments (
    shipment_id             TEXT        PRIMARY KEY,
    tenant_id               TEXT        NOT NULL,
    reference               TEXT        NOT NULL,
    origin_facility_id      TEXT        NOT NULL REFERENCES freight.facilities(facility_id),
    destination_facility_id TEXT        NOT NULL REFERENCES freight.facilities(facility_id),
    incoterm                CHAR(3)     NOT NULL,
    status                  TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                              ('draft','booked','sealed','in_transit','at_risk','held_at_customs',
                               'delivered','cancelled')),
    sla_deadline_at         TIMESTAMPTZ,
    declared_value_minor    BIGINT      NOT NULL DEFAULT 0,
    currency                CHAR(3)     NOT NULL,
    region_code             TEXT        NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at            TIMESTAMPTZ,

    -- ग्राहक की अपनी booking reference; tenant के भीतर अनूठी, विश्व में नहीं।
    UNIQUE (tenant_id, reference),

    CONSTRAINT shipments_id_is_prefixed_ulid
        CHECK (shipment_id ~ '^shp_[0-9A-HJKMNP-TV-Z]{26}$'),

    CONSTRAINT shipments_endpoints_differ
        CHECK (origin_facility_id <> destination_facility_id),

    CONSTRAINT shipments_incoterm_is_uppercase CHECK (incoterm ~ '^[A-Z]{3}$'),
    CONSTRAINT shipments_currency_is_iso4217 CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT shipments_value_not_negative CHECK (declared_value_minor >= 0),

    CONSTRAINT shipments_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),

    -- delivered_at और status का एक-दूसरे से सहमत रहना ज़रूरी है: analytics की
    -- mv_lane_performance_daily सिर्फ़ status='delivered' पंक्तियाँ लेती है और
    -- delivered_at से transit समय गिनती है। NULL वहाँ पूरी lane को ख़राब करता था।
    CONSTRAINT shipments_delivered_has_timestamp
        CHECK ((status = 'delivered') = (delivered_at IS NOT NULL))
);

COMMENT ON TABLE freight.shipments IS
    'container-registry की मालिकाना table; POST /v1/shipments बनाती है और shipment.created प्रकाशित करती है';
COMMENT ON COLUMN freight.shipments.status IS
    'बदलाव सिर्फ़ PATCH /v1/shipments/{shipment_id}/status से; हर बदलाव shipment.status.changed भेजता है';

-- खुली shipments कुल का छोटा हिस्सा हैं पर हर console screen उन्हीं को माँगती है।
CREATE INDEX shipments_open_idx
    ON freight.shipments (tenant_id, status)
    WHERE status NOT IN ('delivered','cancelled');

-- SLA breach वाला sweep: वे shipments जिनकी समय-सीमा निकल रही है और जो अभी
-- पहुँची नहीं। notification-service इसी से shipment_delayed template भेजती है।
CREATE INDEX shipments_sla_watch_idx
    ON freight.shipments (sla_deadline_at)
    WHERE sla_deadline_at IS NOT NULL AND delivered_at IS NULL
      AND status NOT IN ('delivered','cancelled');

-- analytics-pipeline रोज़ 03:15 UTC पर पिछले दिन की delivered shipments उठाती है।
CREATE INDEX shipments_delivered_day_idx
    ON freight.shipments (tenant_id, delivered_at)
    WHERE status = 'delivered';

-- Lane विश्लेषण origin+destination की जोड़ी से चलता है।
CREATE INDEX shipments_lane_idx
    ON freight.shipments (origin_facility_id, destination_facility_id);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0012_freight_shipments', sha256('0012'::bytea));

COMMIT;
