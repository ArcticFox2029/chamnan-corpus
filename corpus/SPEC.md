<!--
  SPEC.md — the single source of truth for ORBITALFREIGHT.
  Every service name, table name, column name, endpoint path, event name, environment
  variable and directory path used anywhere in this repository is defined here and
  nowhere else. If an implementation disagrees with this file, the implementation is
  wrong. Cite names from this document verbatim, including case and separators.
-->

# ORBITALFREIGHT — Platform Specification

**Version:** 4.2.0
**Status:** Authoritative
**Scope:** cross-border container logistics — IoT sensors on containers, edge gateways at depots,
fourteen backend services, two mobile apps, one web console, one analytics pipeline.

---

## 0. Cross-cutting conventions

These bind every component. They are not per-service choices.

### 0.1 Identifiers

All primary keys are **prefixed ULIDs** stored as `TEXT` (26 base32 characters after the prefix).
The prefix is part of the value and is never stripped in transit.

| Prefix | Entity | Prefix | Entity |
|---|---|---|---|
| `tnt_` | tenant | `dcl_` | customs declaration |
| `org_` | org unit | `lin_` | declaration line item |
| `usr_` | user | `trf_` | tariff schedule row |
| `rol_` | role | `inv_` | invoice |
| `ses_` | session | `ivl_` | invoice line |
| `cred_` | API credential | `pay_` | payment |
| `car_` | carrier | `doc_` | document |
| `veh_` | vehicle | `ntf_` | notification |
| `drv_` | driver | `gwy_` | device gateway |
| `asg_` | vehicle assignment | `alr_` | telemetry alert |
| `dep_` | depot | `rdg_` | telemetry reading |
| `fac_` | facility | `rec_` | reconciliation run |
| `cnt_` | container | `dsc_` | discrepancy |
| `shp_` | shipment | `evt_` | event envelope id |
| `scn_` | scan event | `job_` | analytics job run |
| `rte_` | route | `gfn_` | geofence |
| `leg_` | route leg | `bxg_` | border crossing |

`audit_ledger_entries.entry_id` is the single exception: it is a `BIGINT` monotonic sequence,
because the ledger's hash chain depends on total order.

### 0.2 Wire format

- Timestamps: RFC 3339, always UTC, always suffix `Z`. Column names end in `_at`.
- Dates without a time: column names end in `_on`.
- Money: integer **minor units** in a `*_minor` column, always paired with a `currency CHAR(3)`
  (ISO 4217) column on the same row. There are no floating-point money columns anywhere.
- Distances: metres, integer, `_m` suffix. Weights: kilograms, integer, `_kg` suffix.
- Temperature: Celsius, `NUMERIC(5,2)`, `_c` suffix.
- Duty and tax rates: **basis points**, integer, `_bp` suffix (1250 = 12.50 %).
- Country codes: ISO 3166-1 alpha-2, uppercase. Ports and inland facilities also carry a
  five-character UN/LOCODE in `unlocode`.

### 0.3 Required HTTP headers

| Header | Meaning |
|---|---|
| `Authorization: Bearer <jwt>` | issued by **identity-service**, RS256, 15 min TTL |
| `X-OF-Tenant` | `tnt_…`; must match the `tid` claim or the request is rejected `403` |
| `X-OF-Trace-Id` | W3C trace-id (32 hex); generated at the edge if absent |
| `X-OF-Idempotency-Key` | required on every non-GET that creates or charges |
| `X-OF-Actor-Kind` | `user` \| `service` \| `device` \| `partner` |

### 0.4 Error envelope

Every service, including the gRPC ones (as `google.rpc.Status.details`), returns:

```json
{
  "error": {
    "code": "shipment_already_sealed",
    "http_status": 409,
    "message": "shipment shp_01J8ZK4T9 is sealed and cannot accept containers",
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
    "retryable": false,
    "fields": [{ "path": "containers[0].seal_number", "reason": "immutable" }]
  }
}
```

`code` is `snake_case`, stable, and part of the public contract. `retryable` drives client backoff.

### 0.5 Pagination

Cursor-based only. Request `?limit=` (max 200, default 50) and `?cursor=`. Response body carries
`{"items": [...], "next_cursor": "…"|null}`. Offset pagination is not implemented anywhere.

### 0.6 Region codes

Used for data residency, telemetry partitioning and Kafka partition affinity. This list is closed:

`eu-west`, `eu-central`, `na-east`, `na-west`, `apac-sg`, `apac-jp`, `latam-br`, `mea-ae`

### 0.7 Event envelope

Every message on every topic is wrapped identically. Only `payload` differs per event.

```json
{
  "event_id": "evt_01J8ZK4T9QW3RM7XN2VB6HD5PC",
  "event_name": "shipment.scanned",
  "schema_version": 3,
  "occurred_at": "2026-03-14T09:21:44.118Z",
  "tenant_id": "tnt_01J7A0000000000000000000AA",
  "region_code": "eu-west",
  "producer": "container-registry",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "partition_key": "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
  "payload": {}
}
```

Producers never write to Kafka directly from request handlers. They insert into
`platform.outbox_messages` inside the same transaction as the state change, and a relay per
service publishes. This is why every consumer must be idempotent on `event_id`.

---

## 1. The fourteen backend services

Ports are the in-cluster listen ports; every service is reachable at
`http://<service-name>.orbitalfreight.svc.cluster.local:<http_port>`.

> **The `Directory` column below is where a service WOULD live. Twelve of the fourteen are not
> built in this repository** — they exist as an OpenAPI document in `contracts/openapi/` and are
> referenced by name from the code that is built. Only `services/fleet/` and `services/routing/`
> resolve as written, and `services/routing/` is Go here rather than the Python this table gives it.
> **§6.0 has the map of what is actually on disk**, and `check_spec.py` re-derives it.

| # | Service | Purpose | Language | Directory | HTTP | gRPC |
|---|---|---|---|---|---|---|
| 1 | **identity-service** | Issues and introspects tokens; owns tenants, users, org-unit hierarchy, roles and API credentials. | Go 1.22 | `services/identity/` | 8081 | 9081 |
| 2 | **fleet-service** | Matches vehicles and drivers to shipments and enforces hours-of-service and licence validity. | Java 21 (Spring Boot 3) | `services/fleet/` | 8082 | 9082 |
| 3 | **container-registry** | System of record for containers, shipments and the scan trail; owns shipment state transitions. | Kotlin 1.9 (Ktor) | `services/container-registry/` | 8083 | 9083 |
| 4 | **telemetry-ingest** | Accepts sensor batches from edge gateways, deduplicates, partitions by region and raises threshold alerts. | Rust 1.77 (axum + tonic) | `services/telemetry-ingest/` | 8084 | 9084 |
| 5 | **routing-service** | Plans and replans multi-leg routes, picks border crossings, computes ETAs. | Python 3.12 (FastAPI) | `services/routing/` | 8085 | — |
| 6 | **geo-service** | Geofence storage and the geometry hot path: point-in-fence, snap-to-road, distance matrices. | C++20 (gRPC core) | `services/geo/` | 8086 | 9086 |
| 7 | **customs-service** | Builds, files and tracks customs declarations; assesses duty against versioned tariff schedules. | C# / .NET 8 | `services/customs/` | 8087 | — |
| 8 | **billing-service** | Turns shipments, assessed duty and accessorial charges into invoices; records payments. | Ruby 3.3 (Rails 7 API) | `services/billing/` | 8088 | — |
| 9 | **document-service** | Stores and serves every binary artefact — bills of lading, photos, signed PDFs — behind short-lived URLs. | TypeScript (Node 20, NestJS) | `services/document/` | 8089 | — |
| 10 | **notification-service** | Fans events out to humans over e-mail, SMS, push and partner webhooks, honouring per-user preferences. | Elixir 1.16 (Phoenix) | `services/notification/` | 8090 | — |
| 11 | **partner-portal-api** | The narrow, rate-limited, tenant-scoped surface external brokers and carriers are allowed to touch. | PHP 8.3 (Laravel 11) | `services/partner-portal/` | 8091 | — |
| 12 | **analytics-pipeline** | Batch and streaming aggregation into the analytics schema; owns every materialised view. | Scala 2.13 (Spark 3.5) | `services/analytics/` | 8093 | — |
| 13 | **audit-ledger** | Append-only, hash-chained record of who did what to which subject, with inclusion proofs. | Go 1.22 | `services/audit-ledger/` | 8092 | 9092 |
| 14 | **reconciliation-service** | Nightly three-way match of shipments, declarations and invoices; opens discrepancies. | Clojure 1.11 | `services/reconciliation/` | 8094 | — |

### 1.1 Synchronous call graph

```
                              ┌──────────────────┐
      everything ────────────▶│ identity-service │   (introspection; no outbound sync calls)
                              └──────────────────┘

  partner-portal-api ─┬─▶ billing-service ──┬─▶ customs-service ──┬─▶ document-service
                      │                     │                     │
                      ├─▶ customs-service ──┘                     │
                      └─▶ container-registry ─────────────────────┘

  fleet-service ─┬─▶ container-registry ─┬─▶ geo-service
                 ├─▶ routing-service ────┘
                 └─▶ document-service

  telemetry-ingest ─┬─▶ container-registry
                    └─▶ geo-service

  routing-service ─┬─▶ geo-service
                   └─▶ customs-service

  analytics-pipeline ─┬─▶ container-registry
                      └─▶ geo-service

  reconciliation-service ─┬─▶ billing-service
                          ├─▶ audit-ledger
                          └─▶ analytics-pipeline

  notification-service ──▶ document-service
  audit-ledger ──▶ (identity-service only)
```

Explicit per-service outbound list, which is what implementations must honour:

| Service | Calls synchronously |
|---|---|
| identity-service | *(none — it is the root)* |
| fleet-service | identity-service, container-registry, routing-service, geo-service, document-service |
| container-registry | identity-service, geo-service, document-service |
| telemetry-ingest | identity-service, container-registry, geo-service |
| routing-service | identity-service, geo-service, customs-service |
| geo-service | identity-service |
| customs-service | identity-service, document-service, audit-ledger |
| billing-service | identity-service, customs-service, fleet-service, document-service |
| document-service | identity-service |
| notification-service | identity-service, document-service |
| partner-portal-api | identity-service, billing-service, customs-service, container-registry |
| analytics-pipeline | identity-service, container-registry, geo-service |
| audit-ledger | identity-service |
| reconciliation-service | identity-service, billing-service, audit-ledger, analytics-pipeline |

### 1.2 Properties of the graph you must preserve

**The universal dependency.** Every one of the other thirteen services calls
`identity.v1.TokenIntrospection/Introspect` (or `BatchIntrospect`) on **identity-service** before
acting on a request. identity-service itself calls nobody synchronously; it only emits events. If
identity-service is unreachable, services fall back to local verification of the RS256 signature
against a cached JWKS for at most `OF_IDENTITY_JWKS_GRACE_SECONDS`, and refuse credential-scoped
(non-user) calls entirely.

**Diamond A — geo-service.** `fleet-service` calls both `container-registry` and `routing-service`;
both of them call `geo-service`. A single fleet assignment therefore resolves the same geofence
twice unless the caller passes `X-OF-Trace-Id` through, which is why geo-service caches
`ResolveGeofence` results per trace for 30 seconds.

**Diamond B — document-service.** `partner-portal-api` calls both `billing-service` and
`customs-service`; both call `document-service` to attach the same commercial invoice PDF. The
second writer must detect the duplicate by `documents.sha256` and reuse the existing `doc_` id
rather than storing the blob twice.

**The cycle, broken by the queue.** `billing-service` needs assessed duty, so it calls
`customs-service` synchronously (`GET /v1/tariffs/lookup`, `GET /v1/declarations/{id}`).
customs-service needs to know whether the duty has been paid before it releases a declaration —
but it **must never call billing-service back**. Instead billing publishes `billing.invoice.settled`
and customs-service consumes it. The synchronous graph is therefore acyclic; the feedback edge
exists only through `of.billing.v1`. Any pull request that adds a billing HTTP client to
customs-service is rejected on sight.

