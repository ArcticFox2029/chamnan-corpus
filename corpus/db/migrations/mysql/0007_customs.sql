-- ---------------------------------------------------------------------------
-- 0007_customs.sql
--
-- customs-service की तीन tables। सबसे कठिन अनुवाद यहीं है: PostgreSQL में
-- customs.tariff_schedules की अवधि TSTZRANGE है और उसका ओवरलैप-निषेध एक GiST
-- EXCLUDE constraint से आता है। MySQL में न range type है, न EXCLUDE — इसलिए
-- अवधि दो columns में बँटी है और निषेध trigger पर आ गया है।
--
-- SPEC.md §2.6, §3.7।
-- ---------------------------------------------------------------------------

CREATE TABLE customs.customs_declarations (
    declaration_id      VARCHAR(30) NOT NULL,
    tenant_id           VARCHAR(30) NOT NULL,
    shipment_id         VARCHAR(30) NOT NULL,   -- logical FK → freight.shipments
    crossing_id         VARCHAR(30) NOT NULL,   -- logical FK → geo.border_crossings
    customs_office_code VARCHAR(32) NOT NULL,
    broker_user_id      VARCHAR(30) NULL,
    direction           ENUM('import','export','transit') NOT NULL,
    status              ENUM('draft','submitted','under_review','held',
                             'cleared','rejected','amended') NOT NULL DEFAULT 'draft',
    mrn                 VARCHAR(32) NULL,
    filed_at            DATETIME(6) NULL,
    cleared_at          DATETIME(6) NULL,
    assessed_duty_minor BIGINT      NULL,
    assessed_vat_minor  BIGINT      NULL,
    currency            CHAR(3)     NOT NULL,
    -- सिर्फ़ billing.invoice.settled खाकर पलटता है; customs-service billing को
    -- कभी synchronously नहीं बुलाती (SPEC.md §1.2)।
    duty_paid           TINYINT(1)  NOT NULL DEFAULT 0,
    created_at          DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (declaration_id),
    UNIQUE KEY declarations_mrn (mrn),

    CONSTRAINT declaration_cleared_needs_mrn
        CHECK (status <> 'cleared' OR (mrn IS NOT NULL AND cleared_at IS NOT NULL)),
    CONSTRAINT declarations_filed_when_not_draft
        CHECK (status = 'draft' OR filed_at IS NOT NULL),
    CONSTRAINT declarations_assessment_is_complete
        CHECK ((assessed_duty_minor IS NULL) = (assessed_vat_minor IS NULL)),
    CONSTRAINT declarations_currency_is_iso4217 CHECK (currency REGEXP '^[A-Z]{3}$'),

    KEY declarations_shipment_idx (shipment_id),
    KEY declarations_cleared_unpaid_idx (tenant_id, status, duty_paid, cleared_at),
    KEY declarations_office_idx (customs_office_code, filed_at)
) ENGINE = InnoDB;

-- अवधि। PostgreSQL में एक TSTZRANGE column; यहाँ दो DATETIME(6), जिनमें
-- valid_until NULL का मतलब 'अभी तक खुली' है। तुलना का अर्थ वही रखा गया है:
-- [valid_from, valid_until) — यानी शुरुआत शामिल, अंत बाहर। यह चुनाव इसलिए है कि
-- एक दर ठीक उसी क्षण ख़त्म होकर अगली शुरू हो सके जिस क्षण आदेश लागू होता है।
CREATE TABLE customs.tariff_schedules (
    tariff_id           VARCHAR(30) NOT NULL,
    hs_code             CHAR(10)    NOT NULL,
    destination_country CHAR(2)     NOT NULL,
    origin_country      CHAR(2)     NULL,   -- NULL = किसी भी मूल पर लागू
    duty_rate_bp        INT         NOT NULL,   -- basis points, SPEC.md §0.2
    vat_rate_bp         INT         NOT NULL,
    preferential_scheme VARCHAR(64) NULL,
    valid_from          DATETIME(6) NOT NULL,
    valid_until         DATETIME(6) NULL,
    superseded_by       VARCHAR(30) NULL,
    source_document_id  VARCHAR(30) NULL,
    recorded_at         DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    -- ओवरलैप-निषेध की कुंजी में origin_country चाहिए, पर NULL यहाँ 'किसी भी मूल'
    -- का अर्थ रखता है और NULL आपस में बराबर नहीं होते। PostgreSQL में इसका हल
    -- `coalesce(origin_country, '**')` था; यहाँ वही coalesce एक generated column
    -- में जमा है ताकि trigger और index दोनों उसे इस्तेमाल कर सकें।
    origin_key CHAR(2) GENERATED ALWAYS AS (COALESCE(origin_country, '**')) STORED,

    PRIMARY KEY (tariff_id),

    CONSTRAINT tariffs_hs_code_is_numeric CHECK (hs_code REGEXP '^[0-9]{10}$'),
    CONSTRAINT tariffs_rates_not_negative CHECK (duty_rate_bp >= 0 AND vat_rate_bp >= 0),
    CONSTRAINT tariffs_rates_are_plausible
        CHECK (duty_rate_bp <= 50000 AND vat_rate_bp <= 10000),
    CONSTRAINT tariffs_period_is_forward
        CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT tariffs_no_self_supersede CHECK (superseded_by <> tariff_id),
    CONSTRAINT tariffs_supersede_fk FOREIGN KEY (superseded_by)
        REFERENCES customs.tariff_schedules (tariff_id),

    -- यही index वह है जिस पर नीचे वाला trigger ओवरलैप ढूँढ़ता है, और वही
    -- GET /v1/tariffs/lookup का रास्ता भी है।
    KEY tariffs_lookup_idx (hs_code, destination_country, origin_key, valid_from, valid_until)
) ENGINE = InnoDB
  COMMENT = 'अपरिवर्तनीय पंक्तियाँ; बदलाव खुली अवधि बंद करके उत्तराधिकारी डालता है';

