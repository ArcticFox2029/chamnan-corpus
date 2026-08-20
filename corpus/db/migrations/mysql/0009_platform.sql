-- ---------------------------------------------------------------------------
-- 0009_platform.sql
--
-- platform schema की छह tables: hash-chained ledger, document शब्दावली और
-- दस्तावेज़, notifications, वरीयताएँ, और outbox। दो बोली-भेद यहाँ भारी हैं —
-- MySQL में `GENERATED ALWAYS AS IDENTITY` नहीं है (AUTO_INCREMENT है, और वह
-- rollback पर अंतराल छोड़ता है), और NOTIFY/LISTEN नहीं है, इसलिए outbox relay
-- यहाँ शुद्ध मतदान पर चलता है।
--
-- SPEC.md §2.8।
-- ---------------------------------------------------------------------------

-- entry_id AUTO_INCREMENT है। PostgreSQL के IDENTITY से एक अहम अंतर: दोनों ही
-- rollback पर अंतराल छोड़ते हैं, इसलिए hash chain का सत्यापन entry_id की सततता
-- पर नहीं, prev_entry_hash की कड़ी पर टिकता है — जो वैसे भी सही डिज़ाइन है।
-- ledger verifier (tools/) यही करता है और उसे बोली से कोई फ़र्क़ नहीं पड़ता।
CREATE TABLE platform.audit_ledger_entries (
    entry_id        BIGINT       NOT NULL AUTO_INCREMENT,
    tenant_id       VARCHAR(30)  NOT NULL,
    actor_kind      ENUM('user','service','device','partner','system') NOT NULL,
    actor_id        VARCHAR(64)  NOT NULL,
    action          VARCHAR(128) NOT NULL,   -- 'shipment.sealed', 'credential.revoked'
    subject_type    VARCHAR(64)  NOT NULL,
    subject_id      VARCHAR(64)  NOT NULL,
    payload         JSON         NOT NULL,
    trace_id        CHAR(32)     NULL,
    recorded_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    prev_entry_hash BINARY(32)   NOT NULL,   -- entry_id = 1 पर 32 शून्य बाइट
    entry_hash      BINARY(32)   NOT NULL,
    checkpoint_id   BIGINT       NULL,
    PRIMARY KEY (entry_id),
    UNIQUE KEY ledger_entry_hash (entry_hash),

    CONSTRAINT ledger_trace_is_hex CHECK (trace_id IS NULL OR trace_id REGEXP '^[0-9a-f]{32}$'),
    CONSTRAINT ledger_action_shape
        CHECK (action REGEXP '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$'),

    KEY ledger_subject_idx (subject_type, subject_id, entry_id),
    KEY ledger_tenant_time_idx (tenant_id, recorded_at),
    KEY ledger_actor_idx (actor_kind, actor_id, entry_id),
    KEY ledger_unfolded_idx (checkpoint_id, entry_id)
) ENGINE = InnoDB
  COMMENT = 'append-only; audit.v1.LedgerService/Append इकलौता लेखन-रास्ता है';

CREATE TABLE platform.ledger_checkpoints (
    checkpoint_id BIGINT     NOT NULL AUTO_INCREMENT,
    from_entry_id BIGINT     NOT NULL,
    to_entry_id   BIGINT     NOT NULL,
    merkle_root   BINARY(32) NOT NULL,
    signature     VARBINARY(128) NOT NULL,
    notarised_at  DATETIME(6) NULL,
    created_at    DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (checkpoint_id),
    UNIQUE KEY checkpoints_root (merkle_root),
    CONSTRAINT checkpoints_range_is_forward CHECK (to_entry_id >= from_entry_id),
    KEY checkpoints_pending_notary_idx (notarised_at, created_at)
) ENGINE = InnoDB;

DELIMITER $$

