-- ---------------------------------------------------------------------------
-- 0024_platform_notifications.sql
--
-- notification-service की दोनों tables। platform.notifications की UNIQUE
-- (source_event_id, channel, recipient_user_id) ही at-least-once delivery को
-- सहनीय बनाती है: वही event दोबारा आने पर insert गिरता है, दूसरा ईमेल नहीं जाता।
--
-- SPEC.md §2.8, §3.10, §4.18।
-- ---------------------------------------------------------------------------

BEGIN;

-- recipient_user_id या webhook_url — इनमें से ठीक एक होता है। partner webhook
-- का कोई user नहीं होता, और console notification का कोई URL नहीं।
CREATE TABLE platform.notifications (
    notification_id   TEXT        PRIMARY KEY,
    tenant_id         TEXT        NOT NULL,
    recipient_user_id TEXT,
    webhook_url       TEXT,
    channel           TEXT        NOT NULL CHECK (channel IN ('email','sms','push','webhook','console')),
    template_code     TEXT        NOT NULL,
    source_event_id   TEXT        NOT NULL,
    payload           JSONB       NOT NULL,
    state             TEXT        NOT NULL DEFAULT 'queued' CHECK (state IN
                        ('queued','sending','sent','failed','suppressed')),
    attempts          SMALLINT    NOT NULL DEFAULT 0,
    queued_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at           TIMESTAMPTZ,
    failed_reason     TEXT,

    -- यही पूरी idempotency है। SPEC.md §4.19 नियम 1 हर consumer से event_id पर
    -- seen-set माँगता है; notification-service के लिए वह seen-set यही UNIQUE है,
    -- अलग table नहीं।
    UNIQUE (source_event_id, channel, recipient_user_id),

    CONSTRAINT notifications_id_is_prefixed_ulid
        CHECK (notification_id ~ '^ntf_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT notifications_source_event_is_prefixed
        CHECK (source_event_id ~ '^evt_[0-9A-HJKMNP-TV-Z]{26}$'),

    CONSTRAINT notifications_target_is_exclusive
        CHECK ((recipient_user_id IS NULL) <> (webhook_url IS NULL)),

    CONSTRAINT notifications_webhook_channel_matches
        CHECK ((channel = 'webhook') = (webhook_url IS NOT NULL)),

    CONSTRAINT notifications_sent_has_timestamp
        CHECK ((state = 'sent') = (sent_at IS NOT NULL)),

    CONSTRAINT notifications_failed_has_reason
        CHECK (state <> 'failed' OR failed_reason IS NOT NULL),

    -- OF_NOTIFY_MAX_ATTEMPTS = 8, SPEC.md §4.19 नियम 4 के DLQ नियम से मेल खाता है।
    CONSTRAINT notifications_attempts_bounded CHECK (attempts BETWEEN 0 AND 8)
);

COMMENT ON TABLE platform.notifications IS
    'POST /v1/notifications/dispatch और हर event consumer यहीं पंक्ति डालते हैं; असल भेजना अलग worker करता है';
COMMENT ON COLUMN platform.notifications.source_event_id IS
    'उसी event envelope का event_id जिसने यह notification जन्माई; retries इसी से बेअसर होती हैं';

-- भेजने वाला worker यही एक प्रश्न पूछता है, हर 200 ms पर।
CREATE INDEX notifications_outbound_idx
    ON platform.notifications (queued_at)
    WHERE state IN ('queued','sending');

-- GET /v1/notifications?state=&channel=&since= — delivery audit screen।
CREATE INDEX notifications_audit_idx
    ON platform.notifications (tenant_id, state, queued_at DESC);

-- notification.delivery.failed भेजने से पहले की खोज; विफल पंक्तियाँ कुल का बहुत
-- छोटा हिस्सा हैं।
CREATE INDEX notifications_failed_idx
    ON platform.notifications (tenant_id, channel, queued_at DESC)
    WHERE state = 'failed';

CREATE INDEX notifications_recipient_idx
    ON platform.notifications (recipient_user_id, queued_at DESC)
    WHERE recipient_user_id IS NOT NULL;

-- वरीयताएँ। event_name या तो SPEC.md §4 का कोई नाम है या '*' — और '*' वाली
-- पंक्ति बाक़ी सबके लिए fallback है, इसलिए lookup हमेशा दो पंक्तियाँ पढ़कर
-- विशिष्ट को प्राथमिकता देती है।
CREATE TABLE platform.notification_preferences (
    user_id           TEXT    NOT NULL,
    channel           TEXT    NOT NULL CHECK (channel IN ('email','sms','push','webhook','console')),
    event_name        TEXT    NOT NULL,
    enabled           BOOLEAN NOT NULL DEFAULT true,
    quiet_hours_start TIME,
    quiet_hours_end   TIME,
    timezone          TEXT    NOT NULL DEFAULT 'UTC',
    PRIMARY KEY (user_id, channel, event_name),

    CONSTRAINT preferences_user_is_prefixed
        CHECK (user_id ~ '^usr_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- '*' या dotted.lower.case — SPEC.md §4 की शब्दावली।
    CONSTRAINT preferences_event_name_shape
        CHECK (event_name = '*' OR event_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),

    -- शांत घंटे या तो पूरे हैं या बिलकुल नहीं। आधे भरे होने पर worker उन्हें चुपचाप
    -- नज़रअंदाज़ करता था और रात दो बजे SMS चले गए थे।
    CONSTRAINT preferences_quiet_hours_are_complete
        CHECK ((quiet_hours_start IS NULL) = (quiet_hours_end IS NULL))
);

COMMENT ON TABLE platform.notification_preferences IS
    'GET/PUT /v1/users/{user_id}/preferences; timezone IANA नाम है, fleet.depots.timezone जैसा';

-- worker प्रति user+channel एक बार पढ़ता है और '*' fallback साथ ही उठाता है।
CREATE INDEX preferences_lookup_idx
    ON platform.notification_preferences (user_id, channel);

-- 'किन उपयोगकर्ताओं ने यह event बंद कर रखा है' — fan-out की गिनती इसी से होती है।
CREATE INDEX preferences_by_event_idx
    ON platform.notification_preferences (event_name, channel)
    WHERE enabled;

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0024_platform_notifications', sha256('0024'::bytea));

COMMIT;