Two smaller edges are broken the same way, and for the same reason:

- `container-registry` never calls `telemetry-ingest`; it consumes `telemetry.alert.raised` to
  flip a shipment into `at_risk`.
- `billing-service` never calls `reconciliation-service`; it consumes
  `reconciliation.discrepancy.opened` and places the invoice on hold.

**Leaves.** `geo-service` and `document-service` call nothing except identity-service. They are the
only services allowed to be on the hot path of more than four callers.

---

## 2. Relational schema

One PostgreSQL 16 cluster, ten schemas, one owning service per schema. Cross-schema **reads** go
through the owning service's API, never through SQL — the only exception is `analytics-pipeline`,
which holds a read-only role (`of_analytics_ro`) on every schema and is the reason the physical
database is shared at all.

| Schema | Owner service | Notes |
|---|---|---|
| `identity` | identity-service | replicated to every region, written in `eu-central` only |
| `fleet` | fleet-service | |
| `freight` | container-registry | |
| `routing` | routing-service | |
| `geo` | geo-service | PostGIS 3.4 extension lives here |
| `telemetry` | telemetry-ingest | partitioned, highest write volume by three orders of magnitude |
| `customs` | customs-service | |
| `billing` | billing-service | |
| `platform` | shared — see per-table owner | documents, notifications, ledger, outbox |
| `analytics` | analytics-pipeline | derived only; safe to drop and rebuild |

**Cross-schema foreign keys.** Rule 2 of §7 forbids a service from *querying* another
service's schema, but a small, enumerated set of declared foreign keys does cross a schema
boundary. They are allowed only against slow-changing reference data whose owner never deletes
rows, and they exist because losing them cost us four orphan-cleanup incidents:

- `freight.containers.owner_carrier_id` → `fleet.carriers`
- `routing.route_legs.crossing_id` → `geo.border_crossings`
- `geo.border_crossings.geofence_id` → `geo.geofences` *(same schema, listed for completeness)*
- `platform.documents.owner_type` → `platform.document_owner_types`

Everywhere else a column that names a row in another schema is marked **logical FK** in the DDL
below and is enforced by the owning service, not by the database — most importantly
`freight.shipments.tenant_id`, `fleet.vehicle_assignments.shipment_id` and every `*_facility_id`
outside `freight`. The DDL below is grouped by domain, not by creation order; the real migrations
in `db/` add the forward references (`customs.declaration_line_items.tariff_id` is the notable
one) with a later `ALTER TABLE`.

### 2.1 `identity` — tenants, people, permissions

```sql
CREATE TABLE identity.tenants (
    tenant_id        TEXT        PRIMARY KEY,              -- tnt_<ULID>
    legal_name       TEXT        NOT NULL,
    country_code     CHAR(2)     NOT NULL,
    home_region_code TEXT        NOT NULL,                 -- one of §0.6
    tier             TEXT        NOT NULL DEFAULT 'standard'
                                 CHECK (tier IN ('trial','standard','enterprise','internal')),
    status           TEXT        NOT NULL DEFAULT 'active'
                                 CHECK (status IN ('active','suspended','closed')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at        TIMESTAMPTZ
);

-- Self-referencing hierarchy. A tenant's org chart is arbitrarily deep: group -> region ->
-- country entity -> branch -> desk. `materialised_path` is denormalised on purpose so that
-- "every unit under org_01H…" is one LIKE against an index instead of a recursive CTE on the
-- authorisation hot path; a BEFORE trigger recomputes it and `depth` on reparent.
CREATE TABLE identity.org_units (
    org_unit_id        TEXT        PRIMARY KEY,            -- org_<ULID>
    tenant_id          TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    parent_org_unit_id TEXT        REFERENCES identity.org_units(org_unit_id),
    name               TEXT        NOT NULL,
    materialised_path  TEXT        NOT NULL,               -- '/org_root/org_emea/org_de'
    depth              SMALLINT    NOT NULL CHECK (depth BETWEEN 0 AND 12),
    cost_centre        TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at        TIMESTAMPTZ,
    CONSTRAINT org_units_root_is_unique
        EXCLUDE (tenant_id WITH =) WHERE (parent_org_unit_id IS NULL AND archived_at IS NULL),
    CONSTRAINT org_units_no_self_parent CHECK (parent_org_unit_id <> org_unit_id)
);
CREATE INDEX org_units_path_idx ON identity.org_units (tenant_id, materialised_path text_pattern_ops);

CREATE TABLE identity.users (
    user_id             TEXT        PRIMARY KEY,           -- usr_<ULID>
    tenant_id           TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    -- DEFERRABLE because tenant bootstrap inserts the first user and the root org unit in one
    -- transaction and the ordering is decided by the caller, not by us.
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
    UNIQUE (tenant_id, email)                              -- e-mail is unique per tenant, not globally:
);                                                         -- brokers legitimately hold accounts at several

CREATE TABLE identity.roles (
    role_id     TEXT     PRIMARY KEY,                      -- rol_<ULID>
    code        TEXT     NOT NULL UNIQUE,                  -- 'dispatcher', 'customs_broker', 'auditor'
    scope_level TEXT     NOT NULL CHECK (scope_level IN ('tenant','org_unit','shipment')),
    description TEXT     NOT NULL,
    is_system   BOOLEAN  NOT NULL DEFAULT false            -- system roles cannot be edited by tenants
);

-- Many-to-many, three-way: a grant is (who, what, where). The org unit is part of the key because
-- the same person is a dispatcher in Hamburg and a read-only observer in Rotterdam.
CREATE TABLE identity.user_role_grants (
    user_id     TEXT        NOT NULL REFERENCES identity.users(user_id) ON DELETE CASCADE,
    role_id     TEXT        NOT NULL REFERENCES identity.roles(role_id),
    org_unit_id TEXT        NOT NULL REFERENCES identity.org_units(org_unit_id) ON DELETE CASCADE,
    granted_by  TEXT        NOT NULL REFERENCES identity.users(user_id),
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ,
    PRIMARY KEY (user_id, role_id, org_unit_id)
);

CREATE TABLE identity.api_credentials (
    credential_id TEXT        PRIMARY KEY,                 -- cred_<ULID>
    tenant_id     TEXT        NOT NULL REFERENCES identity.tenants(tenant_id),
    label         TEXT        NOT NULL,
    key_prefix    CHAR(12)    NOT NULL UNIQUE,             -- shown in the console; the lookup handle
    secret_hash   TEXT        NOT NULL,                    -- argon2id, never the secret itself
    scopes        TEXT[]      NOT NULL,
    created_by    TEXT        NOT NULL REFERENCES identity.users(user_id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    rotated_at    TIMESTAMPTZ,
    revoked_at    TIMESTAMPTZ,
    revoked_reason TEXT
);

CREATE TABLE identity.sessions (
    session_id        TEXT        PRIMARY KEY,             -- ses_<ULID>
    user_id           TEXT        NOT NULL REFERENCES identity.users(user_id) ON DELETE CASCADE,
    refresh_family_id TEXT        NOT NULL,                -- rotation reuse detection kills the family
    issued_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ NOT NULL,
    ip_inet           INET,
    user_agent        TEXT,
    revoked_at        TIMESTAMPTZ,
    revoked_reason    TEXT CHECK (revoked_reason IN
                        ('logout','rotation_reuse','admin','password_change','mfa_reset'))
);
CREATE INDEX sessions_family_idx ON identity.sessions (refresh_family_id) WHERE revoked_at IS NULL;
```

### 2.2 `fleet` — carriers, vehicles, drivers

```sql
CREATE TABLE fleet.carriers (
    carrier_id           TEXT        PRIMARY KEY,          -- car_<ULID>
    tenant_id            TEXT        NOT NULL,             -- logical FK to identity.tenants
    scac_code            CHAR(4),                          -- NULL for non-US carriers
    name                 TEXT        NOT NULL,
    country_code         CHAR(2)     NOT NULL,
    insurance_expires_on DATE        NOT NULL,
    is_subcontractor     BOOLEAN     NOT NULL DEFAULT false,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE fleet.vehicles (
    vehicle_id         TEXT        PRIMARY KEY,            -- veh_<ULID>
    carrier_id         TEXT        NOT NULL REFERENCES fleet.carriers(carrier_id),
    plate              TEXT        NOT NULL,
    plate_country      CHAR(2)     NOT NULL,
    vehicle_class      TEXT        NOT NULL CHECK (vehicle_class IN
                         ('van','rigid','tractor','chassis','reefer_tractor','rail_wagon','barge')),
    max_payload_kg     INTEGER     NOT NULL,
    telematics_unit_id TEXT,                               -- matches telemetry.device_gateways.serial
    adr_certified      BOOLEAN     NOT NULL DEFAULT false, -- may carry dangerous goods
    decommissioned_at  TIMESTAMPTZ,
    UNIQUE (plate_country, plate)
);

CREATE TABLE fleet.drivers (
    driver_id          TEXT        PRIMARY KEY,            -- drv_<ULID>
    carrier_id         TEXT        NOT NULL REFERENCES fleet.carriers(carrier_id),
    -- Nullable: subcontracted drivers appear on the roster long before (or without ever) getting a
    -- console login, so we cannot make this mandatory without blocking dispatch.
    user_id            TEXT,
    full_name          TEXT        NOT NULL,
    licence_number     TEXT        NOT NULL,
    licence_country    CHAR(2)     NOT NULL,
    licence_expires_on DATE        NOT NULL,
    adr_expires_on     DATE,
    phone_e164         TEXT        NOT NULL,
    UNIQUE (licence_country, licence_number)
);

-- One vehicle cannot be on two shipments at once. Enforced by the database rather than by
-- fleet-service, because the mobile app and the dispatch console both write here.
CREATE TABLE fleet.vehicle_assignments (
    assignment_id TEXT        PRIMARY KEY,                 -- asg_<ULID>
    vehicle_id    TEXT        NOT NULL REFERENCES fleet.vehicles(vehicle_id),
    driver_id     TEXT        NOT NULL REFERENCES fleet.drivers(driver_id),
    shipment_id   TEXT        NOT NULL,                    -- logical FK to freight.shipments
    leg_id        TEXT,                                    -- logical FK to routing.route_legs
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at   TIMESTAMPTZ,
    assigned_by   TEXT        NOT NULL,
    active_period TSTZRANGE   GENERATED ALWAYS AS
                    (tstzrange(assigned_at, released_at, '[)')) STORED,
    EXCLUDE USING gist (vehicle_id WITH =, active_period WITH &&),
    EXCLUDE USING gist (driver_id  WITH =, active_period WITH &&)
);

CREATE TABLE fleet.depots (
    depot_id      TEXT        PRIMARY KEY,                 -- dep_<ULID>
    tenant_id     TEXT        NOT NULL,
    name          TEXT        NOT NULL,
    geofence_id   TEXT        NOT NULL,                    -- logical FK to geo.geofences
    unlocode      CHAR(5),
    timezone      TEXT        NOT NULL,                    -- IANA, e.g. 'Europe/Hamburg'
    region_code   TEXT        NOT NULL,
    opened_on     DATE        NOT NULL,
    closed_on     DATE
);
```

### 2.3 `freight` — containers, shipments, the scan trail