-- अपरिवर्तनीयता। PostgreSQL में यह BEFORE UPDATE OR DELETE का एक trigger था;
-- MySQL में एक trigger एक ही event सँभालता है, इसलिए दो लिखने पड़े। TRUNCATE का
-- कोई trigger नहीं होता — उसे रोकने का इकलौता तरीक़ा DROP/TRUNCATE अधिकार न देना
-- है, और वह deploy/ की grant फ़ाइल में है।
CREATE TRIGGER ledger_immutable_bu
BEFORE UPDATE ON platform.audit_ledger_entries
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'platform.audit_ledger_entries is append-only';
END$$

CREATE TRIGGER ledger_immutable_bd
BEFORE DELETE ON platform.audit_ledger_entries
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'platform.audit_ledger_entries is append-only';
END$$

-- कड़ी की जाँच: नई entry का prev_entry_hash मौजूदा head से मेल खाए।
CREATE TRIGGER ledger_verify_link_bi
BEFORE INSERT ON platform.audit_ledger_entries
FOR EACH ROW
BEGIN
    DECLARE head BINARY(32);

    SELECT entry_hash INTO head
      FROM platform.audit_ledger_entries
     ORDER BY entry_id DESC LIMIT 1;

    IF head IS NULL THEN
        SET head = UNHEX(REPEAT('00', 32));
    END IF;

    IF NEW.prev_entry_hash <> head THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ledger chain broken: prev_entry_hash does not match head';
    END IF;
END$$

DELIMITER ;

CREATE TABLE platform.document_owner_types (
    owner_type     VARCHAR(32)  NOT NULL,
    schema_name    VARCHAR(32)  NOT NULL,
    table_name     VARCHAR(64)  NOT NULL,
    owning_service VARCHAR(64)  NOT NULL,
    description    VARCHAR(255) NOT NULL,
    PRIMARY KEY (owner_type)
) ENGINE = InnoDB
  COMMENT = 'यही owner_type को खुला text बनने से रोकती है';

INSERT INTO platform.document_owner_types VALUES
  ('shipment',    'freight',  'shipments',            'container-registry', 'bill of lading, packing list'),
  ('container',   'freight',  'containers',           'container-registry', 'CSC plate photo, damage survey'),
  ('scan',        'freight',  'shipment_scan_events', 'container-registry', 'proof-of-delivery signature'),
  ('declaration', 'customs',  'customs_declarations', 'customs-service',    'commercial invoice, certificate of origin'),
  ('invoice',     'billing',  'invoices',             'billing-service',    'rendered PDF, credit note'),
  ('carrier',     'fleet',    'carriers',             'fleet-service',      'insurance certificate, ADR licence');

-- Diamond B (SPEC.md §1.2): UNIQUE (tenant_id, sha256, owner_type, owner_id) ही
-- वह चीज़ है जो एक ही PDF को दो बार object store में जाने से रोकती है।
CREATE TABLE platform.documents (
    document_id    VARCHAR(30)  NOT NULL,
    tenant_id      VARCHAR(30)  NOT NULL,
    owner_type     VARCHAR(32)  NOT NULL,
    owner_id       VARCHAR(64)  NOT NULL,
    kind           ENUM('bill_of_lading','commercial_invoice','packing_list',
                        'certificate_of_origin','proof_of_delivery','damage_photo',
                        'insurance_certificate','customs_decision','rendered_invoice','credit_note')
                                NOT NULL,
    storage_key    VARCHAR(512) NOT NULL,   -- region से शुरू होता है
    region_code    VARCHAR(16)  NOT NULL,
    mime_type      VARCHAR(128) NOT NULL,
    byte_size      BIGINT       NOT NULL,
    sha256         BINARY(32)   NOT NULL,
    uploaded_by    VARCHAR(64)  NOT NULL,
    uploaded_at    DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    retained_until DATE         NULL,
    deleted_at     DATETIME(6)  NULL,
    PRIMARY KEY (document_id),
    UNIQUE KEY documents_dedupe (tenant_id, sha256, owner_type, owner_id),

    CONSTRAINT documents_size_is_positive CHECK (byte_size > 0),
    CONSTRAINT documents_mime_shape CHECK (mime_type REGEXP '^[a-z]+/[A-Za-z0-9.+-]+$'),
    -- PostgreSQL में यह `storage_key LIKE region_code || '/%'` था; MySQL में
    -- CONCAT से वही लिखा जाता है और CHECK में दोनों columns देखना अनुमत है।
    CONSTRAINT documents_storage_key_is_region_prefixed
        CHECK (storage_key LIKE CONCAT(region_code, '/%')),

    CONSTRAINT documents_owner_type_fk FOREIGN KEY (owner_type)
        REFERENCES platform.document_owner_types (owner_type),
    CONSTRAINT documents_region_fk FOREIGN KEY (region_code)
        REFERENCES platform.region_codes (region_code),

    KEY documents_owner_idx (owner_type, owner_id, deleted_at),
    KEY documents_kind_idx (tenant_id, kind, uploaded_at),
    KEY documents_retention_idx (retained_until, deleted_at),
    KEY documents_sha_lookup_idx (tenant_id, sha256)
) ENGINE = InnoDB;

