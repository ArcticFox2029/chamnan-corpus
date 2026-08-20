-- ---------------------------------------------------------------------------
-- 0011_freight_hazard_classes.sql
--
-- ख़तरनाक माल का वर्गीकरण: शब्दावली table freight.hazard_classes और उसका
-- many-to-many जोड़ freight.container_hazard_classes। fleet-service की
-- CheckEligibility इन्हीं पंक्तियों को देखकर तय करती है कि ADR-प्रमाणित vehicle
-- चाहिए या नहीं।
--
-- SPEC.md §2.3।
-- ---------------------------------------------------------------------------

BEGIN;

-- यह ADR/IMDG की तय शब्दावली है, हमारी अपनी नहीं — इसलिए primary key वही कोड है
-- जो कागज़ों पर छपता है ('3', '6.1', '8'), कोई surrogate ULID नहीं। कोड बदलते
-- नहीं; नए जुड़ते हैं।
CREATE TABLE freight.hazard_classes (
    hazard_class_code TEXT PRIMARY KEY,
    un_division       TEXT NOT NULL,
    placard_label     TEXT NOT NULL,
    segregation_group TEXT,

    CONSTRAINT hazard_code_shape CHECK (hazard_class_code ~ '^[1-9](\.[1-9])?$')
);

COMMENT ON TABLE freight.hazard_classes IS
    'ADR/IMDG श्रेणियाँ; billing-service का hazmat_handling charge इन्हीं की मौजूदगी से लगता है';

INSERT INTO freight.hazard_classes (hazard_class_code, un_division, placard_label, segregation_group) VALUES
  ('1.4', '1.4', 'Explosives, minor hazard',       'A'),
  ('2.1', '2.1', 'Flammable gas',                  'B'),
  ('2.2', '2.2', 'Non-flammable, non-toxic gas',   NULL),
  ('2.3', '2.3', 'Toxic gas',                      'C'),
  ('3',   '3',   'Flammable liquid',               'B'),
  ('4.1', '4.1', 'Flammable solid',                'B'),
  ('5.1', '5.1', 'Oxidiser',                       'D'),
  ('6.1', '6.1', 'Toxic substance',                'C'),
  ('8',   '8',   'Corrosive',                      'E'),
  ('9',   '9',   'Miscellaneous dangerous goods',  NULL);

-- Many-to-many, और यही सही आकार है: एक टैंक कंटेनर नियमित रूप से अपनी मुख्य
-- श्रेणी के साथ-साथ अवशेष-वर्गीकरण भी ढोता है। इसे freight.containers पर एक
-- column बनाकर सपाट नहीं किया जा सकता।
CREATE TABLE freight.container_hazard_classes (
    container_id      TEXT NOT NULL REFERENCES freight.containers(container_id) ON DELETE CASCADE,
    hazard_class_code TEXT NOT NULL REFERENCES freight.hazard_classes(hazard_class_code),
    is_primary        BOOLEAN NOT NULL DEFAULT false,
    declared_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (container_id, hazard_class_code)
);

-- मुख्य श्रेणी अधिकतम एक। Partial unique index ही एकमात्र तरीक़ा है — साधारण
-- UNIQUE (container_id, is_primary) false वाली पंक्तियों को भी एक तक सीमित कर
-- देता, जो बिलकुल उल्टा है।
CREATE UNIQUE INDEX container_one_primary_hazard
    ON freight.container_hazard_classes (container_id)
    WHERE is_primary;

CREATE INDEX container_hazard_by_class_idx
    ON freight.container_hazard_classes (hazard_class_code);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0011_freight_hazard_classes', sha256('0011'::bytea));

COMMIT;