```sql
CREATE TABLE freight.facilities (
    facility_id  TEXT        PRIMARY KEY,                  -- fac_<ULID>
    tenant_id    TEXT        NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN
                   ('seaport','airport','rail_terminal','warehouse','customer_site','bonded_store')),
    name         TEXT        NOT NULL,
    country_code CHAR(2)     NOT NULL,
    unlocode     CHAR(5),
    geofence_id  TEXT        NOT NULL,                     -- logical FK to geo.geofences
    region_code  TEXT        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE freight.containers (
    container_id      TEXT        PRIMARY KEY,             -- cnt_<ULID>
    iso_code          CHAR(11)    NOT NULL UNIQUE,         -- BIC, e.g. 'MSCU3948571'
    iso_size_type     CHAR(4)     NOT NULL,                -- '45R1' = 40ft high-cube reefer
    owner_carrier_id  TEXT        REFERENCES fleet.carriers(carrier_id),
    tare_weight_kg    INTEGER     NOT NULL,
    max_gross_kg      INTEGER     NOT NULL,
    is_reefer         BOOLEAN     NOT NULL DEFAULT false,
    setpoint_c        NUMERIC(5,2),                        -- only meaningful when is_reefer
    -- Deliberately NOT a foreign key: telemetry.telemetry_readings is partitioned and lives in a
    -- schema owned by another service, and this column is updated at ~4 kHz across the fleet.
    -- A referential check here would serialise the whole ingest path.
    last_reading_id   TEXT,
    last_reading_at   TIMESTAMPTZ,
    retired_at        TIMESTAMPTZ,
    CONSTRAINT containers_setpoint_only_for_reefer
        CHECK (setpoint_c IS NULL OR is_reefer)
);

CREATE TABLE freight.hazard_classes (
    hazard_class_code TEXT PRIMARY KEY,                    -- '3', '6.1', '8'
    un_division       TEXT NOT NULL,
    placard_label     TEXT NOT NULL,
    segregation_group TEXT
);

-- Many-to-many. A tank container regularly carries a residue classification alongside its
-- primary class, so this cannot collapse into a column on freight.containers.
CREATE TABLE freight.container_hazard_classes (
    container_id      TEXT NOT NULL REFERENCES freight.containers(container_id) ON DELETE CASCADE,
    hazard_class_code TEXT NOT NULL REFERENCES freight.hazard_classes(hazard_class_code),
    is_primary        BOOLEAN NOT NULL DEFAULT false,
    declared_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (container_id, hazard_class_code)
);
CREATE UNIQUE INDEX container_one_primary_hazard
    ON freight.container_hazard_classes (container_id) WHERE is_primary;

CREATE TABLE freight.shipments (
    shipment_id             TEXT        PRIMARY KEY,       -- shp_<ULID>
    tenant_id               TEXT        NOT NULL,
    reference               TEXT        NOT NULL,          -- customer's own booking reference
    origin_facility_id      TEXT        NOT NULL REFERENCES freight.facilities(facility_id),
    destination_facility_id TEXT        NOT NULL REFERENCES freight.facilities(facility_id),
    incoterm                CHAR(3)     NOT NULL,          -- 'DAP', 'CIF', 'EXW' …
    status                  TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                              ('draft','booked','sealed','in_transit','at_risk','held_at_customs',
                               'delivered','cancelled')),
    sla_deadline_at         TIMESTAMPTZ,
    declared_value_minor    BIGINT      NOT NULL DEFAULT 0,
    currency                CHAR(3)     NOT NULL,
    region_code             TEXT        NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at            TIMESTAMPTZ,
    UNIQUE (tenant_id, reference),
    CONSTRAINT shipments_endpoints_differ
        CHECK (origin_facility_id <> destination_facility_id)
);
CREATE INDEX shipments_open_idx ON freight.shipments (tenant_id, status)
    WHERE status NOT IN ('delivered','cancelled');

-- Many-to-many with payload: one shipment holds several containers, and a container is reused
-- across shipments over its lifetime. The seal number belongs to the pairing, not to either side.
CREATE TABLE freight.shipment_containers (
    shipment_id  TEXT        NOT NULL REFERENCES freight.shipments(shipment_id) ON DELETE CASCADE,
    container_id TEXT        NOT NULL REFERENCES freight.containers(container_id),
    seal_number  TEXT        NOT NULL,
    gross_kg     INTEGER     NOT NULL,
    loaded_at    TIMESTAMPTZ,
    unloaded_at  TIMESTAMPTZ,
    PRIMARY KEY (shipment_id, container_id)
);

-- Append-only in practice (no UPDATE path in container-registry), but not hash-chained: the
-- authoritative tamper-evident copy of every scan is mirrored into platform.audit_ledger_entries.
CREATE TABLE freight.shipment_scan_events (
    scan_id            TEXT        PRIMARY KEY,            -- scn_<ULID>
    shipment_id        TEXT        NOT NULL REFERENCES freight.shipments(shipment_id),
    container_id       TEXT        REFERENCES freight.containers(container_id),
    scan_type          TEXT        NOT NULL CHECK (scan_type IN
                         ('gate_in','gate_out','load','unload','seal_check','customs_inspection',
                          'damage_report','proof_of_delivery')),
    scanned_by_user_id TEXT        NOT NULL,
    facility_id        TEXT        REFERENCES freight.facilities(facility_id),
    occurred_at        TIMESTAMPTZ NOT NULL,
    recorded_at        TIMESTAMPTZ NOT NULL DEFAULT now(), -- differs from occurred_at when offline
    position           geography(Point, 4326),
    device_serial      TEXT,
    notes              TEXT
);
CREATE INDEX scan_events_shipment_idx
    ON freight.shipment_scan_events (shipment_id, occurred_at DESC);
```

### 2.4 `routing` and `geo`

```sql
CREATE TABLE routing.routes (
    route_id         TEXT        PRIMARY KEY,              -- rte_<ULID>
    shipment_id      TEXT        NOT NULL,                 -- logical FK to freight.shipments
    version          INTEGER     NOT NULL,                 -- monotonic per shipment; replans bump it
    is_current       BOOLEAN     NOT NULL DEFAULT true,
    planned_by       TEXT        NOT NULL,                 -- usr_… or 'svc:routing-service'
    strategy         TEXT        NOT NULL CHECK (strategy IN
                       ('cheapest','fastest','lowest_carbon','customs_optimised','manual')),
    total_distance_m BIGINT      NOT NULL,
    total_duration_s INTEGER     NOT NULL,
    computed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    superseded_at    TIMESTAMPTZ,
    UNIQUE (shipment_id, version)
);
CREATE UNIQUE INDEX routes_one_current_per_shipment
    ON routing.routes (shipment_id) WHERE is_current;

CREATE TABLE routing.route_legs (
    leg_id             TEXT        PRIMARY KEY,            -- leg_<ULID>
    route_id           TEXT        NOT NULL REFERENCES routing.routes(route_id) ON DELETE CASCADE,
    seq_no             SMALLINT    NOT NULL,
    mode               TEXT        NOT NULL CHECK (mode IN ('road','rail','sea','air','barge')),
    from_facility_id   TEXT        NOT NULL,
    to_facility_id     TEXT        NOT NULL,
    crossing_id        TEXT        REFERENCES geo.border_crossings(crossing_id),
    planned_depart_at  TIMESTAMPTZ NOT NULL,
    planned_arrive_at  TIMESTAMPTZ NOT NULL,
    actual_depart_at   TIMESTAMPTZ,
    actual_arrive_at   TIMESTAMPTZ,
    distance_m         BIGINT      NOT NULL,
    carrier_id         TEXT,
    UNIQUE (route_id, seq_no),
    CONSTRAINT legs_arrive_after_depart CHECK (planned_arrive_at > planned_depart_at)
);

CREATE TABLE geo.geofences (
    geofence_id  TEXT        PRIMARY KEY,                  -- gfn_<ULID>
    tenant_id    TEXT,                                     -- NULL = shared/global fence (a port, a border)
    name         TEXT        NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN
                   ('facility','depot','border_zone','restricted','customer_site','corridor')),
    boundary     geography(Polygon, 4326) NOT NULL,
    buffer_m     INTEGER     NOT NULL DEFAULT 50,          -- GPS slop tolerance on entry/exit
    dwell_alert_minutes INTEGER,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at   TIMESTAMPTZ
);
CREATE INDEX geofences_boundary_gix ON geo.geofences USING gist (boundary);

CREATE TABLE geo.border_crossings (
    crossing_id         TEXT     PRIMARY KEY,              -- bxg_<ULID>
    from_country        CHAR(2)  NOT NULL,
    to_country          CHAR(2)  NOT NULL,
    unlocode            CHAR(5)  NOT NULL,
    customs_office_code TEXT     NOT NULL,                 -- cited on customs.customs_declarations
    geofence_id         TEXT     NOT NULL REFERENCES geo.geofences(geofence_id),
    modes_allowed       TEXT[]   NOT NULL,
    avg_dwell_minutes   INTEGER  NOT NULL,                 -- refreshed nightly by analytics-pipeline
    open_24h            BOOLEAN  NOT NULL DEFAULT true,
    UNIQUE (from_country, to_country, unlocode),
    CONSTRAINT crossing_countries_differ CHECK (from_country <> to_country)
);
```

### 2.5 `telemetry` — the partitioned hot path

```sql
CREATE TABLE telemetry.device_gateways (
    gateway_id       TEXT        PRIMARY KEY,              -- gwy_<ULID>
    serial           TEXT        NOT NULL UNIQUE,
    depot_id         TEXT,                                 -- logical FK to fleet.depots; NULL = mobile
    region_code      TEXT        NOT NULL,
    firmware_version TEXT        NOT NULL,                 -- semver of firmware/sensor-node
    public_key       TEXT        NOT NULL,                 -- Ed25519, verifies every ingest batch
    last_heartbeat_at TIMESTAMPTZ,
    provisioned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    decommissioned_at TIMESTAMPTZ
);

-- Partitioned by LIST(region_code) for data residency, not for size: a Brazilian reading is not
-- permitted to sit on European storage. The partition key must therefore be part of the primary
-- key, which is why the PK is composite even though reading_id is already globally unique.
CREATE TABLE telemetry.telemetry_readings (
    reading_id     TEXT        NOT NULL,                   -- rdg_<ULID>
    region_code    TEXT        NOT NULL,
    container_id   TEXT        NOT NULL,
    gateway_id     TEXT        NOT NULL,
    recorded_at    TIMESTAMPTZ NOT NULL,                   -- clock of the sensor
    received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),     -- clock of telemetry-ingest
    temperature_c  NUMERIC(5,2),
    humidity_pct   NUMERIC(5,2),
    shock_g        NUMERIC(6,3),
    door_open      BOOLEAN,
    battery_pct    SMALLINT CHECK (battery_pct BETWEEN 0 AND 100),
    position       geography(Point, 4326),
    ingest_batch_id TEXT       NOT NULL,                   -- dedupe handle; see UNIQUE below
    PRIMARY KEY (region_code, reading_id)
) PARTITION BY LIST (region_code);

CREATE TABLE telemetry.telemetry_readings_eu_west   PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('eu-west');
CREATE TABLE telemetry.telemetry_readings_eu_central PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('eu-central');
CREATE TABLE telemetry.telemetry_readings_na_east   PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('na-east');
CREATE TABLE telemetry.telemetry_readings_na_west   PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('na-west');
CREATE TABLE telemetry.telemetry_readings_apac_sg   PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('apac-sg');
CREATE TABLE telemetry.telemetry_readings_apac_jp   PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('apac-jp');
CREATE TABLE telemetry.telemetry_readings_latam_br  PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('latam-br');
CREATE TABLE telemetry.telemetry_readings_mea_ae    PARTITION OF telemetry.telemetry_readings FOR VALUES IN ('mea-ae');

-- Gateways retransmit whole batches after a connectivity gap. Uniqueness on (batch, container,
-- sensor clock) makes the replay a no-op instead of a duplicate.
CREATE UNIQUE INDEX readings_dedupe_idx
    ON telemetry.telemetry_readings (region_code, ingest_batch_id, container_id, recorded_at);
CREATE INDEX readings_container_time_idx
    ON telemetry.telemetry_readings (container_id, recorded_at DESC);

CREATE TABLE telemetry.telemetry_alerts (
    alert_id           TEXT        PRIMARY KEY,            -- alr_<ULID>
    container_id       TEXT        NOT NULL,
    shipment_id        TEXT,                               -- resolved via container-registry at raise time
    rule_code          TEXT        NOT NULL CHECK (rule_code IN
                         ('temp_excursion_high','temp_excursion_low','humidity_high','shock_impact',
                          'door_open_in_transit','battery_critical','gateway_silent','geofence_breach')),
    severity           SMALLINT    NOT NULL CHECK (severity BETWEEN 1 AND 5),
    opened_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at          TIMESTAMPTZ,
    peak_value         NUMERIC(10,3),
    threshold_value    NUMERIC(10,3) NOT NULL,
    first_reading_id   TEXT        NOT NULL,
    acknowledged_by    TEXT,
    acknowledged_at    TIMESTAMPTZ
);
CREATE INDEX alerts_open_idx ON telemetry.telemetry_alerts (container_id) WHERE closed_at IS NULL;
```

