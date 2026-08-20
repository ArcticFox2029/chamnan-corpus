-- ---------------------------------------------------------------------------
-- 0002_identity.sql
--
-- identity-service की सातों tables MySQL 8.0 में। सबसे बड़ा बोली-भेद यहीं है:
-- identity.users.primary_org_unit_id की DEFERRABLE INITIALLY DEFERRED foreign
-- key MySQL में मौजूद ही नहीं — InnoDB हर FK तुरंत जाँचता है और उसे टालने का
-- कोई तरीक़ा नहीं। इसलिए वह FK यहाँ घोषित ही नहीं की गई; tenant bootstrap की
-- transaction पहले org unit डालती है, फिर user, और यह क्रम अब सेवा की ज़िम्मेदारी
-- है, database की नहीं।
--
-- SPEC.md §2.1।
-- ---------------------------------------------------------------------------

CREATE TABLE identity.tenants (
    tenant_id        VARCHAR(30) NOT NULL,
    legal_name       VARCHAR(255) NOT NULL,
    country_code     CHAR(2)     NOT NULL,
    home_region_code VARCHAR(16) NOT NULL,
    tier             ENUM('trial','standard','enterprise','internal')
                                 NOT NULL DEFAULT 'standard',
    status           ENUM('active','suspended','closed')
                                 NOT NULL DEFAULT 'active',
    created_at       DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    closed_at        DATETIME(6) NULL,
    PRIMARY KEY (tenant_id),

    -- PostgreSQL में ये CHECK थे। MySQL 8.0.16+ में CHECK चलता है, पर ENUM यहाँ
    -- बेहतर है: वह मान को storage में एक बाइट में रखता है और गलत मान को insert
    -- पर ही रोक देता है। क़ीमत यह है कि नया tier जोड़ना ALTER TABLE है, CHECK
    -- बदलने जितना सस्ता नहीं — जानबूझकर, क्योंकि यह सूची सचमुच नहीं बदलती।
    CONSTRAINT tenants_id_is_prefixed_ulid
        CHECK (tenant_id REGEXP '^tnt_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT tenants_closed_only_when_closed
        CHECK ((status = 'closed') = (closed_at IS NOT NULL)),

    CONSTRAINT tenants_region_fk FOREIGN KEY (home_region_code)
        REFERENCES platform.region_codes (region_code),

    KEY tenants_active_idx (status, home_region_code, tier)
) ENGINE = InnoDB
  COMMENT = 'हर ग्राहक संगठन की जड़; identity-service की मालिक';

-- Self-referencing hierarchy। PostgreSQL वाला `EXCLUDE (tenant_id WITH =) WHERE
-- (parent IS NULL AND archived_at IS NULL)` यहाँ असंभव है, इसलिए एक generated
-- column से काम लिया है: root_marker सिर्फ़ तभी tenant_id रखती है जब यह पंक्ति
-- जीवित root हो, बाक़ी हर पंक्ति पर NULL — और NULL unique index में आपस में नहीं
-- टकराते। यही MySQL में partial unique index का मानक विकल्प है।
CREATE TABLE identity.org_units (
    org_unit_id        VARCHAR(30)  NOT NULL,
    tenant_id          VARCHAR(30)  NOT NULL,
    parent_org_unit_id VARCHAR(30)  NULL,
    name               VARCHAR(255) NOT NULL,
    materialised_path  VARCHAR(1024) NOT NULL,
    depth              SMALLINT     NOT NULL,
    cost_centre        VARCHAR(64)  NULL,
    created_at         DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    archived_at        DATETIME(6)  NULL,

    root_marker VARCHAR(30) GENERATED ALWAYS AS (
        CASE WHEN parent_org_unit_id IS NULL AND archived_at IS NULL
             THEN tenant_id END
    ) STORED,

    PRIMARY KEY (org_unit_id),
    UNIQUE KEY org_units_root_is_unique (root_marker),

    CONSTRAINT org_units_depth_range CHECK (depth BETWEEN 0 AND 12),
    CONSTRAINT org_units_no_self_parent CHECK (parent_org_unit_id <> org_unit_id),

    CONSTRAINT org_units_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES identity.tenants (tenant_id),
    CONSTRAINT org_units_parent_fk FOREIGN KEY (parent_org_unit_id)
        REFERENCES identity.org_units (org_unit_id),

    -- text_pattern_ops यहाँ नहीं है और न ही ज़रूरत: utf8mb4_0900_as_cs पहले से
    -- binary-order वाली है, इसलिए LIKE 'prefix%' सीधे index इस्तेमाल करता है।
    -- 255 अक्षरों की prefix सीमा इसलिए कि पूरा 1024-अक्षर column InnoDB की
    -- 3072-byte index सीमा पार कर जाता।
    KEY org_units_path_idx (tenant_id, materialised_path(255)),
    KEY org_units_parent_idx (parent_org_unit_id)
) ENGINE = InnoDB
  COMMENT = 'materialised_path authorisation के hot path के लिए denormalised है';

DELIMITER $$

-- PostgreSQL वाला BEFORE trigger यहाँ दो हिस्सों में बँटता है: MySQL एक ही
-- table पर एक ही समय के दो trigger नहीं चलाता था (8.0 से चलाता है), पर असली
-- वजह दूसरी है — MySQL का trigger अपनी ही table को UPDATE नहीं कर सकता, इसलिए
-- subtree का पुनर्लेखन यहाँ trigger में नहीं हो सकता। वह काम
-- identity.reparent_org_unit() procedure करती है और सेवा उसी को बुलाती है।
CREATE TRIGGER org_units_path_bi
BEFORE INSERT ON identity.org_units
FOR EACH ROW
BEGIN
    DECLARE parent_path  VARCHAR(1024);
    DECLARE parent_depth SMALLINT;

    IF NEW.parent_org_unit_id IS NULL THEN
        SET NEW.materialised_path = CONCAT('/', NEW.org_unit_id);
        SET NEW.depth = 0;
    ELSE
        SELECT materialised_path, depth INTO parent_path, parent_depth
          FROM identity.org_units WHERE org_unit_id = NEW.parent_org_unit_id;

        SET NEW.materialised_path = CONCAT(parent_path, '/', NEW.org_unit_id);
        SET NEW.depth = parent_depth + 1;
    END IF;

    IF NEW.depth > 12 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'org unit depth exceeds OF_IDENTITY_MAX_ORG_DEPTH';
    END IF;
END$$

-- Reparent। PostgreSQL में यह एक statement-level AFTER trigger था; यहाँ स्पष्ट
-- procedure है क्योंकि trigger अपनी ही table नहीं छू सकता।
CREATE PROCEDURE identity.reparent_org_unit(
    IN p_org_unit_id VARCHAR(30),
    IN p_new_parent  VARCHAR(30))
BEGIN
    DECLARE old_path   VARCHAR(1024);
    DECLARE old_depth  SMALLINT;
    DECLARE new_path   VARCHAR(1024);
    DECLARE new_depth  SMALLINT;
    DECLARE parent_path VARCHAR(1024);
    DECLARE parent_depth SMALLINT;

    START TRANSACTION;

    SELECT materialised_path, depth INTO old_path, old_depth
      FROM identity.org_units WHERE org_unit_id = p_org_unit_id FOR UPDATE;

    IF p_new_parent IS NULL THEN
        SET new_path = CONCAT('/', p_org_unit_id);
        SET new_depth = 0;
    ELSE
        SELECT materialised_path, depth INTO parent_path, parent_depth
          FROM identity.org_units WHERE org_unit_id = p_new_parent;

        -- चक्र की जाँच; FK अकेला A→B→A नहीं रोकता।
        IF parent_path LIKE CONCAT('%/', p_org_unit_id, '/%')
           OR parent_path LIKE CONCAT('%/', p_org_unit_id) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'reparenting would create a cycle';
        END IF;

        SET new_path = CONCAT(parent_path, '/', p_org_unit_id);
        SET new_depth = parent_depth + 1;
    END IF;

    UPDATE identity.org_units
       SET parent_org_unit_id = p_new_parent,
           materialised_path  = new_path,
           depth              = new_depth
     WHERE org_unit_id = p_org_unit_id;

    UPDATE identity.org_units
       SET materialised_path = CONCAT(new_path, SUBSTRING(materialised_path, CHAR_LENGTH(old_path) + 1)),
           depth = depth + (new_depth - old_depth)
     WHERE materialised_path LIKE CONCAT(old_path, '/%');

    COMMIT;
END$$

DELIMITER ;

-- CITEXT नहीं है। बदले में column पर case-insensitive collation लगती है, जो
-- UNIQUE (tenant_id, email) को अपने आप case-insensitive बना देती है — बिलकुल
-- वही व्यवहार जो PostgreSQL में CITEXT देता है।
CREATE TABLE identity.users (
    user_id             VARCHAR(30)  NOT NULL,
    tenant_id           VARCHAR(30)  NOT NULL,
    -- FK जानबूझकर नहीं: bootstrap का क्रम टाला नहीं जा सकता (ऊपर header देखें)।
    primary_org_unit_id VARCHAR(30)  NOT NULL,
    email               VARCHAR(320) COLLATE utf8mb4_0900_ai_ci NOT NULL,
    display_name        VARCHAR(255) NOT NULL,
    locale              VARCHAR(16)  NOT NULL DEFAULT 'en-GB',
    status              ENUM('invited','active','locked','disabled')
                                     NOT NULL DEFAULT 'invited',
    mfa_enrolled_at     DATETIME(6)  NULL,
    last_login_at       DATETIME(6)  NULL,
    created_at          DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (user_id),
    UNIQUE KEY users_tenant_email (tenant_id, email),

    CONSTRAINT users_id_is_prefixed_ulid
        CHECK (user_id REGEXP '^usr_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT users_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES identity.tenants (tenant_id),

    KEY users_org_unit_idx (primary_org_unit_id),
    KEY users_status_idx (tenant_id, status)
) ENGINE = InnoDB
  COMMENT = 'email tenant के भीतर unique है; brokers कई tenants में खाते रखते हैं';

CREATE TABLE identity.roles (
    role_id     VARCHAR(30)  NOT NULL,
    code        VARCHAR(64)  NOT NULL,
    scope_level ENUM('tenant','org_unit','shipment') NOT NULL,
    description VARCHAR(512) NOT NULL,
    is_system   TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (role_id),
    UNIQUE KEY roles_code (code),
    CONSTRAINT roles_code_is_snake_case CHECK (code REGEXP '^[a-z][a-z0-9_]*$')
) ENGINE = InnoDB;

INSERT INTO identity.roles VALUES
  ('rol_01H0000000000000000000DISP', 'dispatcher',      'org_unit', 'Assigns vehicles and drivers via fleet.v1.FleetService/Assign', 1),
  ('rol_01H0000000000000000000BRKR', 'customs_broker',  'tenant',   'Files declarations through customs-service', 1),
  ('rol_01H0000000000000000000AUDT', 'auditor',         'tenant',   'Read-only across the tenant, including platform.audit_ledger_entries', 1),
  ('rol_01H0000000000000000000DRVR', 'driver',          'shipment', 'Posts scans and hours-of-service from the driver-ios app', 1),
  ('rol_01H0000000000000000000INSP', 'depot_inspector', 'org_unit', 'Seal checks and damage photos from the inspector-android app', 1),
  ('rol_01H0000000000000000000BILL', 'billing_clerk',   'tenant',   'Issues and voids invoices in billing-service', 1),
  ('rol_01H0000000000000000000ADMN', 'tenant_admin',    'tenant',   'Manages org units, users and API credentials', 1);

CREATE TABLE identity.user_role_grants (
    user_id     VARCHAR(30) NOT NULL,
    role_id     VARCHAR(30) NOT NULL,
    org_unit_id VARCHAR(30) NOT NULL,
    granted_by  VARCHAR(30) NOT NULL,
    granted_at  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    expires_at  DATETIME(6) NULL,
    PRIMARY KEY (user_id, role_id, org_unit_id),

    CONSTRAINT grants_user_fk FOREIGN KEY (user_id)
        REFERENCES identity.users (user_id) ON DELETE CASCADE,
    CONSTRAINT grants_role_fk FOREIGN KEY (role_id)
        REFERENCES identity.roles (role_id),
    CONSTRAINT grants_org_fk FOREIGN KEY (org_unit_id)
        REFERENCES identity.org_units (org_unit_id) ON DELETE CASCADE,
    CONSTRAINT grants_granter_fk FOREIGN KEY (granted_by)
        REFERENCES identity.users (user_id),

    -- PostgreSQL में यह `WHERE expires_at IS NULL OR expires_at > now()` वाला
    -- partial index था। MySQL में now() जैसा volatile function index में नहीं जा
    -- सकता, इसलिए पूरा index रखा है और छँटाई query के WHERE पर छोड़ी है।
    KEY grants_expiry_idx (expires_at),
    KEY grants_by_role_idx (role_id)
) ENGINE = InnoDB;

CREATE TABLE identity.api_credentials (
    credential_id  VARCHAR(30)  NOT NULL,
    tenant_id      VARCHAR(30)  NOT NULL,
    label          VARCHAR(128) NOT NULL,
    key_prefix     CHAR(12)     NOT NULL,
    secret_hash    VARCHAR(255) NOT NULL,
    -- TEXT[] नहीं है → JSON array। सदस्यता की जाँच JSON_CONTAINS से होती है और
    -- scopes पर कोई index नहीं — introspection हमेशा key_prefix से आती है और
    -- scopes पढ़ने के बाद ही जाँचे जाते हैं।
    scopes         JSON         NOT NULL,
    created_by     VARCHAR(30)  NOT NULL,
    created_at     DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    rotated_at     DATETIME(6)  NULL,
    revoked_at     DATETIME(6)  NULL,
    revoked_reason VARCHAR(255) NULL,
    PRIMARY KEY (credential_id),
    UNIQUE KEY credentials_key_prefix (key_prefix),

    CONSTRAINT credentials_scopes_is_array CHECK (JSON_TYPE(scopes) = 'ARRAY'),
    CONSTRAINT credentials_scopes_not_empty CHECK (JSON_LENGTH(scopes) > 0),
    CONSTRAINT credentials_hash_is_argon2id CHECK (secret_hash LIKE '$argon2id$%'),
    CONSTRAINT credentials_revoked_needs_reason
        CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL)),

    CONSTRAINT credentials_tenant_fk FOREIGN KEY (tenant_id)
        REFERENCES identity.tenants (tenant_id),
    CONSTRAINT credentials_creator_fk FOREIGN KEY (created_by)
        REFERENCES identity.users (user_id),

    KEY credentials_tenant_idx (tenant_id, created_at)
) ENGINE = InnoDB
  COMMENT = 'DELETE /v1/credentials/{id} पर identity.credential.revoked जाता है';

