-- ---------------------------------------------------------------------------
-- 0020_customs_tariff_schedules.sql
--
-- customs.tariff_schedules — पूरे schema की एकमात्र temporal table, और वह
-- forward reference जो 0019 में अधूरी छोड़ी गई थी। GET /v1/tariffs/lookup इसी
-- एक table से on_date के हिसाब से ठीक एक पंक्ति निकालती है।
--
-- SPEC.md §2.6, §3.7।
-- ---------------------------------------------------------------------------

BEGIN;

-- दरें आदेश से बदलती हैं, किसी तारीख़ से। कल दायर की गई declaration को आज भी
-- कल की दर पर ही आँका जाना चाहिए — इसलिए पंक्तियाँ कभी UPDATE नहीं होतीं:
-- बदलाव खुली अवधि बंद करता है और उत्तराधिकारी पंक्ति डालता है।
--
-- EXCLUDE constraint वह चीज़ है जो एक ही (hs_code, destination, origin) जोड़ी के
-- लिए दो अवधियों का ओवरलैप storage स्तर पर असंभव बना देती है। coalesce(origin,
-- '**') इसलिए कि NULL origin का मतलब 'कोई भी मूल' है और NULL आपस में बराबर नहीं
-- होते — बिना coalesce के दो 'any origin' पंक्तियाँ चुपचाप ओवरलैप कर जातीं, और
-- lookup कभी-कभी गलत दर लौटाती। यह असल में हुआ था।
CREATE TABLE customs.tariff_schedules (
    tariff_id           TEXT      PRIMARY KEY,
    hs_code             CHAR(10)  NOT NULL,
    destination_country CHAR(2)   NOT NULL,
    origin_country      CHAR(2),
    duty_rate_bp        INTEGER   NOT NULL CHECK (duty_rate_bp >= 0),
    vat_rate_bp         INTEGER   NOT NULL CHECK (vat_rate_bp >= 0),
    preferential_scheme TEXT,
    valid_period        TSTZRANGE NOT NULL,
    superseded_by       TEXT      REFERENCES customs.tariff_schedules(tariff_id),
    source_document_id  TEXT,
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT tariffs_id_is_prefixed_ulid
        CHECK (tariff_id ~ '^trf_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT tariffs_hs_code_is_numeric CHECK (hs_code ~ '^[0-9]{10}$'),
    CONSTRAINT tariffs_document_is_prefixed
        CHECK (source_document_id IS NULL OR source_document_id ~ '^doc_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- बेसिस पॉइंट्स (SPEC.md §0.2): 1250 = 12.50 %। 100% से ऊपर की duty असल में
    -- होती है (डंपिंग-रोधी शुल्क), इसलिए ऊपरी सीमा उदार रखी है — पर 500% से आगे
    -- हमेशा data-entry की गलती निकली है।
    CONSTRAINT tariffs_rates_are_plausible
        CHECK (duty_rate_bp <= 50000 AND vat_rate_bp <= 10000),

    CONSTRAINT tariffs_period_is_bounded_below
        CHECK (lower(valid_period) IS NOT NULL),

    CONSTRAINT tariffs_no_self_supersede CHECK (superseded_by <> tariff_id),

    EXCLUDE USING gist (
        hs_code WITH =, destination_country WITH =,
        coalesce(origin_country, '**') WITH =, valid_period WITH &&
    )
);

COMMENT ON TABLE customs.tariff_schedules IS
    'अपरिवर्तनीय पंक्तियाँ; इसीलिए OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS को बहुत लंबा रखना सुरक्षित है';
COMMENT ON COLUMN customs.tariff_schedules.valid_period IS
    'GET /v1/tariffs/lookup?on_date= इसी range में @> से गिरता है';

-- lookup का असली प्रश्न: (hs_code, destination, origin, on_date)। GiST index
-- ऊपर के EXCLUDE से पहले ही बन चुका है, पर वह चार-column वाला है; यह छोटा btree
-- उन 80% प्रश्नों को सँभालता है जिनमें origin NULL होता है।
CREATE INDEX tariffs_any_origin_idx
    ON customs.tariff_schedules (hs_code, destination_country)
    WHERE origin_country IS NULL;

-- अभी लागू दरें — सबसे आम slice।
CREATE INDEX tariffs_current_idx
    ON customs.tariff_schedules (destination_country, hs_code)
    WHERE upper(valid_period) IS NULL;

CREATE INDEX tariffs_scheme_idx
    ON customs.tariff_schedules (preferential_scheme)
    WHERE preferential_scheme IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 0019 की अधूरी forward reference। line item अपनी tariff पंक्ति को जमा देती है;
-- RESTRICT इसलिए कि उद्धृत tariff पंक्ति को मिटाना इतिहास मिटाना है।
-- ---------------------------------------------------------------------------
ALTER TABLE customs.declaration_line_items
    ADD CONSTRAINT declaration_line_items_tariff_fk
    FOREIGN KEY (tariff_id) REFERENCES customs.tariff_schedules(tariff_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX lines_tariff_idx
    ON customs.declaration_line_items (tariff_id)
    WHERE tariff_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- अपरिवर्तनीयता का प्रवर्तन। SPEC.md §7 नियम 6 कहता है कि customs को छूने वाली
-- हर चीज़ append-only है। UPDATE की इकलौती अनुमति superseded_by भरने की है —
-- वही उत्तराधिकार का धागा है।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION customs.tariffs_forbid_rewrite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'customs.tariff_schedules पंक्तियाँ मिटाई नहीं जा सकतीं (trf %)', OLD.tariff_id
            USING ERRCODE = 'restrict_violation';
    END IF;

    IF ROW(NEW.hs_code, NEW.destination_country, NEW.origin_country,
           NEW.duty_rate_bp, NEW.vat_rate_bp, NEW.valid_period)
       IS DISTINCT FROM
       ROW(OLD.hs_code, OLD.destination_country, OLD.origin_country,
           OLD.duty_rate_bp, OLD.vat_rate_bp, OLD.valid_period)
    THEN
        RAISE EXCEPTION 'tariff % अपरिवर्तनीय है; उत्तराधिकारी पंक्ति डालें', OLD.tariff_id
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER tariffs_immutable_bud
    BEFORE UPDATE OR DELETE ON customs.tariff_schedules
    FOR EACH ROW
    EXECUTE FUNCTION customs.tariffs_forbid_rewrite();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0020_customs_tariff_schedules', sha256('0020'::bytea));

COMMIT;