### 2.6 `customs` — declarations and versioned tariffs

```sql
CREATE TABLE customs.customs_declarations (
    declaration_id      TEXT        PRIMARY KEY,           -- dcl_<ULID>
    tenant_id           TEXT        NOT NULL,
    shipment_id         TEXT        NOT NULL,
    crossing_id         TEXT        NOT NULL,              -- logical FK to geo.border_crossings
    customs_office_code TEXT        NOT NULL,
    broker_user_id      TEXT,
    direction           TEXT        NOT NULL CHECK (direction IN ('import','export','transit')),
    status              TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                          ('draft','submitted','under_review','held','cleared','rejected','amended')),
    mrn                 TEXT        UNIQUE,                -- assigned by the customs authority on accept
    filed_at            TIMESTAMPTZ,
    cleared_at          TIMESTAMPTZ,
    assessed_duty_minor BIGINT,
    assessed_vat_minor  BIGINT,
    currency            CHAR(3)     NOT NULL,
    duty_paid           BOOLEAN     NOT NULL DEFAULT false, -- flipped by billing.invoice.settled
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT declaration_cleared_needs_mrn
        CHECK (status <> 'cleared' OR (mrn IS NOT NULL AND cleared_at IS NOT NULL))
);
CREATE INDEX declarations_shipment_idx ON customs.customs_declarations (shipment_id);

CREATE TABLE customs.declaration_line_items (
    line_id             TEXT        PRIMARY KEY,           -- lin_<ULID>
    declaration_id      TEXT        NOT NULL
                          REFERENCES customs.customs_declarations(declaration_id) ON DELETE CASCADE,
    seq_no              SMALLINT    NOT NULL,
    hs_code             CHAR(10)    NOT NULL,
    description         TEXT        NOT NULL,
    origin_country      CHAR(2)     NOT NULL,
    quantity            NUMERIC(14,3) NOT NULL,
    unit                TEXT        NOT NULL,              -- 'KGM', 'PCE', 'LTR' (UN/ECE Rec 20)
    net_weight_kg       NUMERIC(12,3) NOT NULL,
    customs_value_minor BIGINT      NOT NULL,
    -- The exact tariff row used at assessment time, frozen so a later tariff change cannot
    -- silently rewrite history. Resolved by customs-service through §2.6 tariff_schedules.
    tariff_id           TEXT        REFERENCES customs.tariff_schedules(tariff_id),
    duty_minor          BIGINT,
    UNIQUE (declaration_id, seq_no)
);

-- Temporal / versioned table. Tariff rates change by decree on a date; a declaration filed
-- yesterday must still assess at yesterday's rate. Rows are never updated — a change closes the
-- open period and inserts a successor. The EXCLUDE constraint makes overlapping periods for the
-- same (hs_code, destination, origin) combination impossible at the storage layer.
CREATE TABLE customs.tariff_schedules (
    tariff_id            TEXT      PRIMARY KEY,            -- trf_<ULID>
    hs_code              CHAR(10)  NOT NULL,
    destination_country  CHAR(2)   NOT NULL,
    origin_country       CHAR(2),                          -- NULL = applies to any origin
    duty_rate_bp         INTEGER   NOT NULL CHECK (duty_rate_bp >= 0),
    vat_rate_bp          INTEGER   NOT NULL CHECK (vat_rate_bp >= 0),
    preferential_scheme  TEXT,                             -- 'GSP', 'EU-UK TCA', 'USMCA'
    valid_period         TSTZRANGE NOT NULL,
    superseded_by        TEXT      REFERENCES customs.tariff_schedules(tariff_id),
    source_document_id   TEXT,                             -- doc_… of the published decree
    recorded_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    EXCLUDE USING gist (
        hs_code WITH =, destination_country WITH =,
        coalesce(origin_country, '**') WITH =, valid_period WITH &&
    )
);
```

### 2.7 `billing`

```sql
CREATE TABLE billing.invoices (
    invoice_id      TEXT        PRIMARY KEY,               -- inv_<ULID>
    tenant_id       TEXT        NOT NULL,
    shipment_id     TEXT        NOT NULL,
    invoice_number  TEXT        UNIQUE,                    -- NULL until issued; gap-free per tenant year
    currency        CHAR(3)     NOT NULL,
    subtotal_minor  BIGINT      NOT NULL DEFAULT 0,
    duty_minor      BIGINT      NOT NULL DEFAULT 0,        -- sourced from customs-service
    tax_minor       BIGINT      NOT NULL DEFAULT 0,
    total_minor     BIGINT      NOT NULL DEFAULT 0,
    status          TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN
                      ('draft','issued','part_paid','settled','on_hold','void','written_off')),
    hold_reason     TEXT,                                  -- set from reconciliation.discrepancy.opened
    issued_at       TIMESTAMPTZ,
    due_on          DATE,
    settled_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT invoice_total_is_consistent
        CHECK (total_minor = subtotal_minor + duty_minor + tax_minor)
);
CREATE INDEX invoices_unsettled_idx ON billing.invoices (tenant_id, due_on)
    WHERE status IN ('issued','part_paid','on_hold');

CREATE TABLE billing.invoice_lines (
    invoice_line_id  TEXT     PRIMARY KEY,                 -- ivl_<ULID>
    invoice_id       TEXT     NOT NULL REFERENCES billing.invoices(invoice_id) ON DELETE CASCADE,
    seq_no           SMALLINT NOT NULL,
    charge_code      TEXT     NOT NULL CHECK (charge_code IN
                       ('linehaul','fuel_surcharge','demurrage','detention','reefer_power',
                        'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')),
    description      TEXT     NOT NULL,
    quantity         NUMERIC(12,3) NOT NULL DEFAULT 1,
    unit_price_minor BIGINT   NOT NULL,
    amount_minor     BIGINT   NOT NULL,
    -- Polymorphic-ish provenance: which fact produced this line. Kept as a bare string pair
    -- because the sources live in four different schemas owned by four different services.
    source_kind      TEXT     CHECK (source_kind IN
                       ('leg','alert','declaration','assignment','manual')),
    source_id        TEXT,
    UNIQUE (invoice_id, seq_no)
);

CREATE TABLE billing.payments (
    payment_id   TEXT        PRIMARY KEY,                  -- pay_<ULID>
    invoice_id   TEXT        NOT NULL REFERENCES billing.invoices(invoice_id),
    method       TEXT        NOT NULL CHECK (method IN ('sepa_dd','swift','card','credit_note','cash')),
    amount_minor BIGINT      NOT NULL CHECK (amount_minor > 0),
    currency     CHAR(3)     NOT NULL,
    received_at  TIMESTAMPTZ NOT NULL,
    external_ref TEXT,                                     -- PSP or bank statement reference
    reversed_at  TIMESTAMPTZ,
    UNIQUE (method, external_ref)                          -- idempotency against bank file re-import
);
```

### 2.8 `platform` — ledger, documents, notifications, outbox

```sql
-- Append-only. The role that owns the connection has INSERT and SELECT only; there is no UPDATE
-- or DELETE grant, and a BEFORE UPDATE OR DELETE trigger raises regardless. Each row hashes the
-- previous row's hash, so removing or editing any entry breaks verification of every entry after
-- it. audit-ledger is the only writer; everything else appends through
-- audit.v1.LedgerService/Append.
CREATE TABLE platform.audit_ledger_entries (
    entry_id        BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       TEXT        NOT NULL,
    actor_kind      TEXT        NOT NULL CHECK (actor_kind IN ('user','service','device','partner','system')),
    actor_id        TEXT        NOT NULL,
    action          TEXT        NOT NULL,                  -- 'shipment.sealed', 'credential.revoked'
    subject_type    TEXT        NOT NULL,                  -- see platform.document_owner_types vocabulary
    subject_id      TEXT        NOT NULL,
    payload         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    trace_id        CHAR(32),
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    prev_entry_hash BYTEA       NOT NULL,                  -- 32 zero bytes for entry_id = 1
    entry_hash      BYTEA       NOT NULL UNIQUE,           -- sha256(prev || canonical_json(row))
    checkpoint_id   BIGINT                                 -- set when folded into a Merkle checkpoint
);
CREATE INDEX ledger_subject_idx ON platform.audit_ledger_entries (subject_type, subject_id, entry_id DESC);

-- Vocabulary table backing the polymorphic association below. A document can hang off a shipment,
-- a declaration, an invoice, a container, a scan or a carrier, and those live in six schemas — so
-- no single foreign key is possible. This table is what keeps `owner_type` from becoming free text.
CREATE TABLE platform.document_owner_types (
    owner_type    TEXT PRIMARY KEY,
    schema_name   TEXT NOT NULL,
    table_name    TEXT NOT NULL,
    owning_service TEXT NOT NULL,
    description   TEXT NOT NULL
);
INSERT INTO platform.document_owner_types VALUES
  ('shipment',    'freight',  'shipments',            'container-registry', 'bill of lading, packing list'),
  ('container',   'freight',  'containers',           'container-registry', 'CSC plate photo, damage survey'),
  ('scan',        'freight',  'shipment_scan_events', 'container-registry', 'proof-of-delivery signature'),
  ('declaration', 'customs',  'customs_declarations', 'customs-service',    'commercial invoice, certificate of origin'),
  ('invoice',     'billing',  'invoices',             'billing-service',    'rendered PDF, credit note'),
  ('carrier',     'fleet',    'carriers',             'fleet-service',      'insurance certificate, ADR licence');

-- Polymorphic association. (owner_type, owner_id) has no referential integrity by construction;
-- document-service validates owner_type against platform.document_owner_types on write and calls
-- the owning service to confirm the id exists before the upload is committed.
CREATE TABLE platform.documents (
    document_id  TEXT        PRIMARY KEY,                  -- doc_<ULID>
    tenant_id    TEXT        NOT NULL,
    owner_type   TEXT        NOT NULL REFERENCES platform.document_owner_types(owner_type),
    owner_id     TEXT        NOT NULL,
    kind         TEXT        NOT NULL CHECK (kind IN
                   ('bill_of_lading','commercial_invoice','packing_list','certificate_of_origin',
                    'proof_of_delivery','damage_photo','insurance_certificate','customs_decision',
                    'rendered_invoice','credit_note')),
    storage_key  TEXT        NOT NULL,                     -- object-store key, region-prefixed
    region_code  TEXT        NOT NULL,
    mime_type    TEXT        NOT NULL,
    byte_size    BIGINT      NOT NULL,
    sha256       BYTEA       NOT NULL,
    uploaded_by  TEXT        NOT NULL,
    uploaded_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    retained_until DATE,                                   -- customs documents: filing date + 10 years
    deleted_at   TIMESTAMPTZ,
    UNIQUE (tenant_id, sha256, owner_type, owner_id)       -- see Diamond B in §1.2
);
CREATE INDEX documents_owner_idx ON platform.documents (owner_type, owner_id) WHERE deleted_at IS NULL;

CREATE TABLE platform.notifications (
    notification_id TEXT        PRIMARY KEY,               -- ntf_<ULID>
    tenant_id       TEXT        NOT NULL,
    recipient_user_id TEXT,                                -- NULL when the target is a partner webhook
    webhook_url     TEXT,
    channel         TEXT        NOT NULL CHECK (channel IN ('email','sms','push','webhook','console')),
    template_code   TEXT        NOT NULL,                  -- 'shipment_delayed', 'invoice_overdue'
    source_event_id TEXT        NOT NULL,                  -- evt_… ; makes retries idempotent
    payload         JSONB       NOT NULL,
    state           TEXT        NOT NULL DEFAULT 'queued' CHECK (state IN
                      ('queued','sending','sent','failed','suppressed')),
    attempts        SMALLINT    NOT NULL DEFAULT 0,
    queued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at         TIMESTAMPTZ,
    failed_reason   TEXT,
    UNIQUE (source_event_id, channel, recipient_user_id)
);

CREATE TABLE platform.notification_preferences (
    user_id    TEXT    NOT NULL,
    channel    TEXT    NOT NULL CHECK (channel IN ('email','sms','push','webhook','console')),
    event_name TEXT    NOT NULL,                           -- one of §4, or '*'
    enabled    BOOLEAN NOT NULL DEFAULT true,
    quiet_hours_start TIME,
    quiet_hours_end   TIME,
    timezone   TEXT    NOT NULL DEFAULT 'UTC',
    PRIMARY KEY (user_id, channel, event_name)
);

-- Transactional outbox. Every producing service writes here in the same transaction as its state
-- change; a per-service relay reads, publishes to Kafka and stamps published_at. Nothing publishes
-- from a request handler directly.
CREATE TABLE platform.outbox_messages (
    message_id     TEXT        PRIMARY KEY,                -- evt_<ULID>, becomes envelope.event_id
    producer       TEXT        NOT NULL,                   -- service name from §1
    aggregate_type TEXT        NOT NULL,
    aggregate_id   TEXT        NOT NULL,
    event_name     TEXT        NOT NULL,
    topic          TEXT        NOT NULL,
    partition_key  TEXT        NOT NULL,
    schema_version SMALLINT    NOT NULL,
    payload        JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ,
    attempts       SMALLINT    NOT NULL DEFAULT 0,
    last_error     TEXT
);
CREATE INDEX outbox_pending_idx ON platform.outbox_messages (producer, created_at)
    WHERE published_at IS NULL;
```

