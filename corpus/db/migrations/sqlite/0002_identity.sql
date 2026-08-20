-- ---------------------------------------------------------------------------
-- 0002_identity.sql
--
-- identity-service की सातों tables। SQLite में यह schema सिर्फ़ पढ़ने के लिए है —
-- driver-ios और inspector-android इसे token introspection के offline cache की
-- तरह रखते हैं, और edge agent इसे बिलकुल नहीं छूता। इसीलिए यहाँ वे trigger नहीं
-- हैं जो PostgreSQL शाखा में org tree लिखते समय चलते हैं: लिखाई sync से आती है,
-- हाथ से नहीं।
--
-- SPEC.md §2.1।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

CREATE TABLE identity_tenants (
    tenant_id        TEXT NOT NULL PRIMARY KEY,
    legal_name       TEXT NOT NULL,
    country_code     TEXT NOT NULL,
    home_region_code TEXT NOT NULL REFERENCES platform_region_codes (region_code),
    tier             TEXT NOT NULL DEFAULT 'standard'
                          CHECK (tier IN ('trial','standard','enterprise','internal')),
    status           TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','suspended','closed')),
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    closed_at        TEXT,

    -- SQLite में REGEXP built-in नहीं है (वह एक user function है जिसे host
    -- रजिस्टर करता है)। इसलिए ULID की जाँच GLOB से होती है — जो pattern भाषा में
    -- कम ताक़तवर है पर उपसर्ग और लंबाई दोनों पकड़ लेती है, और वही असली गलती है।
    CHECK (tenant_id GLOB 'tnt_[0-9A-Z]*' AND length(tenant_id) = 30),
    CHECK (length(country_code) = 2),
    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
) STRICT;

CREATE INDEX identity_tenants_active_idx
    ON identity_tenants (home_region_code, tier)
    WHERE status = 'active';

-- Self-referencing hierarchy। partial unique index SQLite में है (PostgreSQL
-- जैसा ही), इसलिए 'हर tenant की एक ही जड़' वाला नियम MySQL की generated-column
-- चाल के बिना सीधे लिखा जा सकता है — यह उन कुछ जगहों में से एक है जहाँ SQLite
-- MySQL से ज़्यादा PostgreSQL जैसा है।
CREATE TABLE identity_org_units (
    org_unit_id        TEXT    NOT NULL PRIMARY KEY,
    tenant_id          TEXT    NOT NULL REFERENCES identity_tenants (tenant_id),
    parent_org_unit_id TEXT    REFERENCES identity_org_units (org_unit_id),
    name               TEXT    NOT NULL,
    materialised_path  TEXT    NOT NULL,
    depth              INTEGER NOT NULL CHECK (depth BETWEEN 0 AND 12),
    cost_centre        TEXT,
    created_at         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    archived_at        TEXT,

    CHECK (parent_org_unit_id IS NOT org_unit_id),
    -- depth और path हमेशा सहमत रहें: path में '/' की गिनती depth है।
    CHECK (depth = length(materialised_path) - length(replace(materialised_path, '/', '')) - 1)
) STRICT;

CREATE UNIQUE INDEX identity_org_units_root_is_unique
    ON identity_org_units (tenant_id)
    WHERE parent_org_unit_id IS NULL AND archived_at IS NULL;

-- LIKE 'prefix%' इस index का उपयोग तभी करता है जब column BINARY collation पर हो
-- और PRAGMA case_sensitive_like चालू हो। हम उस pragma पर निर्भर नहीं रहते —
-- authorisation की query GLOB इस्तेमाल करती है, जो हमेशा case-sensitive है और
-- हमेशा index लेती है।
CREATE INDEX identity_org_units_path_idx
    ON identity_org_units (tenant_id, materialised_path);

CREATE INDEX identity_org_units_parent_idx
    ON identity_org_units (parent_org_unit_id)
    WHERE archived_at IS NULL;

-- CITEXT नहीं है, पर SQLite का COLLATE NOCASE column पर लगाया जा सकता है और वही
-- काम करता है — UNIQUE (tenant_id, email) अपने आप case-insensitive हो जाती है।
-- चेतावनी: NOCASE सिर्फ़ ASCII पर काम करता है, इसलिए यूनिकोड डोमेन नाम वाले
-- पते यहाँ PostgreSQL जितने सुरक्षित नहीं हैं। यह स्वीकार किया गया समझौता है
-- क्योंकि यह cache है, सच नहीं।
CREATE TABLE identity_users (
    user_id             TEXT NOT NULL PRIMARY KEY,
    tenant_id           TEXT NOT NULL REFERENCES identity_tenants (tenant_id),
    -- DEFERRABLE FK SQLite में मौजूद है (DEFERRABLE INITIALLY DEFERRED), पर वह
    -- सिर्फ़ transaction के अंत तक टालती है — जो bootstrap के लिए काफ़ी है।
    primary_org_unit_id TEXT NOT NULL
                             REFERENCES identity_org_units (org_unit_id)
                             DEFERRABLE INITIALLY DEFERRED,
    email               TEXT NOT NULL COLLATE NOCASE,
    display_name        TEXT NOT NULL,
    locale              TEXT NOT NULL DEFAULT 'en-GB',
    status              TEXT NOT NULL DEFAULT 'invited'
                             CHECK (status IN ('invited','active','locked','disabled')),
    mfa_enrolled_at     TEXT,
    last_login_at       TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

    UNIQUE (tenant_id, email),
    CHECK (user_id GLOB 'usr_[0-9A-Z]*' AND length(user_id) = 30)
) STRICT;

