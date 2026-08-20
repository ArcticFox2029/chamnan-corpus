-- ---------------------------------------------------------------------------
-- 0004_identity_users_roles_grants.sql
--
-- लोग और उनकी अनुमतियाँ: identity.users, identity.roles और तीन-तरफ़ा grant table
-- identity.user_role_grants। identity.v1.TokenIntrospection/Introspect हर दूसरी
-- सेवा के हर request पर इन्हीं तीन tables को छूता है, इसलिए यहाँ का हर index
-- सोच-समझकर रखा गया है।
--
-- SPEC.md §2.1।
-- ---------------------------------------------------------------------------

BEGIN;

-- primary_org_unit_id DEFERRABLE INITIALLY DEFERRED है क्योंकि tenant bootstrap
-- पहला user और root org unit एक ही transaction में डालती है, और क्रम caller तय
-- करता है, हम नहीं। इसे NOT DEFERRABLE करने की कोशिश एक बार हो चुकी है — signup
-- flow तुरंत टूटा था।
CREATE TABLE identity.users (
    user_id             TEXT        PRIMARY KEY,
    tenant_id           TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    primary_org_unit_id TEXT        NOT NULL REFERENCES identity.org_units(org_unit_id)
                                    DEFERRABLE INITIALLY DEFERRED,
    email               CITEXT      NOT NULL,
    display_name        TEXT        NOT NULL,
    locale              TEXT        NOT NULL DEFAULT 'en-GB',
    status              TEXT        NOT NULL DEFAULT 'invited'
                                    CHECK (status IN ('invited','active','locked','disabled')),
    mfa_enrolled_at     TIMESTAMPTZ,
    last_login_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Email tenant के भीतर unique है, globally नहीं: customs brokers सचमुच कई
    -- tenants में खाते रखते हैं, और उन्हें अलग-अलग पते बनवाना ग्राहक ने साफ़ मना
    -- किया था।
    UNIQUE (tenant_id, email),

    CONSTRAINT users_id_is_prefixed_ulid
        CHECK (user_id ~ '^usr_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- BCP-47, ढीला पर खाली-string रोकने भर को सख़्त।
    CONSTRAINT users_locale_shape CHECK (locale ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$')
);

COMMENT ON TABLE identity.users IS
    'Console और mobile apps के मानव उपयोगकर्ता; service और device actors यहाँ नहीं आते';

-- Login screen email से user ढूँढ़ता है और locked/disabled को वहीं रोक देता है।
-- Partial index इसलिए कि disabled users कभी हटाए नहीं जाते (audit) पर lookup में
-- कभी नहीं आते।
CREATE INDEX users_active_email_idx
    ON identity.users (tenant_id, email)
    WHERE status IN ('invited','active');

CREATE INDEX users_org_unit_idx ON identity.users (primary_org_unit_id);

-- Roles global हैं, per-tenant नहीं। is_system वाली पंक्तियाँ platform के साथ
-- ship होती हैं और tenant उन्हें बदल नहीं सकता; 0005 का trigger इसे लागू करता है।
CREATE TABLE identity.roles (
    role_id     TEXT     PRIMARY KEY,
    code        TEXT     NOT NULL UNIQUE,
    scope_level TEXT     NOT NULL CHECK (scope_level IN ('tenant','org_unit','shipment')),
    description TEXT     NOT NULL,
    is_system   BOOLEAN  NOT NULL DEFAULT false,

    CONSTRAINT roles_id_is_prefixed_ulid
        CHECK (role_id ~ '^rol_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT roles_code_is_snake_case CHECK (code ~ '^[a-z][a-z0-9_]*$')
);

-- तीन-तरफ़ा many-to-many: grant का मतलब है (कौन, क्या, कहाँ)। org unit key का
-- हिस्सा है क्योंकि वही व्यक्ति Hamburg में dispatcher और Rotterdam में सिर्फ़
-- observer होता है — यह असली माँग है, काल्पनिक नहीं।
CREATE TABLE identity.user_role_grants (
    user_id     TEXT        NOT NULL REFERENCES identity.users(user_id) ON DELETE CASCADE,
    role_id     TEXT        NOT NULL REFERENCES identity.roles(role_id),
    org_unit_id TEXT        NOT NULL REFERENCES identity.org_units(org_unit_id) ON DELETE CASCADE,
    granted_by  TEXT        NOT NULL REFERENCES identity.users(user_id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ,
    PRIMARY KEY (user_id, role_id, org_unit_id),

    CONSTRAINT grants_expire_after_grant
        CHECK (expires_at IS NULL OR expires_at > granted_at)
);

COMMENT ON TABLE identity.user_role_grants IS
    'GET /v1/users/{user_id}/effective-roles इसे org_units के ancestors के साथ flatten करता है';

-- effective-roles की query grant से ऊपर की ओर चलती है: पहले user के सारे live
-- grants, फिर हर grant के org unit का materialised_path prefix-match। इसलिए
-- index का leading column user_id है और expires_at partial predicate में।
CREATE INDEX grants_live_idx
    ON identity.user_role_grants (user_id, org_unit_id)
    WHERE expires_at IS NULL OR expires_at > now();

CREATE INDEX grants_by_role_idx ON identity.user_role_grants (role_id);

-- Platform के साथ जाने वाली system roles। इन्हें seed में नहीं रखा क्योंकि
-- introspection इन codes पर हार्ड-निर्भर है — खाली database पर हर service का
-- /readyz तुरंत लाल हो जाता।
INSERT INTO identity.roles (role_id, code, scope_level, description, is_system) VALUES
  ('rol_01H0000000000000000000DISP', 'dispatcher',      'org_unit', 'Assigns vehicles and drivers via fleet.v1.FleetService/Assign', true),
  ('rol_01H0000000000000000000BRKR', 'customs_broker',  'tenant',   'Files declarations through customs-service', true),
  ('rol_01H0000000000000000000AUDT', 'auditor',         'tenant',   'Read-only across the tenant, including platform.audit_ledger_entries', true),
  ('rol_01H0000000000000000000DRVR', 'driver',          'shipment', 'Posts scans and hours-of-service from the driver-ios app', true),
  ('rol_01H0000000000000000000INSP', 'depot_inspector', 'org_unit', 'Seal checks and damage photos from the inspector-android app', true),
  ('rol_01H0000000000000000000BILL', 'billing_clerk',   'tenant',   'Issues and voids invoices in billing-service', true),
  ('rol_01H0000000000000000000ADMN', 'tenant_admin',    'tenant',   'Manages org units, users and API credentials', true);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0004_identity_users_roles_grants', sha256('0004'::bytea));

COMMIT;