### 2.9 `analytics` — reconciliation and the materialised views

```sql
CREATE TABLE analytics.reconciliation_runs (
    run_id         TEXT        PRIMARY KEY,                -- rec_<ULID>
    tenant_id      TEXT        NOT NULL,
    business_date  DATE        NOT NULL,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ,
    state          TEXT        NOT NULL DEFAULT 'running'
                     CHECK (state IN ('running','succeeded','failed','partial')),
    shipments_examined INTEGER NOT NULL DEFAULT 0,
    discrepancies_opened INTEGER NOT NULL DEFAULT 0,
    engine_version TEXT        NOT NULL,
    UNIQUE (tenant_id, business_date, engine_version)
);

CREATE TABLE analytics.reconciliation_discrepancies (
    discrepancy_id TEXT        PRIMARY KEY,                -- dsc_<ULID>
    run_id         TEXT        NOT NULL REFERENCES analytics.reconciliation_runs(run_id),
    tenant_id      TEXT        NOT NULL,
    shipment_id    TEXT        NOT NULL,
    declaration_id TEXT,
    invoice_id     TEXT,
    kind           TEXT        NOT NULL CHECK (kind IN
                     ('missing_declaration','missing_invoice','duty_mismatch','weight_mismatch',
                      'orphan_payment','unbilled_accessorial','cleared_without_payment')),
    expected_minor BIGINT,
    observed_minor BIGINT,
    currency       CHAR(3),
    state          TEXT        NOT NULL DEFAULT 'open'
                     CHECK (state IN ('open','acknowledged','resolved','waived')),
    opened_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at    TIMESTAMPTZ,
    resolved_by    TEXT,
    resolution_note TEXT
);
CREATE INDEX discrepancies_open_idx ON analytics.reconciliation_discrepancies (tenant_id, kind)
    WHERE state = 'open';

-- Materialised view. Refreshed CONCURRENTLY at 03:15 UTC by analytics-pipeline; the unique index
-- below exists solely because REFRESH ... CONCURRENTLY requires one. The web console's lane
-- dashboard and routing-service's ETA prior both read it — routing-service is the reason
-- avg_transit_seconds is stored rather than recomputed.
CREATE MATERIALIZED VIEW analytics.mv_lane_performance_daily AS
SELECT
    s.tenant_id,
    date_trunc('day', s.created_at)::date          AS business_date,
    o.unlocode                                     AS origin_unlocode,
    d.unlocode                                     AS destination_unlocode,
    l.mode                                         AS primary_mode,
    count(*)                                       AS shipment_count,
    count(*) FILTER (WHERE s.delivered_at <= s.sla_deadline_at) AS on_time_count,
    avg(extract(epoch FROM (s.delivered_at - s.created_at)))::bigint AS avg_transit_seconds,
    percentile_disc(0.95) WITHIN GROUP (
        ORDER BY extract(epoch FROM (s.delivered_at - s.created_at))
    )::bigint                                      AS p95_transit_seconds,
    sum(a.alert_count)                             AS excursion_alerts
FROM freight.shipments s
JOIN freight.facilities o ON o.facility_id = s.origin_facility_id
JOIN freight.facilities d ON d.facility_id = s.destination_facility_id
LEFT JOIN LATERAL (
    SELECT rl.mode
    FROM routing.routes r
    JOIN routing.route_legs rl ON rl.route_id = r.route_id
    WHERE r.shipment_id = s.shipment_id AND r.is_current
    ORDER BY rl.distance_m DESC
    LIMIT 1
) l ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS alert_count
    FROM telemetry.telemetry_alerts ta
    WHERE ta.shipment_id = s.shipment_id
) a ON true
WHERE s.status = 'delivered'
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX mv_lane_performance_daily_key
    ON analytics.mv_lane_performance_daily
       (tenant_id, business_date, origin_unlocode, destination_unlocode, primary_mode);

-- Second materialised view, weekly, feeding the "idle box" report in the web console.
CREATE MATERIALIZED VIEW analytics.mv_container_utilisation_weekly AS
SELECT
    c.container_id,
    c.iso_size_type,
    date_trunc('week', sc.loaded_at)::date        AS week_start,
    count(DISTINCT sc.shipment_id)                AS trips,
    sum(sc.gross_kg)                              AS total_gross_kg,
    max(c.max_gross_kg)                           AS max_gross_kg,
    round(100.0 * sum(sc.gross_kg) /
          nullif(count(DISTINCT sc.shipment_id) * max(c.max_gross_kg), 0), 2) AS fill_rate_pct
FROM freight.containers c
JOIN freight.shipment_containers sc ON sc.container_id = c.container_id
WHERE sc.loaded_at IS NOT NULL AND c.retired_at IS NULL
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX mv_container_utilisation_weekly_key
    ON analytics.mv_container_utilisation_weekly (container_id, week_start);
```

### 2.10 Table inventory

40 base tables and 2 materialised views:

`identity.tenants`, `identity.org_units`, `identity.users`, `identity.roles`,
`identity.user_role_grants`, `identity.api_credentials`, `identity.sessions`,
`fleet.carriers`, `fleet.vehicles`, `fleet.drivers`, `fleet.vehicle_assignments`, `fleet.depots`,
`freight.facilities`, `freight.containers`, `freight.hazard_classes`,
`freight.container_hazard_classes`, `freight.shipments`, `freight.shipment_containers`,
`freight.shipment_scan_events`, `routing.routes`, `routing.route_legs`, `geo.geofences`,
`geo.border_crossings`, `telemetry.device_gateways`, `telemetry.telemetry_readings` (+8 partitions),
`telemetry.telemetry_alerts`, `customs.customs_declarations`, `customs.declaration_line_items`,
`customs.tariff_schedules`, `billing.invoices`, `billing.invoice_lines`, `billing.payments`,
`platform.audit_ledger_entries`, `platform.document_owner_types`, `platform.documents`,
`platform.notifications`, `platform.notification_preferences`, `platform.outbox_messages`,
`analytics.reconciliation_runs`, `analytics.reconciliation_discrepancies`,
`analytics.mv_lane_performance_daily`, `analytics.mv_container_utilisation_weekly`.

---

## 3. Endpoints

Paths are exact. HTTP services mount everything under `/v1` except **partner-portal-api**, which
mounts under `/partner/v1` because it is exposed through a separate ingress with its own WAF rules.

### 3.1 identity-service (Go)

| Method | Path / RPC | Purpose |
|---|---|---|
| `POST` | `/v1/auth/token` | Exchange password+MFA or client credentials for an access/refresh pair |
| `POST` | `/v1/auth/token/refresh` | Rotate the refresh token; reuse kills the whole `refresh_family_id` |
| `POST` | `/v1/auth/token/revoke` | Revoke one session or an entire family |
| `GET` | `/v1/users/{user_id}` | Read one user |
| `GET` | `/v1/users/{user_id}/effective-roles` | Flattened grants including every inherited `org_units` ancestor |
| `POST` | `/v1/tenants/{tenant_id}/org-units` | Create an org unit; recomputes `materialised_path` |
| `PATCH` | `/v1/tenants/{tenant_id}/org-units/{org_unit_id}` | Rename or reparent; reparent rewrites the subtree |
| `POST` | `/v1/credentials` | Mint an API credential, returns the secret exactly once |
| `DELETE` | `/v1/credentials/{credential_id}` | Revoke; publishes `identity.credential.revoked` |
| `GET` | `/.well-known/jwks.json` | Public keys for offline verification (see the grace window in §1.2) |
| gRPC | `identity.v1.TokenIntrospection/Introspect` | The call every other service makes |
| gRPC | `identity.v1.TokenIntrospection/BatchIntrospect` | Up to 128 tokens; used by telemetry-ingest per batch |

### 3.2 fleet-service (Java)

| Method | Path / RPC | Purpose |
|---|---|---|
| gRPC | `fleet.v1.FleetService/Assign` | Reserve a vehicle+driver for a shipment leg; the exclusion constraint on `fleet.vehicle_assignments` is the arbiter |
| gRPC | `fleet.v1.FleetService/Release` | End an assignment, stamping `released_at` |
| gRPC | `fleet.v1.FleetService/CheckEligibility` | Licence, ADR and hours-of-service pre-check without reserving |
| `GET` | `/v1/vehicles/{vehicle_id}` | Read one vehicle |
| `GET` | `/v1/carriers/{carrier_id}/vehicles` | Roster, cursor-paginated |
| `GET` | `/v1/assignments` | Filter by `shipment_id`, `vehicle_id`, `driver_id`, `active=true` |
| `POST` | `/v1/drivers/{driver_id}/hours-of-service` | Append a duty-status change from the driver app |
| `GET` | `/v1/drivers/{driver_id}/availability` | Remaining drive time in the current window |

### 3.3 container-registry (Kotlin)

| Method | Path / RPC | Purpose |
|---|---|---|
| `POST` | `/v1/shipments` | Create a shipment; publishes `shipment.created` |
| `GET` | `/v1/shipments/{shipment_id}` | Read, with containers inlined |
| `PATCH` | `/v1/shipments/{shipment_id}/status` | The only legal state-transition path; publishes `shipment.status.changed` |
| `POST` | `/v1/shipments/{shipment_id}/containers` | Attach a container and its seal; rejected once status is `sealed` |
| `DELETE` | `/v1/shipments/{shipment_id}/containers/{container_id}` | Detach before sealing |
| `POST` | `/v1/containers` | Register a container by its BIC `iso_code` |
| `GET` | `/v1/containers/{container_id}` | Read, including `last_reading_at` |
| `GET` | `/v1/containers` | Filter by `iso_code`, `seal`, `shipment_id` |
| `POST` | `/v1/containers/{container_id}/scans` | Record a scan; publishes `shipment.scanned` |
| `GET` | `/v1/shipments/{shipment_id}/scans` | The scan trail, newest first |
| gRPC | `freight.v1.ContainerLookup/ResolveShipmentForContainer` | Hot path for telemetry-ingest |