CREATE TABLE platform.notifications (
    notification_id   VARCHAR(30)  NOT NULL,
    tenant_id         VARCHAR(30)  NOT NULL,
    recipient_user_id VARCHAR(30)  NULL,   -- partner webhook पर NULL
    webhook_url       VARCHAR(1024) NULL,
    channel           ENUM('email','sms','push','webhook','console') NOT NULL,
    template_code     VARCHAR(64)  NOT NULL,
    source_event_id   VARCHAR(30)  NOT NULL,   -- evt_… ; retries इसी से बेअसर
    payload           JSON         NOT NULL,
    state             ENUM('queued','sending','sent','failed','suppressed')
                                   NOT NULL DEFAULT 'queued',
    attempts          SMALLINT     NOT NULL DEFAULT 0,
    queued_at         DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    sent_at           DATETIME(6)  NULL,
    failed_reason     VARCHAR(512) NULL,
    PRIMARY KEY (notification_id),

    -- यही पूरी idempotency है (SPEC.md §4.19 नियम 1)। ध्यान दें कि MySQL में
    -- कई NULL recipient_user_id आपस में नहीं टकराते — यानी webhook वाली पंक्तियों
    -- पर यह जाँच काम नहीं करती। इसलिए webhook का dedupe नीचे वाली दूसरी key से
    -- होता है, जो URL का hash लेती है।
    UNIQUE KEY notifications_idempotency (source_event_id, channel, recipient_user_id),

    webhook_fingerprint BINARY(32) GENERATED ALWAYS AS (
        CASE WHEN webhook_url IS NOT NULL
             THEN UNHEX(SHA2(CONCAT(source_event_id, '|', webhook_url), 256)) END
    ) STORED,
    UNIQUE KEY notifications_webhook_idempotency (webhook_fingerprint),

    CONSTRAINT notifications_target_is_exclusive
        CHECK ((recipient_user_id IS NULL) <> (webhook_url IS NULL)),
    CONSTRAINT notifications_webhook_channel_matches
        CHECK ((channel = 'webhook') = (webhook_url IS NOT NULL)),
    CONSTRAINT notifications_sent_has_timestamp
        CHECK ((state = 'sent') = (sent_at IS NOT NULL)),
    CONSTRAINT notifications_failed_has_reason
        CHECK (state <> 'failed' OR failed_reason IS NOT NULL),
    CONSTRAINT notifications_attempts_bounded CHECK (attempts BETWEEN 0 AND 8),

    KEY notifications_outbound_idx (state, queued_at),
    KEY notifications_audit_idx (tenant_id, state, queued_at),
    KEY notifications_recipient_idx (recipient_user_id, queued_at)
) ENGINE = InnoDB;

