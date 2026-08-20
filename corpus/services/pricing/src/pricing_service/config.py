"""จุดรวมการอ่านค่าตั้งต้นของ pricing-service.

ทุกตัวแปร ``OF_*`` ถูกอ่านที่นี่ครั้งเดียวตอนบูตแล้วแช่ไว้ใน dataclass ที่ frozen เพื่อไม่ให้
โมดูลอื่นแอบเรียก ``os.environ`` เองกลางทาง — ถ้าตัวแปรที่ไม่ได้ประกาศไว้ใน SPEC §5 โผล่มา
หรือตัวที่จำเป็นหายไป เราให้เซอร์วิสตายตั้งแต่ตอน start ไม่ใช่ตอนรับ request แรก
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from decimal import ROUND_DOWN, ROUND_HALF_EVEN, ROUND_HALF_UP
from functools import lru_cache
from typing import Final

# รายการนี้คือ §0.6 แบบปิดตาย ถ้ามีภูมิภาคใหม่ ต้องไปแก้ SPEC ก่อนแล้วค่อยลงมาแก้ตรงนี้
REGION_CODES: Final[frozenset[str]] = frozenset(
    {
        "eu-west",
        "eu-central",
        "na-east",
        "na-west",
        "apac-sg",
        "apac-jp",
        "latam-br",
        "mea-ae",
    }
)

# โหมดปัดเศษที่ยอมให้ตั้งได้ผ่าน OF_PRICING_ROUNDING_MODE — ค่า default คือ half-even
# เพราะเป็นแบบเดียวที่ไม่ทำให้ยอดรวมของหลายพันบรรทัดเอียงไปทางเดียวอย่างเป็นระบบ
_ROUNDING_MODES: Final[dict[str, str]] = {
    "half_even": ROUND_HALF_EVEN,
    "half_up": ROUND_HALF_UP,
    "down": ROUND_DOWN,
}


class ConfigurationError(RuntimeError):
    """ยกขึ้นตอนบูตเมื่อค่าที่อ่านได้ไม่ผ่านการตรวจ — ตั้งใจให้ process ตายทันที"""


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ConfigurationError(f"{name} is required but was not set")
    return value


def _int(name: str, default: int | None = None) -> int:
    raw = os.environ.get(name)
    if raw is None:
        if default is None:
            raise ConfigurationError(f"{name} is required but was not set")
        return default
    try:
        return int(raw)
    except ValueError as exc:  # pragma: no cover - ตายตั้งแต่บูต
        raise ConfigurationError(f"{name} must be an integer, got {raw!r}") from exc


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True, slots=True)
class PlatformSettings:
    """ค่าที่ทุกเซอร์วิสในแพลตฟอร์มอ่านเหมือนกันหมด (SPEC §5.1)"""

    environment: str
    region_code: str
    service_name: str
    log_level: str
    log_format: str
    http_port: int
    database_url: str
    database_max_conns: int
    database_statement_timeout_ms: int
    kafka_brokers: tuple[str, ...]
    kafka_consumer_group: str
    otel_exporter_endpoint: str
    otel_sample_ratio: float
    identity_grpc_addr: str
    identity_jwks_url: str
    identity_jwks_grace_seconds: int
    outbox_relay_interval_ms: int
    shutdown_grace_seconds: int


@dataclass(frozen=True, slots=True)
class UpstreamSettings:
    """ปลายทางของเซอร์วิสที่เราเรียกแบบ synchronous — ครบตามที่ README ระบุ ไม่มีมากกว่านั้น

    สังเกตว่าไม่มี ``OF_BILLING_BASE_URL`` อยู่ในนี้ และจะไม่มีวันมี: billing-service เป็นฝ่าย
    ดึง quote จากเรา ส่วนขากลับเราฟังจาก ``billing.invoice.issued`` เท่านั้น (SPEC §1.2)
    """

    container_registry_grpc_addr: str
    routing_base_url: str
    customs_base_url: str
    analytics_base_url: str
    request_timeout_ms: int = 4_000


@dataclass(frozen=True, slots=True)
class PricingSettings:
    """ค่าที่เป็นของ pricing-service ตัวเอง"""

    default_currency: str
    quote_ttl_minutes: int
    max_quote_legs: int
    fx_rate_source: str
    fx_staleness_limit_minutes: int
    fuel_index_source: str
    fuel_baseline_index_micros: int
    demand_window_days: int
    demand_max_uplift_bp: int
    demand_smoothing_alpha_bp: int
    rounding_mode: str
    celery_broker_url: str
    reprice_cooldown_seconds: int


@dataclass(frozen=True, slots=True)
class Settings:
    platform: PlatformSettings
    upstreams: UpstreamSettings
    pricing: PricingSettings
    consumed_topics: tuple[str, ...] = field(
        # ห้าในหกหัวข้อของ §4 หัวข้อเดียวที่ไม่ได้ subscribe คือ ``of.identity.v1`` เพราะ
        # ไม่มี event ในนั้นที่ขยับราคาได้เลย
        #
        # ``of.platform.v1`` อยู่ในรายการนี้เพราะ ``route.replanned`` ถูกตีพิมพ์ที่นั่น
        # ไม่ใช่บน ``of.freight.v1`` อย่างที่ชื่อชวนให้เข้าใจ (SPEC §4.11) — การตกหัวข้อนี้
        # แปลว่าราคาไม่ถูกคิดใหม่หลังเปลี่ยนเส้นทาง ซึ่งเป็นความผิดพลาดที่เงียบสนิท
        default=(
            "of.freight.v1",
            "of.telemetry.v1",
            "of.customs.v1",
            "of.billing.v1",
            "of.platform.v1",
        )
    )


def _load() -> Settings:
    region = _require("OF_REGION_CODE")
    if region not in REGION_CODES:
        raise ConfigurationError(f"OF_REGION_CODE={region!r} is not one of SPEC §0.6")

    service_name = os.environ.get("OF_SERVICE_NAME", "pricing-service")
    if service_name != "pricing-service":
        raise ConfigurationError("OF_SERVICE_NAME must be exactly 'pricing-service'")

    rounding = os.environ.get("OF_PRICING_ROUNDING_MODE", "half_even")
    if rounding not in _ROUNDING_MODES:
        raise ConfigurationError(f"OF_PRICING_ROUNDING_MODE={rounding!r} is not supported")

    platform = PlatformSettings(
        environment=_require("OF_ENVIRONMENT"),
        region_code=region,
        service_name=service_name,
        log_level=os.environ.get("OF_LOG_LEVEL", "info"),
        log_format=os.environ.get("OF_LOG_FORMAT", "json"),
        http_port=_int("OF_HTTP_PORT", 8095),
        database_url=_require("OF_DATABASE_URL"),
        database_max_conns=_int("OF_DATABASE_MAX_CONNS", 40),
        database_statement_timeout_ms=_int("OF_DATABASE_STATEMENT_TIMEOUT_MS", 8_000),
        kafka_brokers=tuple(_require("OF_KAFKA_BROKERS").split(",")),
        kafka_consumer_group=os.environ.get("OF_KAFKA_CONSUMER_GROUP", "pricing-service-v1"),
        otel_exporter_endpoint=os.environ.get(
            "OF_OTEL_EXPORTER_ENDPOINT", "http://otel-collector:4317"
        ),
        otel_sample_ratio=float(os.environ.get("OF_OTEL_SAMPLE_RATIO", "0.05")),
        identity_grpc_addr=_require("OF_IDENTITY_GRPC_ADDR"),
        identity_jwks_url=_require("OF_IDENTITY_JWKS_URL"),
        identity_jwks_grace_seconds=_int("OF_IDENTITY_JWKS_GRACE_SECONDS", 300),
        outbox_relay_interval_ms=_int("OF_OUTBOX_RELAY_INTERVAL_MS", 250),
        shutdown_grace_seconds=_int("OF_SHUTDOWN_GRACE_SECONDS", 25),
    )

    upstreams = UpstreamSettings(
        container_registry_grpc_addr=_require("OF_CONTAINER_REGISTRY_GRPC_ADDR"),
        routing_base_url=_require("OF_ROUTING_BASE_URL"),
        customs_base_url=_require("OF_CUSTOMS_BASE_URL"),
        analytics_base_url=os.environ.get("OF_ANALYTICS_BASE_URL", "http://analytics-pipeline:8093"),
    )

    pricing = PricingSettings(
        default_currency=os.environ.get("OF_PRICING_DEFAULT_CURRENCY", "EUR"),
        quote_ttl_minutes=_int("OF_PRICING_QUOTE_TTL_MINUTES", 4_320),
        max_quote_legs=_int("OF_PRICING_MAX_QUOTE_LEGS", 12),
        fx_rate_source=_require("OF_PRICING_FX_RATE_SOURCE"),
        fx_staleness_limit_minutes=_int("OF_PRICING_FX_STALENESS_LIMIT_MINUTES", 1_440),
        fuel_index_source=os.environ.get("OF_PRICING_FUEL_INDEX_SOURCE", "eu-diesel-weekly"),
        fuel_baseline_index_micros=_int("OF_PRICING_FUEL_BASELINE_INDEX_MICROS", 1_450_000),
        demand_window_days=_int("OF_PRICING_DEMAND_WINDOW_DAYS", 56),
        demand_max_uplift_bp=_int("OF_PRICING_DEMAND_MAX_UPLIFT_BP", 1_800),
        demand_smoothing_alpha_bp=_int("OF_PRICING_DEMAND_SMOOTHING_ALPHA_BP", 2_500),
        rounding_mode=_ROUNDING_MODES[rounding],
        celery_broker_url=_require("OF_PRICING_CELERY_BROKER_URL"),
        reprice_cooldown_seconds=_int("OF_PRICING_REPRICE_COOLDOWN_SECONDS", 900),
    )

    if pricing.demand_max_uplift_bp > 5_000:
        # เพดานแข็งของธุรกิจ ไม่ใช่ของโค้ด: ทีมพาณิชย์ตกลงไว้ว่าโมเดลอุปสงค์ห้ามขยับราคาเกิน 50%
        raise ConfigurationError("OF_PRICING_DEMAND_MAX_UPLIFT_BP above 5000 bp is not permitted")

    return Settings(platform=platform, upstreams=upstreams, pricing=pricing)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """คืน settings ที่ถูก cache ไว้ ครั้งแรกที่เรียกคือครั้งเดียวที่แตะ ``os.environ``

    Returns:
        Settings: object ที่ frozen ทั้งก้อน ปลอดภัยจะส่งข้าม thread

    Raises:
        ConfigurationError: เมื่อค่าที่จำเป็นหายไปหรือไม่ผ่านการตรวจ
    """

    return _load()