### 3.4 telemetry-ingest (Rust)

| Method | Path / RPC | Purpose |
|---|---|---|
| `POST` | `/v1/ingest/batch` | Signed sensor batch from an edge gateway; dedupes on `ingest_batch_id` |
| gRPC | `telemetry.v1.TelemetryIngest/StreamReadings` | Client-streaming variant used by gateways with a stable link |
| `POST` | `/v1/gateways/{gateway_id}/heartbeat` | Liveness; silence past the threshold raises `gateway.heartbeat.missed` |
| `GET` | `/v1/containers/{container_id}/readings` | Time-window query against the region partition |
| `GET` | `/v1/alerts` | Filter by `state`, `rule_code`, `container_id`, `severity_min` |
| `POST` | `/v1/alerts/{alert_id}/acknowledge` | Stamp `acknowledged_by` / `acknowledged_at` |
| `POST` | `/v1/alerts/{alert_id}/close` | Close manually when the excursion is resolved on the ground |

### 3.5 routing-service (Python)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/routes/plan` | Plan version 1 for a shipment; writes `routing.routes` + `routing.route_legs` |
| `POST` | `/v1/routes/{route_id}/replan` | New version, flips `is_current`, publishes `route.replanned` |
| `GET` | `/v1/routes/{route_id}` | Read a route with its legs |
| `GET` | `/v1/shipments/{shipment_id}/route` | The current route only |
| `POST` | `/v1/eta/batch` | Up to 500 shipments, returns predicted arrival per leg |
| `GET` | `/v1/crossings/recommend` | Ranked border crossings for an origin/destination pair |

### 3.6 geo-service (C++)

| Method | Path / RPC | Purpose |
|---|---|---|
| gRPC | `geo.v1.GeoService/ResolveGeofence` | Fence by id, with the 30-second per-trace cache from §1.2 |
| gRPC | `geo.v1.GeoService/PointInFence` | Batch point-in-polygon with `buffer_m` applied |
| gRPC | `geo.v1.GeoService/DistanceMatrix` | Road-network distances for up to 64×64 points |
| gRPC | `geo.v1.GeoService/SnapToRoad` | Cleans GPS traces before they reach `mv_lane_performance_daily` |
| `GET` | `/v1/geofences/{geofence_id}` | GeoJSON representation for the console map |
| `POST` | `/v1/geofences` | Create a tenant fence |

### 3.7 customs-service (C#)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/declarations` | Draft a declaration for a shipment and crossing |
| `POST` | `/v1/declarations/{declaration_id}/lines` | Add or replace line items |
| `POST` | `/v1/declarations/{declaration_id}/file` | Submit to the authority; publishes `customs.declaration.filed` |
| `POST` | `/v1/declarations/{declaration_id}/amend` | Post-clearance amendment, keeps the same `mrn` |
| `GET` | `/v1/declarations/{declaration_id}` | Read, including assessed duty |
| `GET` | `/v1/shipments/{shipment_id}/declarations` | All declarations for a shipment |
| `GET` | `/v1/tariffs/lookup` | `?hs_code=&destination_country=&origin_country=&on_date=` — resolves one `customs.tariff_schedules` row |

### 3.8 billing-service (Ruby)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/invoices` | Draft an invoice for a shipment |
| `POST` | `/v1/invoices/{invoice_id}/lines` | Append charge lines |
| `POST` | `/v1/invoices/{invoice_id}/issue` | Assign `invoice_number`, publish `billing.invoice.issued` |
| `POST` | `/v1/invoices/{invoice_id}/payments` | Record a payment; settles when the balance reaches zero |
| `POST` | `/v1/invoices/{invoice_id}/void` | Void an issued invoice, requires a credit note document |
| `GET` | `/v1/invoices/{invoice_id}` | Read |
| `GET` | `/v1/tenants/{tenant_id}/invoices` | Filter by `status`, `due_before` |

### 3.9 document-service (TypeScript)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/documents` | Multipart upload; validates `owner_type` against `platform.document_owner_types` |
| `GET` | `/v1/documents/{document_id}` | Metadata only, never the bytes |
| `POST` | `/v1/documents/{document_id}/signed-url` | 15-minute download URL |
| `GET` | `/v1/documents` | `?owner_type=&owner_id=&kind=` |
| `DELETE` | `/v1/documents/{document_id}` | Soft delete; refused while `retained_until` is in the future |

### 3.10 notification-service (Elixir)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/notifications/dispatch` | Direct send, used by operators and by the console |
| `GET` | `/v1/users/{user_id}/preferences` | Read `platform.notification_preferences` |
| `PUT` | `/v1/users/{user_id}/preferences` | Replace the whole preference set |
| `GET` | `/v1/notifications` | `?state=&channel=&since=` for the delivery audit screen |

### 3.11 partner-portal-api (PHP)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/partner/v1/sessions` | Partner login against an `identity.api_credentials` key pair |
| `GET` | `/partner/v1/shipments` | Only shipments the partner's carrier or broker role touches |
| `GET` | `/partner/v1/shipments/{shipment_id}` | Redacted view — no `declared_value_minor` |
| `GET` | `/partner/v1/invoices/{invoice_id}` | Proxied from billing-service |
| `POST` | `/partner/v1/declarations/{declaration_id}/documents` | Broker uploads a certificate of origin |

### 3.12 audit-ledger (Go)

| Method | Path / RPC | Purpose |
|---|---|---|
| gRPC | `audit.v1.LedgerService/Append` | The only write path into `platform.audit_ledger_entries` |
| `GET` | `/v1/entries` | `?subject_type=&subject_id=&since=` |
| `GET` | `/v1/entries/{entry_id}/proof` | Merkle inclusion proof against the published checkpoint |
| `GET` | `/v1/checkpoints/latest` | Signed head, mirrored hourly to an external notary |

### 3.13 analytics-pipeline (Scala)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/v1/metrics/lane-performance` | Serves `analytics.mv_lane_performance_daily` |
| `GET` | `/v1/metrics/container-utilisation` | Serves `analytics.mv_container_utilisation_weekly` |
| `POST` | `/v1/jobs/{job_name}/run` | Trigger a batch job out of schedule |
| `GET` | `/v1/jobs/{run_id}` | Job status |

### 3.14 reconciliation-service (Clojure)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/runs` | Start a three-way match for a tenant and business date |
| `GET` | `/v1/runs/{run_id}` | Run status and counters |
| `GET` | `/v1/discrepancies` | `?state=open&kind=` |
| `POST` | `/v1/discrepancies/{discrepancy_id}/resolve` | Resolve or waive with a note |

### 3.15 Universal