CREATE TABLE identity.sessions (
    session_id        VARCHAR(30)  NOT NULL,
    user_id           VARCHAR(30)  NOT NULL,
    refresh_family_id VARCHAR(30)  NOT NULL,
    issued_at         DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    expires_at        DATETIME(6)  NOT NULL,
    -- INET type नहीं है। VARBINARY(16) में INET6_ATON() से रखते हैं — यह IPv4 और
    -- IPv6 दोनों समेटता है और तुलना के लिए क्रमबद्ध रहता है, जो VARCHAR नहीं करता।
    ip_inet           VARBINARY(16) NULL,
    user_agent        VARCHAR(512) NULL,
    revoked_at        DATETIME(6)  NULL,
    revoked_reason    ENUM('logout','rotation_reuse','admin','password_change','mfa_reset') NULL,
    PRIMARY KEY (session_id),

    CONSTRAINT sessions_expire_after_issue CHECK (expires_at > issued_at),
    CONSTRAINT sessions_user_fk FOREIGN KEY (user_id)
        REFERENCES identity.users (user_id) ON DELETE CASCADE,

    KEY sessions_family_idx (refresh_family_id, revoked_at),
    KEY sessions_user_recent_idx (user_id, issued_at),
    KEY sessions_expiry_sweep_idx (expires_at)
) ENGINE = InnoDB
  COMMENT = 'rotation reuse पूरे refresh_family_id को मार देता है';

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0002_identity', UNHEX(SHA2('0002', 256)));
