-- ---------------------------------------------------------------------------
-- 0002_identity_tenants.sql
--
-- identity.tenants बनाती है — वह जड़ जिस पर बाक़ी हर चीज़ लटकी है। हर दूसरी table
-- में जो tenant_id पड़ा है वह या तो असली foreign key है (सिर्फ़ identity schema के
-- भीतर) या logical FK, जिसे owning service ख़ुद enforce करती है।
--
-- SPEC.md §2.1। यह schema सिर्फ़ eu-central में लिखी जाती है और बाक़ी सातों regions
-- में read-only replica के रूप में पहुँचती है, इसलिए यहाँ कोई region-specific
-- partitioning नहीं है।
-- ---------------------------------------------------------------------------

BEGIN;

-- Tenant एक क़ानूनी इकाई है, login boundary नहीं। एक ही broker कई tenants में
-- account रख सकता है — इसीलिए identity.users का UNIQUE (tenant_id, email) है,
-- अकेला email नहीं (देखें 0004)।
--
-- `tier` को CHECK में बाँधा है, lookup table में नहीं: यह चार-मान वाली बंद सूची
-- है जो पिछले तीन साल में नहीं बदली, और JOIN बचाना introspection hot path पर
-- सस्ता पड़ता है।
CREATE TABLE identity.tenants (
    tenant_id        TEXT        PRIMARY KEY,
    legal_name       TEXT        NOT NULL,
    country_code     CHAR(2)     NOT NULL,
    home_region_code TEXT        NOT NULL,
    tier             TEXT        NOT NULL DEFAULT 'standard'
                                 CHECK (tier IN ('trial','standard','enterprise','internal')),
    status           TEXT        NOT NULL DEFAULT 'active'
                                 CHECK (status IN ('active','suspended','closed')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at        TIMESTAMPTZ,

    -- ULID prefix wire पर कभी नहीं हटता (SPEC.md §0.1), इसलिए उसे storage में भी
    -- रखते हैं और यहीं जाँच लेते हैं। 26 base32 characters, Crockford alphabet —
    -- I, L, O, U जानबूझकर बाहर हैं।
    CONSTRAINT tenants_id_is_prefixed_ulid
        CHECK (tenant_id ~ '^tnt_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- SPEC.md §0.6 की बंद सूची। data residency इसी column पर टिकी है, इसलिए एक
    -- typo'ed region silently एक ऐसा tenant बना देता तो उसकी telemetry किसी
    -- partition में गिरती ही नहीं।
    CONSTRAINT tenants_region_is_known
        CHECK (home_region_code IN ('eu-west','eu-central','na-east','na-west',
                                    'apac-sg','apac-jp','latam-br','mea-ae')),

    CONSTRAINT tenants_closed_only_when_closed
        CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

COMMENT ON TABLE  identity.tenants IS
    'हर ग्राहक संगठन की जड़ पंक्ति; identity-service की मालिक, बाक़ी सब के लिए logical FK का लक्ष्य';
COMMENT ON COLUMN identity.tenants.home_region_code IS
    'SPEC.md §0.6; data residency और Kafka partition affinity दोनों यहीं से तय होती हैं';

-- Console की tenant-सूची और billing-service का nightly sweep दोनों सिर्फ़ जीवित
-- tenants देखते हैं। Partial index इसलिए कि बंद हो चुके tenants कभी हटते नहीं
-- (audit retention), पर पढ़े भी लगभग कभी नहीं जाते।
CREATE INDEX tenants_active_idx
    ON identity.tenants (home_region_code, tier)
    WHERE status = 'active';

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0002_identity_tenants', sha256('0002'::bytea));

COMMIT;