Every service, without exception, exposes these on its HTTP port:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz` | Liveness — process is up. Never touches the database |
| `GET` | `/readyz` | Readiness — database, Kafka and identity-service reachable |
| `GET` | `/metrics` | Prometheus exposition |
| `GET` | `/version` | Build SHA, semver, and the schema migration number it expects |

---

## 4. Asynchronous events

Six Kafka topics. `partition_key` in the envelope (§0.7) determines ordering; anything keyed on
`shipment_id` is ordered per shipment, which is the only ordering guarantee the platform makes.

| Topic | Partitions | Retention | Producers |
|---|---|---|---|
| `of.identity.v1` | 12 | 30 d | identity-service |
| `of.freight.v1` | 48 | 14 d | container-registry, fleet-service |
| `of.telemetry.v1` | 96 | 7 d | telemetry-ingest |
| `of.customs.v1` | 12 | 90 d | customs-service |
| `of.billing.v1` | 12 | 90 d | billing-service |
| `of.platform.v1` | 24 | 30 d | document-service, notification-service, routing-service, reconciliation-service |

### 4.1 `identity.session.opened`
**Topic** `of.identity.v1` · **Publisher** identity-service · **Consumers** audit-ledger, analytics-pipeline
`session_id`, `user_id`, `tenant_id`, `actor_kind`, `ip_inet`, `user_agent`, `mfa_used` (bool), `issued_at`, `expires_at`

### 4.2 `identity.credential.revoked`
**Topic** `of.identity.v1` · **Publisher** identity-service · **Consumers** partner-portal-api, telemetry-ingest, audit-ledger
`credential_id`, `tenant_id`, `key_prefix`, `revoked_reason`, `revoked_at`, `revoked_by`
Consumers must evict their local introspection cache for the prefix within 5 seconds.

### 4.3 `shipment.created`
**Topic** `of.freight.v1` · **Publisher** container-registry · **Consumers** routing-service, billing-service, analytics-pipeline, audit-ledger
`shipment_id`, `tenant_id`, `reference`, `origin_facility_id`, `destination_facility_id`, `incoterm`, `sla_deadline_at`, `region_code`, `created_by`

### 4.4 `shipment.scanned`
**Topic** `of.freight.v1` · **Publisher** container-registry · **Consumers** notification-service, analytics-pipeline, billing-service, audit-ledger, reconciliation-service
`scan_id`, `shipment_id`, `container_id`, `scan_type`, `facility_id`, `scanned_by_user_id`, `occurred_at`, `recorded_at`, `position` (`{lat, lon}` or null), `device_serial`
billing-service only reacts to `scan_type = 'proof_of_delivery'`, which unlocks invoicing.

### 4.5 `shipment.status.changed`
**Topic** `of.freight.v1` · **Publisher** container-registry · **Consumers** notification-service, routing-service, customs-service, billing-service, analytics-pipeline, audit-ledger
`shipment_id`, `tenant_id`, `from_status`, `to_status`, `reason_code`, `changed_by`, `changed_at`

### 4.6 `fleet.assignment.created`
**Topic** `of.freight.v1` · **Publisher** fleet-service · **Consumers** notification-service, routing-service, billing-service, audit-ledger
`assignment_id`, `shipment_id`, `leg_id`, `vehicle_id`, `driver_id`, `carrier_id`, `assigned_at`, `assigned_by`

### 4.7 `fleet.assignment.released`
**Topic** `of.freight.v1` · **Publisher** fleet-service · **Consumers** billing-service, analytics-pipeline, audit-ledger
`assignment_id`, `shipment_id`, `vehicle_id`, `driver_id`, `released_at`, `distance_travelled_m`, `release_reason`

### 4.8 `telemetry.reading.recorded`
**Topic** `of.telemetry.v1` · **Publisher** telemetry-ingest · **Consumers** container-registry, analytics-pipeline
`reading_id`, `region_code`, `container_id`, `shipment_id`, `gateway_id`, `recorded_at`, `temperature_c`, `humidity_pct`, `shock_g`, `door_open`, `battery_pct`, `position`
Sampled: only every 20th reading per container is published, plus every reading that crossed a
threshold. container-registry consumes it purely to keep `freight.containers.last_reading_at` warm.

### 4.9 `telemetry.alert.raised`
**Topic** `of.telemetry.v1` · **Publisher** telemetry-ingest · **Consumers** container-registry, notification-service, billing-service, analytics-pipeline, audit-ledger
`alert_id`, `container_id`, `shipment_id`, `rule_code`, `severity`, `threshold_value`, `peak_value`, `first_reading_id`, `opened_at`
This is the edge that breaks the container-registry ↔ telemetry-ingest cycle: container-registry
flips the shipment to `at_risk` here rather than being called synchronously.

### 4.10 `gateway.heartbeat.missed`
**Topic** `of.telemetry.v1` · **Publisher** telemetry-ingest · **Consumers** notification-service, analytics-pipeline
`gateway_id`, `serial`, `depot_id`, `region_code`, `last_heartbeat_at`, `silent_minutes`, `firmware_version`

### 4.11 `route.replanned`
**Topic** `of.platform.v1` · **Publisher** routing-service · **Consumers** fleet-service, notification-service, container-registry, analytics-pipeline
`route_id`, `shipment_id`, `previous_version`, `version`, `strategy`, `reason_code`, `total_distance_m`, `total_duration_s`, `legs_changed` (array of `leg_id`), `computed_at`
fleet-service consumes this to release assignments whose `leg_id` no longer exists.

### 4.12 `customs.declaration.filed`
**Topic** `of.customs.v1` · **Publisher** customs-service · **Consumers** notification-service, container-registry, reconciliation-service, audit-ledger
`declaration_id`, `shipment_id`, `crossing_id`, `customs_office_code`, `direction`, `mrn`, `line_count`, `assessed_duty_minor`, `assessed_vat_minor`, `currency`, `filed_at`, `filed_by`

### 4.13 `customs.declaration.cleared`
**Topic** `of.customs.v1` · **Publisher** customs-service · **Consumers** billing-service, container-registry, notification-service, reconciliation-service, analytics-pipeline, audit-ledger
`declaration_id`, `shipment_id`, `mrn`, `cleared_at`, `assessed_duty_minor`, `assessed_vat_minor`, `currency`, `inspection_performed` (bool), `decision_document_id`
Half of the broken cycle in §1.2 — billing-service learns the final duty here instead of customs-service pushing it.

### 4.14 `billing.invoice.issued`
**Topic** `of.billing.v1` · **Publisher** billing-service · **Consumers** notification-service, partner-portal-api, reconciliation-service, analytics-pipeline, audit-ledger
`invoice_id`, `tenant_id`, `shipment_id`, `invoice_number`, `currency`, `subtotal_minor`, `duty_minor`, `tax_minor`, `total_minor`, `due_on`, `rendered_document_id`, `issued_at`

### 4.15 `billing.invoice.settled`
**Topic** `of.billing.v1` · **Publisher** billing-service · **Consumers** **customs-service**, reconciliation-service, notification-service, analytics-pipeline, audit-ledger
`invoice_id`, `tenant_id`, `shipment_id`, `declaration_id`, `total_minor`, `currency`, `settled_at`, `final_payment_id`
The other half of the broken cycle: this is the *only* way customs-service ever learns that duty
has been paid, and the only thing that sets `customs.customs_declarations.duty_paid`.

### 4.16 `document.uploaded`
**Topic** `of.platform.v1` · **Publisher** document-service · **Consumers** customs-service, billing-service, container-registry, audit-ledger
`document_id`, `tenant_id`, `owner_type`, `owner_id`, `kind`, `mime_type`, `byte_size`, `sha256` (hex), `region_code`, `uploaded_by`, `uploaded_at`

### 4.17 `reconciliation.discrepancy.opened`
**Topic** `of.platform.v1` · **Publisher** reconciliation-service · **Consumers** billing-service, notification-service, audit-ledger
`discrepancy_id`, `run_id`, `tenant_id`, `shipment_id`, `declaration_id`, `invoice_id`, `kind`, `expected_minor`, `observed_minor`, `currency`, `opened_at`
billing-service puts the invoice `on_hold` and writes `hold_reason` from `kind`. It must not call
reconciliation-service back.

### 4.18 `notification.delivery.failed`
**Topic** `of.platform.v1` · **Publisher** notification-service · **Consumers** analytics-pipeline, audit-ledger
`notification_id`, `tenant_id`, `recipient_user_id`, `channel`, `template_code`, `source_event_id`, `attempts`, `failed_reason`, `failed_at`

### 4.19 Consumer rules

1. **Idempotency on `event_id`.** At-least-once delivery is the contract; every consumer keeps a
   seen-set keyed on `event_id` for at least the topic retention window.
2. **No synchronous call back to the publisher inside the handler.** That is what re-creates the
   cycles §1.2 exists to break.
3. **Unknown fields are ignored, never rejected.** Producers add fields within a
   `schema_version`; only removals and type changes bump it.
4. **A poisoned message goes to `<topic>.dlq` after 8 attempts** with exponential backoff starting
   at 500 ms, and raises `gateway.heartbeat.missed`-style alerting through notification-service.

---

## 5. Environment variables

Every variable is prefixed `OF_`. A service that reads a variable not listed here fails startup —
`ops/validate-env.py` checks the running set against this section in the deploy pipeline.

**Address variables are shared names.** `OF_*_BASE_URL` and `OF_*_GRPC_ADDR` are listed once,
under the service that most obviously needs them, but they are set on **every** service that
appears as a caller of that target in §1.1. fleet-service therefore also reads `OF_GEO_GRPC_ADDR`
and `OF_DOCUMENT_BASE_URL`; telemetry-ingest reads `OF_CONTAINER_REGISTRY_GRPC_ADDR` and
`OF_GEO_GRPC_ADDR`; reconciliation-service reads `OF_BILLING_BASE_URL` and
`OF_AUDIT_LEDGER_GRPC_ADDR`. The spelling never changes with the caller.

### 5.1 Read by every service

| Variable | Example | Meaning |
|---|---|---|
| `OF_ENVIRONMENT` | `production` | `local` \| `ci` \| `staging` \| `production` |
| `OF_REGION_CODE` | `eu-west` | One of §0.6; stamped into every event envelope |
| `OF_SERVICE_NAME` | `container-registry` | Must match a name in §1 exactly |
| `OF_LOG_LEVEL` | `info` | `trace` \| `debug` \| `info` \| `warn` \| `error` |
| `OF_LOG_FORMAT` | `json` | `json` in every deployed environment, `text` locally |
| `OF_HTTP_PORT` | `8083` | The port from §1 |
| `OF_GRPC_PORT` | `9083` | Unset on services without a gRPC surface |
| `OF_DATABASE_URL` | `postgres://…` | Includes the search_path for the owning schema |
| `OF_DATABASE_MAX_CONNS` | `40` | Per pod, not per cluster |
| `OF_DATABASE_STATEMENT_TIMEOUT_MS` | `8000` | |
| `OF_KAFKA_BROKERS` | `kafka-0:9092,kafka-1:9092` | |
| `OF_KAFKA_CONSUMER_GROUP` | `container-registry-v3` | Bump the suffix to force a replay |
| `OF_OTEL_EXPORTER_ENDPOINT` | `http://otel-collector:4317` | |
| `OF_OTEL_SAMPLE_RATIO` | `0.05` | 1.0 on staging |
| `OF_IDENTITY_GRPC_ADDR` | `identity-service:9081` | Every service needs this — see §1.2 |
| `OF_IDENTITY_JWKS_URL` | `http://identity-service:8081/.well-known/jwks.json` | |
| `OF_IDENTITY_JWKS_GRACE_SECONDS` | `300` | How long a cached JWKS stays usable when identity-service is down |
| `OF_OUTBOX_RELAY_INTERVAL_MS` | `250` | Poll interval for `platform.outbox_messages` |
| `OF_SHUTDOWN_GRACE_SECONDS` | `25` | Must stay below the pod termination grace period |

### 5.2 identity-service

| Variable | Meaning |
|---|---|
| `OF_IDENTITY_SIGNING_KEY_PATH` | PEM of the current RS256 private key |
| `OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS` | `900` |
| `OF_IDENTITY_REFRESH_TOKEN_TTL_DAYS` | `30` |
| `OF_IDENTITY_ARGON2_MEMORY_KIB` | Cost parameter for `api_credentials.secret_hash` |
| `OF_IDENTITY_MFA_ISSUER` | Label shown in authenticator apps |
| `OF_IDENTITY_MAX_ORG_DEPTH` | Mirrors the `depth <= 12` check on `identity.org_units` |

### 5.3 fleet-service

| Variable | Meaning |
|---|---|
| `OF_FLEET_HOS_RULESET` | `eu_561` \| `us_fmcsa` \| `none` — which hours-of-service law applies |
| `OF_FLEET_ASSIGNMENT_LOCK_TIMEOUT_MS` | How long `FleetService/Assign` waits on the exclusion constraint |
| `OF_FLEET_LICENCE_EXPIRY_WARN_DAYS` | Drives the pre-expiry notification |
| `OF_ROUTING_BASE_URL` | `http://routing-service:8085` |
| `OF_CONTAINER_REGISTRY_GRPC_ADDR` | `container-registry:9083` |

### 5.4 container-registry

| Variable | Meaning |
|---|---|
| `OF_FREIGHT_SEAL_FORMAT_REGEX` | Validates `freight.shipment_containers.seal_number` |
| `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` | Max `recorded_at - occurred_at` before the scan is flagged |
| `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` | Minimum `telemetry.alert.raised` severity that flips a shipment to `at_risk` |
| `OF_GEO_GRPC_ADDR` | `geo-service:9086` |
| `OF_DOCUMENT_BASE_URL` | `http://document-service:8089` |

### 5.5 telemetry-ingest

| Variable | Meaning |
|---|---|
| `OF_TELEMETRY_BATCH_MAX_READINGS` | Hard cap per `POST /v1/ingest/batch` |
| `OF_TELEMETRY_SIGNATURE_REQUIRED` | `true` everywhere except `local` |
| `OF_TELEMETRY_PUBLISH_SAMPLE_RATE` | `20` — the sampling in §4.8 |
| `OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES` | Silence before `gateway.heartbeat.missed` |
| `OF_TELEMETRY_ALLOWED_REGIONS` | Comma list; a batch for another region is rejected `403`, not rerouted |
| `OF_TELEMETRY_RULES_PATH` | YAML of the `rule_code` thresholds |

### 5.6 routing-service

| Variable | Meaning |
|---|---|
| `OF_ROUTING_SOLVER_THREADS` | |
| `OF_ROUTING_MAX_LEGS` | Refuses to plan beyond this many legs |
| `OF_ROUTING_ETA_MODEL_PATH` | Serialised model fed by `analytics.mv_lane_performance_daily` |
| `OF_ROUTING_REPLAN_COOLDOWN_SECONDS` | Stops replan storms on a flapping route |
| `OF_CUSTOMS_BASE_URL` | `http://customs-service:8087` |

### 5.7 geo-service

| Variable | Meaning |
|---|---|
| `OF_GEO_ROAD_GRAPH_PATH` | Memory-mapped road network |
| `OF_GEO_FENCE_CACHE_TTL_SECONDS` | `30` — the per-trace cache in §1.2 |
| `OF_GEO_MATRIX_MAX_POINTS` | `64` |
| `OF_GEO_SIMPLIFY_TOLERANCE_M` | Polygon simplification before GeoJSON output |

### 5.8 customs-service

| Variable | Meaning |
|---|---|
| `OF_CUSTOMS_AUTHORITY_ENDPOINT` | The national filing gateway |
| `OF_CUSTOMS_AUTHORITY_CERT_PATH` | Client certificate for it |
| `OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS` | Safe to make long: `customs.tariff_schedules` rows are immutable |
| `OF_CUSTOMS_RETENTION_YEARS` | `10`; sets `platform.documents.retained_until` |
| `OF_AUDIT_LEDGER_GRPC_ADDR` | `audit-ledger:9092` |

### 5.9 billing-service

| Variable | Meaning |
|---|---|
| `OF_BILLING_INVOICE_NUMBER_FORMAT` | e.g. `OF-{tenant_short}-{year}-{seq:06d}` |
| `OF_BILLING_DEFAULT_PAYMENT_TERMS_DAYS` | Sets `billing.invoices.due_on` |
| `OF_BILLING_FX_RATE_SOURCE` | Rate provider id; rates are frozen on issue |
| `OF_BILLING_HOLD_ON_DISCREPANCY_KINDS` | Which `reconciliation.discrepancy.opened` kinds trigger a hold |
| `OF_FLEET_BASE_URL` | `http://fleet-service:8082` |