CREATE TABLE platform.notification_preferences (
    user_id           VARCHAR(30) NOT NULL,
    channel           ENUM('email','sms','push','webhook','console') NOT NULL,
    event_name        VARCHAR(64) NOT NULL,   -- SPEC.md §4 का नाम, या '*'
    enabled           TINYINT(1)  NOT NULL DEFAULT 1,
    quiet_hours_start TIME        NULL,
    quiet_hours_end   TIME        NULL,
    timezone          VARCHAR(64) NOT NULL DEFAULT 'UTC',
    PRIMARY KEY (user_id, channel, event_name),

    CONSTRAINT preferences_event_name_shape
        CHECK (event_name = '*' OR event_name REGEXP '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$'),
    CONSTRAINT preferences_quiet_hours_are_complete
        CHECK ((quiet_hours_start IS NULL) = (quiet_hours_end IS NULL)),

    KEY preferences_by_event_idx (event_name, channel, enabled)
) ENGINE = InnoDB;

-- Outbox। MySQL में LISTEN/NOTIFY नहीं है, इसलिए यहाँ relay शुद्ध मतदान पर चलता
-- है — OF_OUTBOX_RELAY_INTERVAL_MS = 250 वही रहता है, पर PostgreSQL शाखा वाली
-- 'तुरंत जगाने' की सुविधा नहीं मिलती और औसत latency ~125 ms ज़्यादा है।
CREATE TABLE platform.outbox_messages (
    message_id     VARCHAR(30)  NOT NULL,   -- envelope.event_id बनता है
    producer       VARCHAR(64)  NOT NULL,
    aggregate_type VARCHAR(32)  NOT NULL,
    aggregate_id   VARCHAR(64)  NOT NULL,
    event_name     VARCHAR(64)  NOT NULL,
    topic          ENUM('of.identity.v1','of.freight.v1','of.telemetry.v1',
                        'of.customs.v1','of.billing.v1','of.platform.v1') NOT NULL,
    partition_key  VARCHAR(64)  NOT NULL,
    schema_version SMALLINT     NOT NULL,
    payload        JSON         NOT NULL,
    created_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    published_at   DATETIME(6)  NULL,
    attempts       SMALLINT     NOT NULL DEFAULT 0,
    last_error     VARCHAR(1024) NULL,
    PRIMARY KEY (message_id),

    CONSTRAINT outbox_producer_is_known
        CHECK (producer IN ('identity-service','fleet-service','container-registry',
                            'telemetry-ingest','routing-service','geo-service',
                            'customs-service','billing-service','document-service',
                            'notification-service','partner-portal-api',
                            'analytics-pipeline','audit-ledger','reconciliation-service')),
    CONSTRAINT outbox_event_name_shape
        CHECK (event_name REGEXP '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$'),
    CONSTRAINT outbox_schema_version_is_positive CHECK (schema_version >= 1),
    CONSTRAINT outbox_attempts_bounded CHECK (attempts BETWEEN 0 AND 8),
    CONSTRAINT outbox_published_has_no_error
        CHECK (published_at IS NULL OR last_error IS NULL),

    -- relay का इकलौता प्रश्न। partial index न होने से यह index प्रकाशित
    -- पंक्तियों को भी ढोता है; इसलिए platform.prune_outbox() यहाँ PostgreSQL से
    -- ज़्यादा ज़रूरी है, टालने लायक़ नहीं।
    KEY outbox_pending_idx (producer, published_at, created_at),
    KEY outbox_stuck_idx (topic, attempts, created_at),
    KEY outbox_aggregate_idx (aggregate_type, aggregate_id, created_at),
    KEY outbox_published_sweep_idx (published_at)
) ENGINE = InnoDB;

DELIMITER $$

CREATE PROCEDURE platform.prune_outbox(IN p_retain_hours INT)
BEGIN
    DECLARE removed INT DEFAULT 1;
    WHILE removed > 0 DO
        DELETE FROM platform.outbox_messages
         WHERE published_at IS NOT NULL
           AND published_at < DATE_SUB(UTC_TIMESTAMP(6), INTERVAL p_retain_hours HOUR)
         LIMIT 10000;
        SET removed = ROW_COUNT();
    END WHILE;
END$$

DELIMITER ;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0009_platform', UNHEX(SHA2('0009', 256)));
