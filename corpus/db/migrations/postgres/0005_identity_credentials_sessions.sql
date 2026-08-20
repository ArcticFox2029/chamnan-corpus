-- ---------------------------------------------------------------------------
-- 0005_identity_credentials_sessions.sql
--
-- मशीन-पहचान और सत्र: identity.api_credentials (partner-portal-api और edge
-- gateways इसी से आते हैं) तथा identity.sessions, जिसमें refresh-token rotation
-- की reuse detection पूरे परिवार को मारती है। साथ में वह trigger भी जो system
-- roles को tenant से बचाता है।
--
-- SPEC.md §2.1, §3.1।
-- ---------------------------------------------------------------------------

BEGIN;

-- key_prefix असली lookup handle है: console उसे दिखाता है, partner उसे भेजता है,
-- और OF_PARTNER_RATE_LIMIT_PER_MINUTE उसी पर गिनता है — IP पर नहीं। secret कभी
-- संग्रहित नहीं होता, सिर्फ़ argon2id hash।
CREATE TABLE identity.api_credentials (
    credential_id  TEXT        PRIMARY KEY,
    tenant_id      TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    label          TEXT        NOT NULL,
    key_prefix     CHAR(12)    NOT NULL UNIQUE,
    secret_hash    TEXT        NOT NULL,
    scopes         TEXT[]      NOT NULL,
    created_by     TEXT        NOT NULL REFERENCES identity.users(user_id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    rotated_at     TIMESTAMPTZ,
    revoked_at     TIMESTAMPTZ,
    revoked_reason TEXT,

    CONSTRAINT credentials_id_is_prefixed_ulid
        CHECK (credential_id ~ '^cred_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- खाली scope array वाला credential चुपचाप सब कुछ मना करता है और debugging में
    -- घंटे खा चुका है; अब उसे बनने ही नहीं देते।
    CONSTRAINT credentials_scopes_not_empty CHECK (cardinality(scopes) > 0),

    -- argon2id encoded hash; यह जाँच सिर्फ़ इसलिए है कि कोई गलती से plaintext या
    -- bcrypt न लिख दे।
    CONSTRAINT credentials_hash_is_argon2id CHECK (secret_hash LIKE '$argon2id$%'),

    CONSTRAINT credentials_revoked_needs_reason
        CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

COMMENT ON COLUMN identity.api_credentials.key_prefix IS
    'DELETE /v1/credentials/{credential_id} इसी prefix को identity.credential.revoked में भेजता है; consumers 5 सेकंड में cache खाली करते हैं';

-- Introspection का सबसे गर्म रास्ता: prefix से जीवित credential ढूँढ़ना। UNIQUE
-- (key_prefix) पहले से है, पर वह revoked पंक्तियों को भी छूता है; यह partial
-- index revoke-भारी tenants पर index को आधा रखता है।
CREATE INDEX credentials_live_idx
    ON identity.api_credentials (key_prefix)
    WHERE revoked_at IS NULL;

CREATE INDEX credentials_tenant_idx
    ON identity.api_credentials (tenant_id, created_at DESC);

-- refresh_family_id वह धागा है जिस पर rotation टिकी है। एक ही refresh token दो
-- बार भुनाया गया मतलब चोरी — तब पूरे परिवार की हर session revoke होती है, न कि
-- सिर्फ़ वह एक।
CREATE TABLE identity.sessions (
    session_id        TEXT        PRIMARY KEY,
    user_id           TEXT        NOT NULL REFERENCES identity.users(user_id) ON DELETE CASCADE,
    refresh_family_id TEXT        NOT NULL,
    issued_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ NOT NULL,
    ip_inet           INET,
    user_agent        TEXT,
    revoked_at        TIMESTAMPTZ,
    revoked_reason    TEXT CHECK (revoked_reason IN
                        ('logout','rotation_reuse','admin','password_change','mfa_reset')),

    CONSTRAINT sessions_id_is_prefixed_ulid
        CHECK (session_id ~ '^ses_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT sessions_expire_after_issue CHECK (expires_at > issued_at)
);

-- POST /v1/auth/token/refresh पूरे परिवार को एक साथ पढ़ता है; revoked पंक्तियाँ
-- उस सवाल में कभी नहीं आतीं।
CREATE INDEX sessions_family_idx
    ON identity.sessions (refresh_family_id)
    WHERE revoked_at IS NULL;

CREATE INDEX sessions_user_recent_idx
    ON identity.sessions (user_id, issued_at DESC);

-- Expired sessions का nightly sweep इसी index से चलता है; बिना इसके वह पूरा
-- table scan करता था और eu-central की replica lag 40 सेकंड तक गई थी।
CREATE INDEX sessions_expiry_sweep_idx
    ON identity.sessions (expires_at)
    WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- System roles को tenant admin से बचाना। SPEC.md §2.1 कहता है "system roles
-- cannot be edited by tenants"; उसे application में लिखा गया था और एक बार
-- migration script ने ही उसे लाँघ दिया था।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.roles_protect_system()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_system AND current_user <> 'of_identity_migrator' THEN
        RAISE EXCEPTION 'system role % is immutable', OLD.code
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER roles_protect_system_bud
    BEFORE UPDATE OR DELETE ON identity.roles
    FOR EACH ROW
    EXECUTE FUNCTION identity.roles_protect_system();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0005_identity_credentials_sessions', sha256('0005'::bytea));

COMMIT;