DELIMITER $$

-- EXCLUDE की जगह। इसकी सीमा वही है जो fleet.vehicle_assignments पर थी: trigger
-- पहले पढ़ता है फिर लिखता है, इसलिए दो समानांतर insert दोनों को खाली दिख सकते
-- हैं। tariff आयात एक ही batch job से होता है (आदेश महीने में एकाध बार आता है),
-- इसलिए व्यवहार में यह जोखिम शून्य के बराबर है — पर यह संयोग है, गारंटी नहीं,
-- और उसी वजह से आयात script table-स्तर पर LOCK लेती है।
CREATE TRIGGER tariff_schedules_no_overlap_bi
BEFORE INSERT ON customs.tariff_schedules
FOR EACH ROW
BEGIN
    DECLARE clashing INT DEFAULT 0;

    SELECT COUNT(*) INTO clashing
      FROM customs.tariff_schedules
     WHERE hs_code = NEW.hs_code
       AND destination_country = NEW.destination_country
       AND origin_key = COALESCE(NEW.origin_country, '**')
       AND NEW.valid_from < COALESCE(valid_until, '9999-12-31 00:00:00')
       AND valid_from < COALESCE(NEW.valid_until, '9999-12-31 00:00:00');

    IF clashing > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'tariff period overlaps an existing schedule row';
    END IF;
END$$

-- अपरिवर्तनीयता (SPEC.md §7 नियम 6)। सिर्फ़ superseded_by और valid_until भरने की
-- छूट है — वही उत्तराधिकार का धागा है।
CREATE TRIGGER tariff_schedules_immutable_bu
BEFORE UPDATE ON customs.tariff_schedules
FOR EACH ROW
BEGIN
    IF NEW.hs_code <> OLD.hs_code
       OR NEW.destination_country <> OLD.destination_country
       OR NOT (NEW.origin_key <=> OLD.origin_key)
       OR NEW.duty_rate_bp <> OLD.duty_rate_bp
       OR NEW.vat_rate_bp <> OLD.vat_rate_bp
       OR NEW.valid_from <> OLD.valid_from THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'tariff row is immutable; insert a successor instead';
    END IF;
END$$

CREATE TRIGGER tariff_schedules_no_delete_bd
BEFORE DELETE ON customs.tariff_schedules
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'customs.tariff_schedules rows cannot be deleted';
END$$

DELIMITER ;

CREATE TABLE customs.declaration_line_items (
    line_id             VARCHAR(30)   NOT NULL,
    declaration_id      VARCHAR(30)   NOT NULL,
    seq_no              SMALLINT      NOT NULL,
    hs_code             CHAR(10)      NOT NULL,
    description         VARCHAR(512)  NOT NULL,
    origin_country      CHAR(2)       NOT NULL,
    quantity            DECIMAL(14,3) NOT NULL,
    unit                ENUM('KGM','PCE','LTR','MTQ','MTR','TNE','SET','PR','NAR') NOT NULL,
    net_weight_kg       DECIMAL(12,3) NOT NULL,
    customs_value_minor BIGINT        NOT NULL,
    -- assessment के समय की ठीक वही tariff पंक्ति, जमा दी गई।
    tariff_id           VARCHAR(30)   NULL,
    duty_minor          BIGINT        NULL,
    PRIMARY KEY (line_id),
    UNIQUE KEY lines_declaration_seq (declaration_id, seq_no),

    CONSTRAINT lines_hs_code_is_numeric CHECK (hs_code REGEXP '^[0-9]{10}$'),
    CONSTRAINT lines_quantity_is_positive CHECK (quantity > 0),
    CONSTRAINT lines_weight_not_negative CHECK (net_weight_kg >= 0),
    CONSTRAINT lines_value_not_negative CHECK (customs_value_minor >= 0),
    CONSTRAINT lines_seq_starts_at_one CHECK (seq_no >= 1),

    CONSTRAINT lines_declaration_fk FOREIGN KEY (declaration_id)
        REFERENCES customs.customs_declarations (declaration_id) ON DELETE CASCADE,
    -- PostgreSQL शाखा में यह forward reference थी और अलग ALTER में जुड़ती थी;
    -- यहाँ tariff_schedules ऊपर ही बन चुकी है, इसलिए सीधे घोषित है।
    CONSTRAINT lines_tariff_fk FOREIGN KEY (tariff_id)
        REFERENCES customs.tariff_schedules (tariff_id),

    KEY lines_hs_code_idx (hs_code, origin_country),
    KEY lines_tariff_idx (tariff_id)
) ENGINE = InnoDB;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0007_customs', UNHEX(SHA2('0007', 256)));
