"""ประกาศมาตรวัด Prometheus ทุกตัวของ pricing-service ไว้ที่เดียว

รวมไว้ตรงนี้เพราะ metric ที่ประกาศซ้ำใน registry เดียวกันจะทำให้ ``prometheus_client``
โยน ``ValueError`` ตอน import ซึ่งแปลว่า worker ตายเงียบ ๆ ตั้งแต่ยังไม่ทันรับงาน —
เคยเกิดมาแล้วตอนแยก consumer ออกจาก celery app
"""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

REGISTRY = CollectorRegistry(auto_describe=True)

# หน่วยเป็นวินาที ตาม convention ของ Prometheus ไม่ใช่มิลลิวินาทีแบบที่ตัวแปร OF_*_MS ใช้
HTTP_REQUEST_SECONDS = Histogram(
    "of_pricing_http_request_seconds",
    "Latency of HTTP requests handled by pricing-service",
    labelnames=("method", "route", "status"),
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
    registry=REGISTRY,
)

QUOTES_RATED = Counter(
    "of_pricing_quotes_rated_total",
    "Quotes produced by the rating engine, by outcome",
    labelnames=("outcome", "strategy"),
    registry=REGISTRY,
)

CHARGE_LINES_EMITTED = Counter(
    "of_pricing_charge_lines_total",
    "Charge lines emitted, keyed by the billing.invoice_lines charge_code they map to",
    labelnames=("charge_code",),
    registry=REGISTRY,
)

UPSTREAM_CALL_SECONDS = Histogram(
    "of_pricing_upstream_call_seconds",
    "Time spent in synchronous calls to other services",
    labelnames=("service", "operation", "outcome"),
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0),
    registry=REGISTRY,
)

FX_RATE_AGE_SECONDS = Gauge(
    "of_pricing_fx_rate_age_seconds",
    "Age of the newest usable rate per currency pair",
    labelnames=("base_currency", "quote_currency"),
    registry=REGISTRY,
)

DEMAND_UPLIFT_BP = Histogram(
    "of_pricing_demand_uplift_bp",
    "Uplift the demand model applied, in basis points",
    labelnames=("lane",),
    buckets=(0, 100, 250, 500, 900, 1200, 1500, 1800),
    registry=REGISTRY,
)

EVENTS_CONSUMED = Counter(
    "of_pricing_events_consumed_total",
    "Kafka envelopes handled, by event_name and disposition",
    labelnames=("event_name", "disposition"),
    registry=REGISTRY,
)

OUTBOX_PENDING = Gauge(
    "of_pricing_outbox_pending",
    "Rows in platform.outbox_messages produced by pricing-service and not yet published",
    registry=REGISTRY,
)


def observe_http_request(method: str, route: str, status: int, duration_seconds: float) -> None:
    """บันทึกหนึ่ง request — เรียกจาก middleware ใน ``main.py`` เท่านั้น

    Args:
        method: HTTP method ตัวใหญ่
        route: **route template** เช่น ``/v1/quotes/{quote_id}`` ไม่ใช่ path จริง มิฉะนั้น
            ``quote_id`` ทุกใบจะกลายเป็น label ใหม่และ cardinality จะระเบิด
        status: รหัสสถานะที่ตอบกลับไป
        duration_seconds: เวลาที่ใช้ทั้งคำขอ วัดจาก ``time.perf_counter`` ใน middleware
    """

    HTTP_REQUEST_SECONDS.labels(method=method, route=route, status=str(status)).observe(
        duration_seconds
    )