### 5.10 document-service

| Variable | Meaning |
|---|---|
| `OF_DOCUMENT_BUCKET` | Object-store bucket, one per region |
| `OF_DOCUMENT_KMS_KEY_ID` | Server-side encryption key |
| `OF_DOCUMENT_SIGNED_URL_TTL_SECONDS` | `900` |
| `OF_DOCUMENT_MAX_UPLOAD_BYTES` | |
| `OF_DOCUMENT_ALLOWED_MIME_TYPES` | Comma list; anything else is `415` |

### 5.11 notification-service

| Variable | Meaning |
|---|---|
| `OF_NOTIFY_SMTP_URL` | |
| `OF_NOTIFY_SMS_PROVIDER_TOKEN` | |
| `OF_NOTIFY_PUSH_APNS_KEY_PATH` | Drives the driver-ios app |
| `OF_NOTIFY_PUSH_FCM_KEY_PATH` | Drives the inspector-android app |
| `OF_NOTIFY_WEBHOOK_TIMEOUT_MS` | |
| `OF_NOTIFY_MAX_ATTEMPTS` | `8`, matching the DLQ rule in §4.19 |
| `OF_NOTIFY_TEMPLATE_DIR` | |

### 5.12 partner-portal-api

| Variable | Meaning |
|---|---|
| `OF_PARTNER_RATE_LIMIT_PER_MINUTE` | Per `key_prefix`, not per IP |
| `OF_PARTNER_SESSION_TTL_MINUTES` | |
| `OF_PARTNER_ALLOWED_ORIGINS` | CORS allow-list |
| `OF_BILLING_BASE_URL` | `http://billing-service:8088` |

### 5.13 analytics-pipeline

| Variable | Meaning |
|---|---|
| `OF_ANALYTICS_SPARK_MASTER` | |
| `OF_ANALYTICS_WAREHOUSE_URI` | Where the Parquet lands before the views are refreshed |
| `OF_ANALYTICS_MV_REFRESH_CRON` | `15 3 * * *` for `mv_lane_performance_daily` |
| `OF_ANALYTICS_READONLY_DATABASE_URL` | Uses the `of_analytics_ro` role from §2 |
| `OF_ANALYTICS_BACKFILL_DAYS` | |

### 5.14 audit-ledger

| Variable | Meaning |
|---|---|
| `OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES` | `60` |
| `OF_LEDGER_NOTARY_ENDPOINT` | External mirror for the signed head |
| `OF_LEDGER_HASH_ALGORITHM` | `sha256`; changing it starts a new chain, never rewrites |

### 5.15 reconciliation-service

| Variable | Meaning |
|---|---|
| `OF_RECON_TOLERANCE_MINOR` | Amounts within this are not discrepancies |
| `OF_RECON_ENGINE_VERSION` | Written to `analytics.reconciliation_runs.engine_version` |
| `OF_RECON_LOOKBACK_DAYS` | |
| `OF_ANALYTICS_BASE_URL` | `http://analytics-pipeline:8093` |

---

## 6. Directory layout

The platform is one repository. Each directory has exactly one owning team, and each team writes
its comments and documentation in its own working language — the result of the 2023 merger, and
deliberately left alone since. Identifiers, log messages and anything on the wire are English
everywhere; only prose comments follow the column below.

> **§6.1 and §6.2 below specify the whole platform. This repository ships an implemented subset of
> it, and the two do not match row for row.** §6.0 is the map from one to the other, and it is
> derived from the tree rather than declared: `python3 check_spec.py` walks every path, service and
> language named in this document and reports which resolve. Read §6.0 before measuring anything
> against this corpus, and run the checker before believing either.

### 6.0 What is actually in this repository

**Six of the fourteen services in §1 are implemented.** The other eight exist as an OpenAPI document
under `contracts/openapi/` and are referenced by name from the six that are implemented — which is
the point of the arrangement rather than an accident: a tool pointed at this corpus has to say
something useful about a service it can only see through its contract AND about one it can read line
by line, and those two answers should not come out looking the same.

**The six that ship do not all use the name, language or comment language §6.2 gives them.** That is
recorded here rather than corrected in §6.2, because §6.2 is the specification and these are the
directories as built:

| Directory | Names itself | Programming language | Comment language |
|---|---|---|---|
| `services/events/` | event-backbone | Elixir (+ Scala) | Russian |
| `services/fleet/` | fleet-service | Java (+ a Kotlin SDK) | Korean |
| `services/portal/` | portal | Ruby (+ PHP) | French |
| `services/pricing/` | pricing-service | Python | Thai |
| `services/routing/` | routing-service | Go | Vietnamese |
| `services/warehouse/` | warehouse-service | C# | Polish |

`pricing-service`, `warehouse-service` and `event-backbone` are **not named anywhere in §1**, and
`services/portal/` is not the `services/partner-portal/` of §6.2. §7 rule 1 says names come from
this file; these four are the standing exceptions to it, and they are the only ones.

**Twelve of the fourteen paths in §6.2 are not built.** Each of the fourteen services still has an
OpenAPI document under `contracts/openapi/`, and the code that IS built calls them by the names §1
gives them — `services/warehouse/` consumes from container-registry, telemetry-ingest and
customs-service, none of which exist here as code. The unbuilt paths, so that a checker can tell a
declared absence from a broken reference:

`services/identity/` · `services/container-registry/` · `services/telemetry-ingest/` ·
`services/geo/` · `services/customs/` · `services/billing/` · `services/document/` ·
`services/notification/` · `services/partner-portal/` · `services/analytics/` ·
`services/audit-ledger/` · `services/reconciliation/`

Only `services/fleet/` and `services/routing/` resolve as §6.2 writes them, and `services/routing/`
is Go with Vietnamese comments rather than the Python with Spanish comments §6.2 gives it.

**Of the thirteen top-level directories in §6.1, eight exist**: `services/`, `apps/`, `web/`,
`edge/`, `firmware/`, `db/`, `ops/`, `contracts/`. `libs/`, `pipelines/`, `infra/`, `tools/` and
`docs/` are specified and not built — the Kubernetes, Terraform and Helm manifests §6.1 puts in
`infra/` are in `ops/` and `deploy/` instead.

**Three directories exist that §6.1 does not mention**, and each is here for a reason that has
nothing to do with the platform:

| Directory | Why it is here |
|---|---|
| `deploy/` | Docker Compose, and one Dockerfile per runtime — including runtimes no service here is written in |
| `legacy/` | the system this one replaced. Contains Python 2 that a current interpreter cannot parse, on purpose |
| `secrets-and-config/` | the planted credentials, in the ten directories they leaked into. Two of the ten are near-misses that must NOT be redacted |


### 6.1 Top-level

| Directory | Contents | Programming language | Comment language | Doc convention |
|---|---|---|---|---|
| `services/` | the fourteen backend services — see §6.2 | mixed | per service | per service |
| `apps/` | the two mobile clients | Swift, Kotlin | per app | headerdoc / KDoc |
| `web/` | the operator console | TypeScript + React | Turkish | TSDoc |
| `edge/` | the depot gateway agent that batches sensor data upstream | Rust | Danish | rustdoc |
| `firmware/` | the container sensor node, bare metal | C11 | Greek | Doxygen |
| `libs/` | shared protobuf/IDL definitions and generated stubs | Protobuf, mixed | English | proto comments |
| `db/` | migrations, seed data, the DDL in §2 as executable files | SQL | Thai | `--` block header |
| `pipelines/` | dbt models feeding the `analytics` schema | SQL + Jinja | Hindi | dbt `.yml` descriptions |
| `infra/` | Kubernetes manifests, Terraform modules, Kafka topic definitions | HCL, YAML | Romanian | `#` block header |
| `ops/` | runbooks, deploy scripts, `validate-env.py` from §5 | Bash + Python | Indonesian | docstrings |
| `contracts/` | OpenAPI 3.1 documents generated from §3 and checked in | YAML | Simplified Chinese | OpenAPI `description` |
| `tools/` | load generators, fixture builders, the ledger verifier | Python | Arabic | docstrings |
| `docs/` | architecture decision records, onboarding | Markdown | English | — |

### 6.2 `services/`

| Directory | Service | Programming language | Comment language | Doc convention |
|---|---|---|---|---|
| `services/identity/` | identity-service | Go 1.22 | Japanese | godoc |
| `services/fleet/` | fleet-service | Java 21 | German | Javadoc |
| `services/container-registry/` | container-registry | Kotlin 1.9 | Korean | KDoc |
| `services/telemetry-ingest/` | telemetry-ingest | Rust 1.77 | Russian | rustdoc |
| `services/routing/` | routing-service | Python 3.12 | Spanish | Google-style docstrings |
| `services/geo/` | geo-service | C++20 | Czech | Doxygen |
| `services/customs/` | customs-service | C# / .NET 8 | Polish | XML doc comments |
| `services/billing/` | billing-service | Ruby 3.3 | Brazilian Portuguese | YARD |
| `services/document/` | document-service | TypeScript (Node 20) | Dutch | TSDoc |
| `services/notification/` | notification-service | Elixir 1.16 | Finnish | `@moduledoc` / `@doc` |
| `services/partner-portal/` | partner-portal-api | PHP 8.3 | French | PHPDoc |
| `services/analytics/` | analytics-pipeline | Scala 2.13 | Italian | Scaladoc |
| `services/audit-ledger/` | audit-ledger | Go 1.22 | Ukrainian | godoc |
| `services/reconciliation/` | reconciliation-service | Clojure 1.11 | Swedish | docstrings + `^{:doc}` metadata |

### 6.3 `apps/`

| Directory | App | Programming language | Comment language | Doc convention |
|---|---|---|---|---|
| `apps/driver-ios/` | Driver app — accepts assignments from `fleet.v1.FleetService/Assign`, posts scans and hours-of-service | Swift 5.9 | Norwegian Bokmål | Swift documentation comments |
| `apps/inspector-android/` | Depot inspector app — seal checks, damage photos into document-service | Kotlin 1.9 | Vietnamese | KDoc |

### 6.4 Conventions that cross directories

- Every source file opens with a header comment stating **what the file is for** in its
  directory's comment language — its job in the system, not a restatement of the filename.
- Cross-references are written with the exact names in this document: service names in
  `kebab-case`, RPCs as `package.v1.Service/Method`, tables as `schema.table`, events as
  `dotted.lower.case`, environment variables in `SCREAMING_SNAKE_CASE`.
- Generated code lives under `**/gen/` and is never edited by hand; those files carry the
  generator's own banner instead of a language header.

---

## 7. Rules for implementers

1. **Names come from this file.** A service, table, column, endpoint, event or variable that is
   not written here does not exist. Adding one means editing §1–§6 first.
2. **No service reads another service's schema.** The single exception is analytics-pipeline with
   its read-only role. A join across schemas in application code is a bug.
3. **State changes and their events are one transaction**, via `platform.outbox_messages`. There
   is no code path that publishes to Kafka and writes to Postgres separately.
4. **Money never leaves a service as a float**, and never without its `currency`.
5. **Every mutating request is idempotent** on `X-OF-Idempotency-Key`, kept for 24 hours.
6. **Anything that touches customs, duty, or the ledger is appended, never updated.** Corrections
   are new rows: an amendment on `customs.customs_declarations`, a credit note in `billing`, a
   compensating entry in `platform.audit_ledger_entries`.
7. **Region is data residency, not sharding.** A reading, document or shipment tagged `latam-br`
   is never written to, cached in, or logged from another region.
8. **Do not add a synchronous edge that closes a cycle in §1.1.** If two services appear to need
   each other, one of them consumes an event instead. There are three such edges today and they
   are listed in §1.2.
