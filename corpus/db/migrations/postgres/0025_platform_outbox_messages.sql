-- ---------------------------------------------------------------------------
-- 0025_platform_outbox_messages.sql
--
-- platform.outbox_messages — वह table जिसकी वजह से SPEC.md §7 नियम 3 निभ पाता
-- है। कोई भी सेवा request handler से सीधे Kafka पर नहीं लिखती; वह अपनी state
-- वाली transaction में यहीं एक पंक्ति डालती है, और प्रति-सेवा relay उसे उठाकर
-- प्रकाशित करता है।
--
-- SPEC.md §0.7, §2.8, §4।
-- ---------------------------------------------------------------------------

BEGIN;

-- message_id ही envelope का event_id बनता है (SPEC.md §0.7) — इसलिए वह यहीं जन्म
-- लेता है, Kafka पर नहीं। यही कारण है कि हर consumer event_id पर idempotent हो
-- सकता है: दोबारा प्रकाशन उसी id के साथ होता है।
CREATE TABLE platform.outbox_messages (
    message_id     TEXT        PRIMARY KEY,
    producer       TEXT        NOT NULL,
    aggregate_type TEXT        NOT NULL,
    aggregate_id   TEXT        NOT NULL,
    event_name     TEXT        NOT NULL,
    topic          TEXT        NOT NULL,
    partition_key  TEXT        NOT NULL,
    schema_version SMALLINT    NOT NULL,
    payload        JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ,
    attempts       SMALLINT    NOT NULL DEFAULT 0,
    last_error     TEXT,

    CONSTRAINT outbox_id_is_prefixed_ulid
        CHECK (message_id ~ '^evt_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- producer SPEC.md §1 की चौदह सेवाओं में से एक होना चाहिए। एक बार एक staging
    -- deploy ने OF_SERVICE_NAME को गलत सेट किया और relay ने सब कुछ किसी अनजान
    -- नाम से प्रकाशित कर दिया; consumers ने चुपचाप छोड़ दिया।
    CONSTRAINT outbox_producer_is_known
        CHECK (producer IN (
            'identity-service','fleet-service','container-registry','telemetry-ingest',
            'routing-service','geo-service','customs-service','billing-service',
            'document-service','notification-service','partner-portal-api',
            'analytics-pipeline','audit-ledger','reconciliation-service')),

    -- छह topics, बंद सूची (SPEC.md §4)।
    CONSTRAINT outbox_topic_is_known
        CHECK (topic IN ('of.identity.v1','of.freight.v1','of.telemetry.v1',
                         'of.customs.v1','of.billing.v1','of.platform.v1')),

    CONSTRAINT outbox_event_name_shape
        CHECK (event_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),

    CONSTRAINT outbox_schema_version_is_positive CHECK (schema_version >= 1),

    -- 8 प्रयास के बाद message DLQ में जाता है (SPEC.md §4.19 नियम 4); उससे आगे
    -- गिनना relay की गड़बड़ है।
    CONSTRAINT outbox_attempts_bounded CHECK (attempts BETWEEN 0 AND 8),

    CONSTRAINT outbox_published_has_no_error
        CHECK (published_at IS NULL OR last_error IS NULL)
);

COMMENT ON TABLE platform.outbox_messages IS
    'transactional outbox; प्रति सेवा relay OF_OUTBOX_RELAY_INTERVAL_MS पर इसे मतदान करता है';
COMMENT ON COLUMN platform.outbox_messages.partition_key IS
    'shipment_id पर keyed संदेश ही platform की इकलौती ordering guarantee देते हैं';

-- Relay का एकमात्र प्रश्न: 'मेरी अप्रकाशित पंक्तियाँ, पुरानी पहले'। Partial index
-- इसलिए अनिवार्य है कि प्रकाशित पंक्तियाँ 24 घंटे रुकती हैं (debugging के लिए) और
-- वे कुल का 99.99% होती हैं।
CREATE INDEX outbox_pending_idx
    ON platform.outbox_messages (producer, created_at)
    WHERE published_at IS NULL;

-- अटकी हुई पंक्तियाँ — on-call का पहला सवाल जब कोई topic ठंडा पड़ जाए।
CREATE INDEX outbox_stuck_idx
    ON platform.outbox_messages (topic, attempts DESC, created_at)
    WHERE published_at IS NULL AND attempts > 0;

-- Aggregate से उलटी खोज: 'इस shipment ने कौन-से events भेजे'।
CREATE INDEX outbox_aggregate_idx
    ON platform.outbox_messages (aggregate_type, aggregate_id, created_at DESC);

-- प्रकाशित पंक्तियों की सफ़ाई इसी से चलती है।
CREATE INDEX outbox_published_sweep_idx
    ON platform.outbox_messages (published_at)
    WHERE published_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- LISTEN/NOTIFY से relay की latency गिराना। मतदान अंतराल OF_OUTBOX_RELAY_INTERVAL_MS
-- = 250 ms है, पर उसका मतलब था कि हर event औसतन 125 ms बैठा रहता। NOTIFY relay
-- को तुरंत जगा देता है; मतदान fallback बना रहता है क्योंकि NOTIFY transaction के
-- commit पर ही जाता है और connection टूटने पर खो जाता है।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.outbox_notify_relay()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- payload में सिर्फ़ producer भेजते हैं: हर relay अपने ही चैनल पर सुनता है और
    -- पूरा message NOTIFY की 8000-byte सीमा में नहीं समाता।
    PERFORM pg_notify('of_outbox', NEW.producer);
    RETURN NULL;
END;
$$;

CREATE TRIGGER outbox_notify_relay_ai
    AFTER INSERT ON platform.outbox_messages
    FOR EACH ROW
    WHEN (NEW.published_at IS NULL)
    EXECUTE FUNCTION platform.outbox_notify_relay();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0025_platform_outbox_messages', sha256('0025'::bytea));

COMMIT;
