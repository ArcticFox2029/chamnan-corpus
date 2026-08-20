-- ---------------------------------------------------------------------------
-- 0022_platform_audit_ledger.sql
--
-- platform.audit_ledger_entries — एकमात्र append-only, hash-chained table। पूरा
-- platform इसमें audit.v1.LedgerService/Append के रास्ते ही लिखता है; audit-ledger
-- इकलौती लेखिका है। यहाँ का trigger UPDATE और DELETE दोनों को असंभव बनाता है,
-- चाहे role के पास grant हो या न हो।
--
-- SPEC.md §2.8, §3.12, §7 नियम 6।
-- ---------------------------------------------------------------------------

BEGIN;

-- entry_id पूरे platform में अकेला BIGINT primary key है (SPEC.md §0.1 का
-- घोषित अपवाद), क्योंकि hash chain को पूर्ण क्रम चाहिए और ULID का क्रम केवल
-- लगभग-समयबद्ध है।
--
-- recorded_at में clock_timestamp() है, now() नहीं: now() पूरे transaction के लिए
-- एक ही मान लौटाता है और एक ही transaction में जुड़ी दस entries एक साथ एक ही
-- क्षण की दिखतीं, जिससे chain की जाँच में क्रम का सुराग खो जाता।
CREATE TABLE platform.audit_ledger_entries (
    entry_id        BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       TEXT        NOT NULL,
    actor_kind      TEXT        NOT NULL CHECK (actor_kind IN ('user','service','device','partner','system')),
    actor_id        TEXT        NOT NULL,
    action          TEXT        NOT NULL,
    subject_type    TEXT        NOT NULL,
    subject_id      TEXT        NOT NULL,
    payload         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    trace_id        CHAR(32),
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    prev_entry_hash BYTEA       NOT NULL,
    entry_hash      BYTEA       NOT NULL UNIQUE,
    checkpoint_id   BIGINT,

    -- sha256 = 32 bytes, हमेशा। ग़लत लंबाई का मतलब है कि किसी ने OF_LEDGER_HASH_
    -- ALGORITHM बदल दिया — जो नई chain शुरू करता है, पुरानी को दोबारा नहीं लिखता।
    CONSTRAINT ledger_hashes_are_sha256
        CHECK (octet_length(prev_entry_hash) = 32 AND octet_length(entry_hash) = 32),

    -- W3C trace-id 32 hex अक्षर (SPEC.md §0.3)।
    CONSTRAINT ledger_trace_is_hex
        CHECK (trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'),

    -- action हमेशा dotted lower case होता है ('shipment.sealed',
    -- 'credential.revoked') — यही वह शब्दावली है जिस पर auditors filter करते हैं।
    CONSTRAINT ledger_action_shape CHECK (action ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')
);

COMMENT ON TABLE platform.audit_ledger_entries IS
    'audit.v1.LedgerService/Append का इकलौता लक्ष्य; entry_hash = sha256(prev || canonical_json(row))';
COMMENT ON COLUMN platform.audit_ledger_entries.prev_entry_hash IS
    'entry_id = 1 के लिए 32 शून्य बाइट; उसके बाद हमेशा पिछली पंक्ति का entry_hash';
COMMENT ON COLUMN platform.audit_ledger_entries.subject_type IS
    'शब्दावली platform.document_owner_types से साझा है, पर FK नहीं — ledger उन छह से ज़्यादा प्रकार दर्ज करता है';

-- GET /v1/entries?subject_type=&subject_id=&since= — सबसे आम auditor प्रश्न,
-- हमेशा नया-पहले।
CREATE INDEX ledger_subject_idx
    ON platform.audit_ledger_entries (subject_type, subject_id, entry_id DESC);

CREATE INDEX ledger_tenant_time_idx
    ON platform.audit_ledger_entries (tenant_id, recorded_at DESC);

CREATE INDEX ledger_actor_idx
    ON platform.audit_ledger_entries (actor_kind, actor_id, entry_id DESC);

-- अभी तक किसी checkpoint में न मुड़ी entries — hourly Merkle fold इसी को पढ़ता है
-- (OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES = 60)।
CREATE INDEX ledger_unfolded_idx
    ON platform.audit_ledger_entries (entry_id)
    WHERE checkpoint_id IS NULL;

-- payload में खोज कभी-कभार होती है (एक विशेष seal number ढूँढ़ना), पर तब पूरी
-- table scan असहनीय है। jsonb_path_ops छोटा पड़ता है क्योंकि हमें सिर्फ़ containment
-- चाहिए, key-existence नहीं।
CREATE INDEX ledger_payload_gin
    ON platform.audit_ledger_entries USING gin (payload jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- अपरिवर्तनीयता। Connection वाले role के पास सिर्फ़ INSERT और SELECT का grant है
-- (0029 देखें), पर grant अकेला काफ़ी नहीं: superuser से चलाया गया एक psql आदेश
-- पूरी chain तोड़ सकता है और सत्यापन हर बाद की entry पर विफल हो जाता। इसलिए
-- trigger भी, और वह किसी role की परवाह नहीं करता।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.ledger_forbid_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'platform.audit_ledger_entries append-only है; % का प्रयास entry % पर रोका गया',
        TG_OP, OLD.entry_id
        USING ERRCODE = 'restrict_violation',
              HINT = 'सुधार के लिए भरपाई करने वाली नई entry जोड़ें';
END;
$$;

CREATE TRIGGER ledger_immutable_bud
    BEFORE UPDATE OR DELETE ON platform.audit_ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION platform.ledger_forbid_mutation();

-- TRUNCATE trigger अलग से चाहिए — वह row-level trigger को छूता ही नहीं।
CREATE OR REPLACE FUNCTION platform.ledger_forbid_truncate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'platform.audit_ledger_entries को TRUNCATE नहीं किया जा सकता'
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER ledger_immutable_bt
    BEFORE TRUNCATE ON platform.audit_ledger_entries
    FOR EACH STATEMENT
    EXECUTE FUNCTION platform.ledger_forbid_truncate();

-- ---------------------------------------------------------------------------
-- Chain को जोड़ने वाला trigger। audit-ledger सेवा hash खुद गिनकर भेजती है, पर यह
-- trigger prev_entry_hash की पुष्टि करता है — दो समानांतर Append कभी एक ही पूर्वज
-- पर न चिपकें। UNIQUE (entry_hash) दूसरी को गिरा देता है और caller दोबारा कोशिश
-- करता है।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.ledger_verify_link()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    expected BYTEA;
BEGIN
    SELECT entry_hash INTO expected
      FROM platform.audit_ledger_entries
     ORDER BY entry_id DESC
     LIMIT 1;

    IF expected IS NULL THEN
        expected := '\x0000000000000000000000000000000000000000000000000000000000000000'::bytea;
    END IF;

    IF NEW.prev_entry_hash <> expected THEN
        RAISE EXCEPTION 'ledger chain टूटी: prev_entry_hash अपेक्षित से भिन्न है'
            USING ERRCODE = 'serialization_failure',
                  HINT = 'नया head पढ़कर Append दोबारा भेजें';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_verify_link_bi
    BEFORE INSERT ON platform.audit_ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION platform.ledger_verify_link();

-- Merkle checkpoints। GET /v1/checkpoints/latest यही head लौटाता है और वही हर
-- घंटे OF_LEDGER_NOTARY_ENDPOINT पर बाहर मिरर होता है।
CREATE TABLE platform.ledger_checkpoints (
    checkpoint_id   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_entry_id   BIGINT      NOT NULL,
    to_entry_id     BIGINT      NOT NULL,
    merkle_root     BYTEA       NOT NULL UNIQUE,
    signature       BYTEA       NOT NULL,
    notarised_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT checkpoints_range_is_forward CHECK (to_entry_id >= from_entry_id),
    CONSTRAINT checkpoints_root_is_sha256 CHECK (octet_length(merkle_root) = 32)
);

ALTER TABLE platform.audit_ledger_entries
    ADD CONSTRAINT ledger_checkpoint_fk
    FOREIGN KEY (checkpoint_id) REFERENCES platform.ledger_checkpoints(checkpoint_id);

CREATE INDEX checkpoints_pending_notary_idx
    ON platform.ledger_checkpoints (created_at)
    WHERE notarised_at IS NULL;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0022_platform_audit_ledger', sha256('0022'::bytea));

COMMIT;
