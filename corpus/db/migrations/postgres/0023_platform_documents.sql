-- ---------------------------------------------------------------------------
-- 0023_platform_documents.sql
--
-- शब्दावली table platform.document_owner_types और उसके ऊपर बैठी बहुरूपी
-- platform.documents। यहाँ की UNIQUE (tenant_id, sha256, owner_type, owner_id)
-- वही है जो SPEC.md §1.2 के Diamond B को हल करती है: partner-portal-api दो अलग
-- रास्तों से वही commercial invoice PDF भेजता है और दूसरा लेखक blob दोबारा नहीं
-- रखता, मौजूदा doc_ id दोबारा इस्तेमाल करता है।
--
-- SPEC.md §2.8, §3.9, §4.16।
-- ---------------------------------------------------------------------------

BEGIN;

-- यह table ही वह चीज़ है जो owner_type को खुला text बनने से रोकती है। दस्तावेज़
-- shipment, declaration, invoice, container, scan या carrier से लटक सकता है — और
-- वे छह अलग schemas में हैं, इसलिए कोई एक foreign key संभव ही नहीं थी।
CREATE TABLE platform.document_owner_types (
    owner_type     TEXT PRIMARY KEY,
    schema_name    TEXT NOT NULL,
    table_name     TEXT NOT NULL,
    owning_service TEXT NOT NULL,
    description    TEXT NOT NULL,

    -- owning_service का नाम SPEC.md §1 की सूची से आता है; typo का मतलब है कि
    -- document-service upload की पुष्टि के लिए किसी अस्तित्वहीन सेवा को बुलाती।
    CONSTRAINT owner_types_service_is_known
        CHECK (owning_service IN (
            'identity-service','fleet-service','container-registry','telemetry-ingest',
            'routing-service','geo-service','customs-service','billing-service',
            'document-service','notification-service','partner-portal-api',
            'analytics-pipeline','audit-ledger','reconciliation-service'))
);

INSERT INTO platform.document_owner_types VALUES
  ('shipment',    'freight',  'shipments',            'container-registry', 'bill of lading, packing list'),
  ('container',   'freight',  'containers',           'container-registry', 'CSC plate photo, damage survey'),
  ('scan',        'freight',  'shipment_scan_events', 'container-registry', 'proof-of-delivery signature'),
  ('declaration', 'customs',  'customs_declarations', 'customs-service',    'commercial invoice, certificate of origin'),
  ('invoice',     'billing',  'invoices',             'billing-service',    'rendered PDF, credit note'),
  ('carrier',     'fleet',    'carriers',             'fleet-service',      'insurance certificate, ADR licence');

-- बहुरूपी संबंध। (owner_type, owner_id) पर कोई referential integrity है ही नहीं,
-- और यह जानबूझकर है: document-service लिखते समय owner_type को ऊपर वाली शब्दावली
-- से जाँचती है और फिर उस schema की मालिक सेवा को बुलाकर id की मौजूदगी की पुष्टि
-- करती है — तभी upload commit होता है।
CREATE TABLE platform.documents (
    document_id    TEXT        PRIMARY KEY,
    tenant_id      TEXT        NOT NULL,
    owner_type     TEXT        NOT NULL REFERENCES platform.document_owner_types(owner_type),
    owner_id       TEXT        NOT NULL,
    kind           TEXT        NOT NULL CHECK (kind IN
                     ('bill_of_lading','commercial_invoice','packing_list','certificate_of_origin',
                      'proof_of_delivery','damage_photo','insurance_certificate','customs_decision',
                      'rendered_invoice','credit_note')),
    storage_key    TEXT        NOT NULL,
    region_code    TEXT        NOT NULL,
    mime_type      TEXT        NOT NULL,
    byte_size      BIGINT      NOT NULL,
    sha256         BYTEA       NOT NULL,
    uploaded_by    TEXT        NOT NULL,
    uploaded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    retained_until DATE,
    deleted_at     TIMESTAMPTZ,

    -- Diamond B (SPEC.md §1.2)। यही वह जाँच है जो एक ही PDF को दो बार object
    -- store में जाने से रोकती है।
    UNIQUE (tenant_id, sha256, owner_type, owner_id),

    CONSTRAINT documents_id_is_prefixed_ulid
        CHECK (document_id ~ '^doc_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT documents_sha256_length CHECK (octet_length(sha256) = 32),
    CONSTRAINT documents_size_is_positive CHECK (byte_size > 0),

    CONSTRAINT documents_region_is_known
        CHECK (region_code IN ('eu-west','eu-central','na-east','na-west',
                               'apac-sg','apac-jp','latam-br','mea-ae')),

    -- storage_key हमेशा region से शुरू होता है (SPEC.md §7 नियम 7): latam-br का
    -- दस्तावेज़ किसी और region की bucket में न लिखा जा सके, यह पहली दीवार है।
    CONSTRAINT documents_storage_key_is_region_prefixed
        CHECK (storage_key LIKE region_code || '/%'),

    CONSTRAINT documents_mime_shape CHECK (mime_type ~ '^[a-z]+/[A-Za-z0-9.+-]+$')
);

COMMENT ON TABLE platform.documents IS
    'POST /v1/documents लिखती है और document.uploaded प्रकाशित करती है; बाइट्स कभी इस table में नहीं आतीं';
COMMENT ON COLUMN platform.documents.retained_until IS
    'customs दस्तावेज़: दाख़िले की तारीख़ + OF_CUSTOMS_RETENTION_YEARS; इससे पहले DELETE मना है';

CREATE INDEX documents_owner_idx
    ON platform.documents (owner_type, owner_id)
    WHERE deleted_at IS NULL;

-- GET /v1/documents?owner_type=&owner_id=&kind= का तीसरा filter।
CREATE INDEX documents_kind_idx
    ON platform.documents (tenant_id, kind, uploaded_at DESC)
    WHERE deleted_at IS NULL;

-- Retention sweep: वे दस्तावेज़ जिनकी अवधि बीत चुकी और जो अभी मिटे नहीं।
CREATE INDEX documents_retention_idx
    ON platform.documents (retained_until)
    WHERE retained_until IS NOT NULL AND deleted_at IS NULL;

-- Diamond B का दूसरा आधा हिस्सा: hash से मौजूदा doc_ ढूँढ़ना, इससे पहले कि blob
-- दोबारा लिखा जाए।
CREATE INDEX documents_sha_lookup_idx
    ON platform.documents (tenant_id, sha256)
    WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- DELETE /v1/documents/{document_id} soft delete है और retained_until के भीतर
-- मना। यह जाँच application में थी और एक बार एक data-fix script ने उसे बाइपास
-- करके customs के दस्तावेज़ समय से पहले हटा दिए थे।
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.documents_guard_retention()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'platform.documents से hard delete मना है; deleted_at भरें'
            USING ERRCODE = 'restrict_violation';
    END IF;

    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL
       AND NEW.retained_until IS NOT NULL AND NEW.retained_until > current_date THEN
        RAISE EXCEPTION 'दस्तावेज़ % % तक रोका गया है', OLD.document_id, NEW.retained_until
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER documents_retention_bud
    BEFORE UPDATE OR DELETE ON platform.documents
    FOR EACH ROW
    EXECUTE FUNCTION platform.documents_guard_retention();

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0023_platform_documents', sha256('0023'::bytea));

COMMIT;