CREATE INDEX identity_users_org_unit_idx ON identity_users (primary_org_unit_id);

CREATE INDEX identity_users_active_idx
    ON identity_users (tenant_id, email)
    WHERE status IN ('invited','active');

CREATE TABLE identity_roles (
    role_id     TEXT    NOT NULL PRIMARY KEY,
    code        TEXT    NOT NULL UNIQUE,
    scope_level TEXT    NOT NULL CHECK (scope_level IN ('tenant','org_unit','shipment')),
    description TEXT    NOT NULL,
    is_system   INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0, 1))
) STRICT;

INSERT INTO identity_roles VALUES
  ('rol_01H0000000000000000000DISP', 'dispatcher',      'org_unit', 'Assigns vehicles and drivers via fleet.v1.FleetService/Assign', 1),
  ('rol_01H0000000000000000000BRKR', 'customs_broker',  'tenant',   'Files declarations through customs-service', 1),
  ('rol_01H0000000000000000000AUDT', 'auditor',         'tenant',   'Read-only across the tenant, including platform.audit_ledger_entries', 1),
  ('rol_01H0000000000000000000DRVR', 'driver',          'shipment', 'Posts scans and hours-of-service from the driver-ios app', 1),
  ('rol_01H0000000000000000000INSP', 'depot_inspector', 'org_unit', 'Seal checks and damage photos from the inspector-android app', 1),
  ('rol_01H0000000000000000000BILL', 'billing_clerk',   'tenant',   'Issues and voids invoices in billing-service', 1),
  ('rol_01H0000000000000000000ADMN', 'tenant_admin',    'tenant',   'Manages org units, users and API credentials', 1);

CREATE TABLE identity_user_role_grants (
    user_id     TEXT NOT NULL REFERENCES identity_users (user_id) ON DELETE CASCADE,
    role_id     TEXT NOT NULL REFERENCES identity_roles (role_id),
    org_unit_id TEXT NOT NULL REFERENCES identity_org_units (org_unit_id) ON DELETE CASCADE,
    granted_by  TEXT NOT NULL REFERENCES identity_users (user_id),
    granted_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at  TEXT,
    PRIMARY KEY (user_id, role_id, org_unit_id),
    CHECK (expires_at IS NULL OR expires_at > granted_at)
) STRICT;

CREATE INDEX identity_grants_by_role_idx ON identity_user_role_grants (role_id);
CREATE INDEX identity_grants_expiry_idx  ON identity_user_role_grants (expires_at);

CREATE TABLE identity_api_credentials (
    credential_id  TEXT NOT NULL PRIMARY KEY,
    tenant_id      TEXT NOT NULL REFERENCES identity_tenants (tenant_id),
    label          TEXT NOT NULL,
    key_prefix     TEXT NOT NULL UNIQUE,
    secret_hash    TEXT NOT NULL,
    -- TEXT[] नहीं है → JSON array। json_valid() जाँच लेता है कि यह सचमुच JSON है
    -- और json_type() कि array है; सदस्यता json_each() से पढ़ी जाती है।
    scopes         TEXT NOT NULL,
    created_by     TEXT NOT NULL REFERENCES identity_users (user_id),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    rotated_at     TEXT,
    revoked_at     TEXT,
    revoked_reason TEXT,

    CHECK (length(key_prefix) = 12),
    CHECK (json_valid(scopes) AND json_type(scopes) = 'array' AND json_array_length(scopes) > 0),
    CHECK (secret_hash LIKE '$argon2id$%'),
    CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
) STRICT;

CREATE INDEX identity_credentials_live_idx
    ON identity_api_credentials (key_prefix)
    WHERE revoked_at IS NULL;

CREATE TABLE identity_sessions (
    session_id        TEXT NOT NULL PRIMARY KEY,
    user_id           TEXT NOT NULL REFERENCES identity_users (user_id) ON DELETE CASCADE,
    refresh_family_id TEXT NOT NULL,
    issued_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at        TEXT NOT NULL,
    -- INET नहीं है; पता उसी रूप में TEXT में रखते हैं जिस रूप में आया — यहाँ
    -- उस पर कोई तुलना नहीं होती, सिर्फ़ ऑडिट में दिखाना है।
    ip_inet           TEXT,
    user_agent        TEXT,
    revoked_at        TEXT,
    revoked_reason    TEXT CHECK (revoked_reason IN
                        ('logout','rotation_reuse','admin','password_change','mfa_reset')),
    CHECK (expires_at > issued_at)
) STRICT;

CREATE INDEX identity_sessions_family_idx
    ON identity_sessions (refresh_family_id)
    WHERE revoked_at IS NULL;

CREATE INDEX identity_sessions_expiry_idx ON identity_sessions (expires_at);

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0002_identity', '0002');
