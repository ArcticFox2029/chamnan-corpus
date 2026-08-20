-- ---------------------------------------------------------------------------
-- 0009_geo_geofences_and_crossings.sql
--
-- geo-service की दोनों tables। geo.geofences हर उस बहुभुज को रखती है जिसके भीतर
-- या बाहर होना किसी को मायने रखता है, और geo.border_crossings उन बिंदुओं को जहाँ
-- customs.customs_declarations दायर होती हैं।
--
-- यह migration routing और freight से पहले चलनी चाहिए: routing.route_legs.crossing_id
-- असली foreign key है (SPEC.md §2 की अनुमत cross-schema सूची)।
-- ---------------------------------------------------------------------------

BEGIN;

-- tenant_id nullable है और यही इस table की पूरी चाल है: NULL का मतलब साझा fence
-- — एक बंदरगाह, एक सीमा-क्षेत्र — जिसे हर tenant देखता है। tenant-विशिष्ट fence
-- ग्राहक का अपना यार्ड होता है और वह किसी और को नहीं दिखता।
--
-- buffer_m हर fence पर अलग है क्योंकि GPS की गड़बड़ खुले बंदरगाह और ढके रेल
-- टर्मिनल में एक जैसी नहीं होती; एक वैश्विक स्थिरांक रखने पर rail terminals पर
-- झूठे geofence_breach alerts की बाढ़ आ गई थी।
CREATE TABLE geo.geofences (
    geofence_id         TEXT        PRIMARY KEY,
    tenant_id           TEXT,
    name                TEXT        NOT NULL,
    kind                TEXT        NOT NULL CHECK (kind IN
                          ('facility','depot','border_zone','restricted','customer_site','corridor')),
    boundary            geography(Polygon, 4326) NOT NULL,
    buffer_m            INTEGER     NOT NULL DEFAULT 50,
    dwell_alert_minutes INTEGER,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at          TIMESTAMPTZ,

    CONSTRAINT geofences_id_is_prefixed_ulid
        CHECK (geofence_id ~ '^gfn_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT geofences_buffer_is_sane CHECK (buffer_m BETWEEN 0 AND 5000),
    CONSTRAINT geofences_dwell_is_positive
        CHECK (dwell_alert_minutes IS NULL OR dwell_alert_minutes > 0),

    -- साझा fence किसी एक tenant का नहीं हो सकता, और restricted zones हमेशा साझा
    -- होते हैं — वे राष्ट्रीय पाबंदियाँ हैं, ग्राहक की पसंद नहीं।
    CONSTRAINT geofences_restricted_is_global
        CHECK (kind <> 'restricted' OR tenant_id IS NULL)
);

COMMENT ON TABLE geo.geofences IS
    'geo.v1.GeoService/PointInFence और /ResolveGeofence दोनों का स्रोत; ResolveGeofence परिणाम को trace-दर-trace 30 सेकंड cache करती है';
COMMENT ON COLUMN geo.geofences.buffer_m IS
    'GPS slop; PointInFence इसे ST_DWithin में लगाती है, boundary को फुलाती नहीं';

CREATE INDEX geofences_boundary_gix ON geo.geofences USING gist (boundary);

CREATE INDEX geofences_tenant_kind_idx
    ON geo.geofences (tenant_id, kind)
    WHERE retired_at IS NULL;

-- साझा fences की सूची console के map में हर बार आती है; tenant_id NULL होने से
-- ऊपर वाला index उन्हें अच्छी तरह नहीं छाँटता।
CREATE INDEX geofences_global_idx
    ON geo.geofences (kind)
    WHERE tenant_id IS NULL AND retired_at IS NULL;

-- सीमा-चौकियाँ। customs_office_code वही स्ट्रिंग है जो customs.customs_declarations
-- पर उद्धृत होती है, और GET /v1/crossings/recommend इसी table को avg_dwell_minutes
-- से क्रम देकर लौटाती है।
--
-- avg_dwell_minutes derived है पर यहीं रखा गया: analytics-pipeline रोज़ रात इसे
-- ताज़ा करती है, और routing-service को planning के दौरान analytics schema पढ़ने की
-- अनुमति नहीं है।
CREATE TABLE geo.border_crossings (
    crossing_id         TEXT     PRIMARY KEY,
    from_country        CHAR(2)  NOT NULL,
    to_country          CHAR(2)  NOT NULL,
    unlocode            CHAR(5)  NOT NULL,
    customs_office_code TEXT     NOT NULL,
    geofence_id         TEXT     NOT NULL REFERENCES geo.geofences(geofence_id),
    modes_allowed       TEXT[]   NOT NULL,
    avg_dwell_minutes   INTEGER  NOT NULL,
    open_24h            BOOLEAN  NOT NULL DEFAULT true,
    UNIQUE (from_country, to_country, unlocode),

    CONSTRAINT crossings_id_is_prefixed_ulid
        CHECK (crossing_id ~ '^bxg_[0-9A-HJKMNP-TV-Z]{26}$'),
    CONSTRAINT crossing_countries_differ CHECK (from_country <> to_country),
    CONSTRAINT crossings_dwell_is_positive CHECK (avg_dwell_minutes >= 0),

    -- modes_allowed का हर सदस्य routing.route_legs.mode की उसी बंद सूची से आता है;
    -- array होने के कारण CHECK ही एकमात्र रास्ता है।
    CONSTRAINT crossings_modes_are_known
        CHECK (modes_allowed <@ ARRAY['road','rail','sea','air','barge']::TEXT[]
               AND cardinality(modes_allowed) > 0)
);

COMMENT ON COLUMN geo.border_crossings.avg_dwell_minutes IS
    'analytics-pipeline रोज़ रात ताज़ा करती है; routing-service का ETA prior यही पढ़ता है';

-- GET /v1/crossings/recommend का असली प्रश्न: इस देश-जोड़ी के लिए सबसे तेज़ चौकी।
CREATE INDEX crossings_pair_dwell_idx
    ON geo.border_crossings (from_country, to_country, avg_dwell_minutes);

CREATE INDEX crossings_office_idx ON geo.border_crossings (customs_office_code);

-- GIN इसलिए कि 'रात में खुली और rail स्वीकार करने वाली चौकियाँ' वाला filter
-- array containment से चलता है।
CREATE INDEX crossings_modes_gin ON geo.border_crossings USING gin (modes_allowed);

INSERT INTO platform.schema_migrations (version, checksum)
VALUES ('0009_geo_geofences_and_crossings', sha256('0009'::bytea));

COMMIT;
