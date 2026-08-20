-- ---------------------------------------------------------------------------
-- 0001_databases_and_conventions.sql
--
-- ORBITALFREIGHT का schema MySQL 8.0 बोली में। यह फ़ाइल दसों "schemas" बनाती है
-- और उन नियमों को दर्ज करती है जो पूरी mysql/ शाखा पर लागू हैं — क्योंकि
-- PostgreSQL से यहाँ का अंतर सजावटी नहीं है, कई जगह आकार ही बदलना पड़ा।
--
-- बोली-भेद जो हर फ़ाइल को छूते हैं:
--
--   1. MySQL में schema और database एक ही चीज़ हैं। इसलिए `identity.tenants`
--      यहाँ भी वैसा ही लिखा जाता है, पर वह अलग database है, एक ही database का
--      namespace नहीं। नतीजा: cross-database foreign keys चलती तो हैं, पर
--      InnoDB उन्हें उसी सख़्ती से नहीं निभाता, इसलिए SPEC.md §2 की चार अनुमत
--      cross-schema FKs में से दो यहाँ trigger से लागू होती हैं (0004, 0005)।
--
--   2. TIMESTAMPTZ नहीं है। TIMESTAMP समय-क्षेत्र बदलता है पर 2038 पर ख़त्म हो
--      जाता है — cold-chain के दस्तावेज़ 2038 के बाद भी रखे जाने हैं। इसलिए हर
--      *_at column DATETIME(6) है और UTC ही रखता है; समय-क्षेत्र का रूपांतरण
--      सेवा करती है, database नहीं। SPEC.md §0.2 का 'always UTC, always Z' इसी
--      तरह निभता है।
--
--   3. Partial index नहीं है। जहाँ PostgreSQL में `WHERE deleted_at IS NULL`
--      वाला index था, वहाँ या तो पूरा index है (और थोड़ा बड़ा), या एक generated
--      column जो शर्त पूरी न होने पर NULL रहती है — NULL unique index में आपस
--      में नहीं टकराते, और यही partial unique index की जगह लेता है।
--
--   4. EXCLUDE constraint नहीं है। fleet.vehicle_assignments का ओवरलैप-निषेध
--      और customs.tariff_schedules की अवधि-uniqueness दोनों trigger से लागू हैं
--      (0003 और 0007)। यह PostgreSQL वाली परत जितनी मज़बूत नहीं — trigger को
--      पहले पढ़ना पड़ता है, इसलिए SERIALIZABLE या क़तार वाली lock चाहिए।
--
--   5. ARRAY नहीं है → JSON। `scopes TEXT[]` यहाँ `scopes JSON` है, और उसकी
--      सदस्यता की जाँच JSON_CONTAINS से होती है।
--
--   6. Materialised view नहीं है → असली table + refresh procedure (0010)।
-- ---------------------------------------------------------------------------

SET NAMES utf8mb4;
SET @@session.sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO';

-- utf8mb4_0900_as_cs हर जगह डिफ़ॉल्ट है: पहचानकर्ता case-sensitive हैं (ULID में
-- केस मायने रखता है, SPEC.md §0.1)। सिर्फ़ identity.users.email इसका अपवाद है और
-- वहाँ column पर अलग collation लगती है — वही CITEXT की जगह लेती है।
CREATE DATABASE IF NOT EXISTS identity
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS fleet
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS freight
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS routing
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS geo
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS telemetry
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS customs
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS billing
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS platform
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;
CREATE DATABASE IF NOT EXISTS analytics
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_cs;

-- migration खाता। PostgreSQL शाखा वाली platform.schema_migrations के बराबर;
-- हर सेवा का /version endpoint इसी से अपेक्षित संख्या बताता है।
CREATE TABLE IF NOT EXISTS platform.schema_migrations (
    version    VARCHAR(128) NOT NULL,
    applied_at DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    checksum   BINARY(32)   NOT NULL,
    applied_by VARCHAR(64)  NOT NULL DEFAULT (CURRENT_USER()),
    PRIMARY KEY (version)
) ENGINE = InnoDB;

-- सभी आठ region codes की बंद सूची (SPEC.md §0.6) एक असली table में। PostgreSQL
-- शाखा में यह हर table के CHECK में दोहराई गई है; यहाँ FK से जोड़ना सस्ता पड़ता
-- है क्योंकि MySQL का CHECK expression index का काम नहीं करता और आठ मानों की
-- सूची हर पंक्ति पर दोबारा जाँचना ingest के पैमाने पर दिखने लगा था।
CREATE TABLE IF NOT EXISTS platform.region_codes (
    region_code   VARCHAR(16) NOT NULL,
    display_name  VARCHAR(64) NOT NULL,
    data_residency_note VARCHAR(255) NOT NULL,
    PRIMARY KEY (region_code)
) ENGINE = InnoDB;

INSERT IGNORE INTO platform.region_codes VALUES
  ('eu-west',    'Western Europe',   'GDPR; यूरोपीय संघ के भीतर ही'),
  ('eu-central', 'Central Europe',   'GDPR; identity schema का इकलौता लेखन-क्षेत्र'),
  ('na-east',    'North America East','FMCSA'),
  ('na-west',    'North America West','FMCSA'),
  ('apac-sg',    'Singapore',        'PDPA'),
  ('apac-jp',    'Japan',            'APPI'),
  ('latam-br',   'Brazil',           'LGPD; डेटा ब्राज़ील से बाहर नहीं जाता'),
  ('mea-ae',     'United Arab Emirates', 'UAE Federal Decree-Law 45 of 2021');

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0001_databases_and_conventions', UNHEX(SHA2('0001', 256)));
