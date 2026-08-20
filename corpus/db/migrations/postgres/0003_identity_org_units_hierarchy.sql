-- ---------------------------------------------------------------------------
-- 0003_identity_org_units_hierarchy.sql
--
-- identity.org_units — पूरे platform की एकमात्र self-referencing hierarchy, और
-- वह जगह जहाँ authorisation का hot path चलता है। साथ में वह BEFORE trigger भी
-- यहीं बनता है जो materialised_path और depth को reparent पर दोबारा गिनता है।
--
-- SPEC.md §2.1। GET /v1/users/{user_id}/effective-roles इसी table के ancestors
-- को flatten करके जवाब देता है।
-- ---------------------------------------------------------------------------

BEGIN;

-- Org chart मनमाना गहरा होता है: group → region → country entity → branch → desk.
-- materialised_path जानबूझकर denormalised है। "org_01H… के नीचे की हर unit" वाला
-- सवाल authorisation में हर request पर पूछा जाता है; recursive CTE वहाँ p99 को
-- 40 ms तक ले गया था, जबकि text_pattern_ops index पर एक LIKE 0.3 ms में लौटता है।
-- क़ीमत यह है कि reparent पर पूरे subtree को दोबारा लिखना पड़ता है — नीचे trigger।
CREATE TABLE identity.org_units (
    org_unit_id        TEXT        PRIMARY KEY,
    tenant_id          TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    parent_org_unit_id TEXT        REFERENCES identity.org_units(org_unit_id),
    name               TEXT        NOT NULL,
    materialised_path  TEXT        NOT NULL,
    depth              SMALLINT    NOT NULL CHECK (depth BETWEEN 0 AND 12),
    cost_centre        TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at        TIMESTAMPTZ,

    -- एक tenant की जड़ एक ही हो सकती है। UNIQUE partial index से काम चल जाता, पर
    -- EXCLUDE इसलिए चुना कि error message constraint का नाम लेकर आता है और
    -- identity-service उसी नाम पर 409 tenant_root_already_exists मैप करती है।
    CONSTRAINT org_units_root_is_unique
        EXCLUDE (tenant_id WITH =) WHERE (parent_org_unit_id IS NULL AND archived_at IS NULL),

    CONSTRAINT org_units_no_self_parent CHECK (parent_org_unit_id <> org_unit_id),

    CONSTRAINT org_units_id_is_prefixed_ulid
        CHECK (org_unit_id ~ '^org_[0-9A-HJKMNP-TV-Z]{26}$'),

    -- depth और path हमेशा एक-दूसरे से सहमत रहें: path में '/' की गिनती depth है।
    CONSTRAINT org_units_depth_matches_path
        CHECK (depth = length(materialised_path) - length(replace(materialised_path, '/', '')) - 1)
);

COMMENT ON TABLE identity.org_units IS
    'Tenant का org chart; materialised_path authorisation के hot path के लिए denormalised है';
COMMENT ON COLUMN identity.org_units.materialised_path IS
    'जैसे /org_root/org_emea/org_de — हमेशा / से शुरू, बिना trailing /';

CREATE INDEX org_units_path_idx
    ON identity.org_units (tenant_id, materialised_path text_pattern_ops);

CREATE INDEX org_units_parent_idx
    ON identity.org_units (parent_org_unit_id)
    WHERE archived_at IS NULL;

-- ---------------------------------------------------------------------------
-- Path recomputation trigger
--
-- POST/PATCH /v1/tenants/{tenant_id}/org-units दोनों यहीं से गुज़रते हैं। Service
-- कोड path नहीं भेजती — भेजती तो दो writers अलग-अलग हिसाब लगा सकते थे।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.org_units_recompute_path()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    parent_path  TEXT;
    parent_depth SMALLINT;
BEGIN
    IF NEW.parent_org_unit_id IS NULL THEN
        NEW.materialised_path := '/' || NEW.org_unit_id;
        NEW.depth := 0;
    ELSE
        SELECT materialised_path, depth
          INTO parent_path, parent_depth
          FROM identity.org_units
         WHERE org_unit_id = NEW.parent_org_unit_id;

        IF parent_path IS NULL THEN
            RAISE EXCEPTION 'parent org unit % not found', NEW.parent_org_unit_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;

        -- Cycle की जाँच। FK अकेला cycle नहीं रोकता — A→B→A पूरी तरह वैध FK graph
        -- है। यह असल में हुआ था: एक reparent ने दो units को आपस में parent बना
        -- दिया और effective-roles की query हमेशा के लिए घूमती रही।
        IF parent_path LIKE '%/' || NEW.org_unit_id || '/%'
           OR parent_path LIKE '%/' || NEW.org_unit_id THEN
            RAISE EXCEPTION 'reparenting % under % would create a cycle',
                NEW.org_unit_id, NEW.parent_org_unit_id
                USING ERRCODE = 'check_violation';
        END IF;

        NEW.materialised_path := parent_path || '/' || NEW.org_unit_id;
        NEW.depth := parent_depth + 1;
    END IF;

    -- OF_IDENTITY_MAX_ORG_DEPTH इसी सीमा को mirror करता है (SPEC.md §5.2)।
    IF NEW.depth > 12 THEN
        RAISE EXCEPTION 'org unit depth % exceeds the maximum of 12', NEW.depth
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER org_units_path_biu
    BEFORE INSERT OR UPDATE OF parent_org_unit_id
    ON identity.org_units
    FOR EACH ROW
    EXECUTE FUNCTION identity.org_units_recompute_path();

-- Reparent के बाद subtree का path बासी रह जाता है। Statement-level AFTER trigger
-- इसे एक ही UPDATE में ठीक करता है; row-level करते तो हर descendant पर trigger
-- दोबारा चलकर O(n²) हो जाता।
CREATE OR REPLACE FUNCTION identity.org_units_rewrite_subtree()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE identity.org_units child
       SET materialised_path = moved.materialised_path
                             || substring(child.materialised_path
                                          FROM length(moved.old_path) + 1),
           depth = child.depth + (moved.depth - moved.old_depth)
      FROM (
            SELECT n.org_unit_id, n.materialised_path, n.depth,
                   o.materialised_path AS old_path, o.depth AS old_depth
              FROM new_rows n
              JOIN old_rows o USING (org_unit_id)
             WHERE n.materialised_path IS DISTINCT FROM o.materialised_path
           ) moved
     WHERE child.materialised_path LIKE moved.old_path || '/%'
       AND child.org_unit_id <> moved.org_unit_id;

    RETURN NULL;
END;
$$;

CREATE TRIGGER org_units_subtree_aus
    AFTER UPDATE ON identity.org_units
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION identity.org_units_rewrite_subtree();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0003_identity_org_units_hierarchy', sha256('0003'::bytea));

COMMIT;
