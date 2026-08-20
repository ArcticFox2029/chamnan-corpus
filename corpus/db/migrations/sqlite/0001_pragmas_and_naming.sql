-- ---------------------------------------------------------------------------
-- 0001_pragmas_and_naming.sql
--
-- ORBITALFREIGHT का schema SQLite 3.45 बोली में। यह शाखा उत्पादन का database
-- नहीं चलाती — इसे तीन जगहें इस्तेमाल करती हैं: edge/ का depot agent अपनी
-- spool के लिए, apps/driver-ios और apps/inspector-android अपने offline cache के
-- लिए, और ci में हर सेवा का integration test। इसलिए यहाँ schema वही है, पर
-- अपेक्षाएँ अलग: एक process, एक writer, और कोई background job नहीं।
--
-- बोली-भेद जो पूरी sqlite/ शाखा को छूते हैं:
--
--   1. Schema नाम नहीं हैं। ATTACH DATABASE से `identity.tenants` लिखना संभव है
--      और वह पहले आज़माया भी गया था — पर SQLite की foreign key किसी दूसरे
--      attached database की table को संदर्भित नहीं कर सकती, यानी schema के भीतर
--      की FKs भी टूट जातीं। इसलिए सब कुछ एक ही फ़ाइल में है और table का नाम
--      `identity_tenants` शैली में उपसर्ग लिए है। SPEC.md का नाम पूरा सुरक्षित
--      रहता है, बस विभाजक '.' के बजाय '_' है।
--
--   2. PRAGMA foreign_keys डिफ़ॉल्ट रूप से बंद है। हर connection पर इसे चालू
--      करना पड़ता है — यह भूल असल में हो चुकी है और inspector-android का cache
--      चुपचाप orphan scans जमा करता रहा। अब हर सेवा का connection खुलते ही यह
--      pragma चलाती है, और नीचे वाली जाँच migration के समय ही असफल हो जाती है।
--
--   3. समय TEXT में है, RFC 3339 UTC, हमेशा 'Z' के साथ (SPEC.md §0.2)। SQLite
--      में कोई timestamp type नहीं है; TEXT ही अकेला रूप है जिसमें शाब्दिक
--      तुलना और कालानुक्रमिक तुलना एक ही चीज़ हैं।
--
--   4. STRICT tables (3.37+) हर जगह। इसके बिना SQLite 'abc' को INTEGER column
--      में चुपचाप स्वीकार कर लेता है, और यही cold-chain के तापमान में एक बार
--      खाली स्ट्रिंग घुसा चुका है।
--
--   5. BOOLEAN नहीं है → INTEGER 0/1 और हर जगह CHECK (col IN (0,1))।
--
--   6. Array और JSONB नहीं हैं → TEXT जिसमें JSON, और CHECK (json_valid(col))।
--
--   7. Spatial type नहीं है। बिंदु lat/lon के दो REAL columns में हैं, और जहाँ
--      खोज चाहिए वहाँ SQLite का अपना R*Tree virtual table (0005) काम करता है।
--
--   8. Stored procedure नहीं हैं → जो PostgreSQL में procedure थीं वे यहाँ
--      trigger हैं, या सेवा के कोड में चली गई हैं।
--
--   9. ALTER TABLE लगभग कुछ नहीं कर सकता — constraint जोड़ना असंभव है। इसलिए
--      PostgreSQL शाखा वाली forward reference (declaration_line_items.tariff_id)
--      यहाँ संभव ही नहीं; tariff table पहले बनती है (0007)।
-- ---------------------------------------------------------------------------

PRAGMA foreign_keys = ON;

-- WAL: एक लेखक और कई पाठक साथ चल सकें। driver-ios में UI thread पढ़ता है जबकि
-- sync thread लिखता है, और rollback journal के साथ वह हर बार SQLITE_BUSY देता था।
PRAGMA journal_mode = WAL;

-- NORMAL WAL के साथ सुरक्षित है (क्रैश पर commit नहीं खोता, सिर्फ़ बिजली जाने पर
-- आख़िरी कुछ transactions) और edge gateway की SD कार्ड पर लिखाई एक-तिहाई कर देता है।
PRAGMA synchronous = NORMAL;

-- 64 MiB page cache; depot agent 512 MiB RAM वाले बोर्ड पर चलता है।
PRAGMA cache_size = -65536;

-- अस्थायी tables डिस्क पर नहीं — SD कार्ड की लिखाई बचाने के लिए।
PRAGMA temp_store = MEMORY;

CREATE TABLE IF NOT EXISTS platform_schema_migrations (
    version    TEXT NOT NULL PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    checksum   TEXT NOT NULL
) STRICT;

-- region codes की बंद सूची (SPEC.md §0.6)। PostgreSQL शाखा में यह हर table के
-- CHECK में दोहराई गई है; यहाँ असली table है क्योंकि SQLite में CHECK बदलने के
-- लिए पूरी table दोबारा बनानी पड़ती है, और आठ मानों की सूची में एक भी बदलाव उस
-- क़ीमत के लायक़ नहीं।
CREATE TABLE platform_region_codes (
    region_code         TEXT NOT NULL PRIMARY KEY,
    display_name        TEXT NOT NULL,
    data_residency_note TEXT NOT NULL
) STRICT;

INSERT INTO platform_region_codes VALUES
  ('eu-west',    'Western Europe',        'GDPR; यूरोपीय संघ के भीतर ही'),
  ('eu-central', 'Central Europe',        'GDPR; identity का इकलौता लेखन-क्षेत्र'),
  ('na-east',    'North America East',    'FMCSA'),
  ('na-west',    'North America West',    'FMCSA'),
  ('apac-sg',    'Singapore',             'PDPA'),
  ('apac-jp',    'Japan',                 'APPI'),
  ('latam-br',   'Brazil',                'LGPD; डेटा ब्राज़ील से बाहर नहीं जाता'),
  ('mea-ae',     'United Arab Emirates',  'UAE Federal Decree-Law 45 of 2021');

-- foreign_keys सचमुच चालू है या नहीं — migration यहीं रुक जाए तो बेहतर, बजाय
-- इसके कि छह महीने बाद orphan पंक्तियाँ मिलें।
CREATE TABLE IF NOT EXISTS platform_migration_guard (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    foreign_keys_were_on INTEGER NOT NULL CHECK (foreign_keys_were_on = 1)
) STRICT;

INSERT OR REPLACE INTO platform_migration_guard (id, foreign_keys_were_on)
SELECT 1, (SELECT * FROM pragma_foreign_keys());

INSERT INTO platform_schema_migrations (version, checksum)
VALUES ('0001_pragmas_and_naming', '0001');
