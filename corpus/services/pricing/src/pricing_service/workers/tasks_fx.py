"""งานที่ดูแล "สภาพตลาด": ดึงอัตราแลกเปลี่ยน, ดึงดัชนีน้ำมัน และเติมสถิติอุปสงค์รายวัน

ทั้งสามงานเป็นงานเติมข้อมูล ไม่ใช่งานคิดราคา ถ้างานใดล้ม ราคาก็ยังคิดได้ด้วยข้อมูลเดิม —
จนกว่าจะเก่าเกิน ``OF_PRICING_FX_STALENESS_LIMIT_MINUTES`` ซึ่งตอนนั้น quote ข้ามสกุล
จะตอบ ``currency_pair_unavailable`` แทนที่จะเสนอราคาด้วยอัตราที่ไม่มีใครยืนยันแล้ว
"""

from __future__ import annotations

import datetime as dt
import logging

import httpx
from celery.utils.log import get_task_logger
from sqlalchemy import select

from pricing_service.clients.analytics import AnalyticsClient
from pricing_service.config import get_settings
from pricing_service.context import RequestContext, new_trace_id, scoped
from pricing_service.db.models_market import DemandObservation, FuelIndexPoint, FxRate
from pricing_service.db.session import session_scope
from pricing_service.metrics import FX_RATE_AGE_SECONDS
from pricing_service.workers.celery_app import app

log: logging.Logger = get_task_logger(__name__)

# สกุลที่เราต้องมีอัตราเสมอ ครอบคลุมทั้งแปดภูมิภาคของ §0.6
TRACKED_CURRENCIES = ("EUR", "USD", "GBP", "SGD", "JPY", "BRL", "AED", "CHF", "PLN", "SEK")


def _service_context(tenant_id: str = "tnt_00000000000000000000000000") -> RequestContext:
    """บริบทของงานเบื้องหลัง — actor เป็น ``service`` และ trace เกิดใหม่ตรงนี้

    tenant ปลอมถูกใช้สำหรับงานที่ไม่ได้ทำให้ tenant ใดโดยเฉพาะ (อัตราแลกเปลี่ยนเป็นของกลาง)
    ส่วนงานที่แตะข้อมูลของ tenant จริงจะส่ง ``tenant_id`` ที่ถูกต้องเข้ามาเสมอ
    """

    return RequestContext(
        tenant_id=tenant_id,
        trace_id=new_trace_id(),
        actor_kind="service",
        actor_id="svc:pricing-service",
    )


@app.task(name="pricing.refresh_fx_rates", bind=True, max_retries=3, default_retry_delay=120)
def refresh_fx_rates(self) -> dict[str, int]:  # type: ignore[no-untyped-def]
    """ดึงอัตราชุดล่าสุดจากผู้ให้บริการที่ ``OF_PRICING_FX_RATE_SOURCE`` ระบุ แล้ว insert

    Returns:
        dict: ``{"inserted": N, "pairs": M}``

    เป็น insert ล้วนเช่นเดียวกับปลายทาง HTTP — อัตราเก่าคือหลักฐานของ quote เก่า
    การเขียนทับจะทำให้เราตอบไม่ได้ว่าราคาที่เสนอไปเมื่อวานคำนวณจากอะไร
    """

    settings = get_settings()
    now = dt.datetime.now(dt.UTC)
    inserted = 0

    with scoped(_service_context()):
        try:
            response = httpx.get(
                f"https://rates.internal.orbitalfreight.net/v2/{settings.pricing.fx_rate_source}",
                params={"base": "EUR", "symbols": ",".join(TRACKED_CURRENCIES)},
                timeout=10.0,
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            log.warning("fx provider %s unreachable: %s", settings.pricing.fx_rate_source, exc)
            raise self.retry(exc=exc)

        quotes = response.json().get("rates", {})
        with session_scope() as session:
            for symbol, rate in quotes.items():
                if symbol == "EUR":
                    continue
                # ผู้ให้บริการส่งมาเป็นทศนิยม เราคูณหนึ่งล้านแล้วปัดทันที ค่านี้จะไม่เป็น float
                # อีกเลยหลังบรรทัดนี้
                rate_micros = int(round(float(rate) * 1_000_000))
                if rate_micros <= 0:
                    log.warning("provider returned non-positive rate for EUR->%s", symbol)
                    continue
                session.add(
                    FxRate(
                        base_currency="EUR",
                        quote_currency=symbol,
                        rate_micros=rate_micros,
                        source=settings.pricing.fx_rate_source,
                        observed_at=now,
                    )
                )
                FX_RATE_AGE_SECONDS.labels(base_currency="EUR", quote_currency=symbol).set(0)
                inserted += 1

    log.info("refreshed %d fx rates from %s", inserted, settings.pricing.fx_rate_source)
    return {"inserted": inserted, "pairs": len(quotes)}


@app.task(name="pricing.ingest_fuel_index", bind=True, max_retries=2, default_retry_delay=600)
def ingest_fuel_index(self) -> dict[str, int]:  # type: ignore[no-untyped-def]
    """ดึงดัชนีน้ำมันรายสัปดาห์ของทุกภูมิภาคที่เราให้บริการ

    ค่าที่ได้ไปอยู่ใน ``pricing.fuel_index_points`` และถูกใช้โดย ``engine.surcharges``
    ผ่านสูตรส่วนต่างจาก ``OF_PRICING_FUEL_BASELINE_INDEX_MICROS``
    """

    settings = get_settings()
    region = settings.platform.region_code
    today = dt.date.today()
    # ดัชนีมีผลตั้งแต่วันจันทร์ของสัปดาห์นั้น ไม่ใช่วันที่ประกาศ
    effective_on = today - dt.timedelta(days=today.weekday())

    with scoped(_service_context()):
        try:
            response = httpx.get(
                f"https://fuel.internal.orbitalfreight.net/v1/{settings.pricing.fuel_index_source}",
                params={"region": region, "week_of": effective_on.isoformat()},
                timeout=10.0,
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            log.warning("fuel index source unreachable: %s", exc)
            raise self.retry(exc=exc)

        index_micros = int(round(float(response.json()["index"]) * 1_000_000))
        with session_scope() as session:
            existing = (
                session.query(FuelIndexPoint)
                .filter_by(
                    region_code=region,
                    source=settings.pricing.fuel_index_source,
                    effective_on=effective_on,
                )
                .one_or_none()
            )
            if existing is not None:
                log.info("fuel index for %s week %s already stored", region, effective_on)
                return {"inserted": 0, "index_micros": existing.index_micros}
            session.add(
                FuelIndexPoint(
                    region_code=region,
                    source=settings.pricing.fuel_index_source,
                    effective_on=effective_on,
                    index_micros=index_micros,
                )
            )
    return {"inserted": 1, "index_micros": index_micros}


@app.task(name="pricing.ingest_demand", bind=True, max_retries=2, default_retry_delay=900)
def ingest_demand(self, tenant_id: str, business_date: str | None = None) -> dict[str, int]:  # type: ignore[no-untyped-def]
    """ดึงสถิติเลนของเมื่อวานจาก analytics-pipeline แล้วเก็บลง ``pricing.demand_observations``

    Args:
        tenant_id: tenant ที่จะดึง — งานถูกแตกเป็นหนึ่งงานต่อหนึ่ง tenant โดย beat
        business_date: ``YYYY-MM-DD`` ปกติปล่อยว่างแล้วใช้เมื่อวาน

    Returns:
        dict: จำนวนแถวที่เพิ่มใหม่ กับจำนวนแถวที่มีอยู่แล้วและถูกข้าม

    ปลายทางที่เรียกคือ ``GET /v1/metrics/lane-performance`` ซึ่งเสิร์ฟ
    ``analytics.mv_lane_performance_daily`` โดยตรง เราไม่ query สคีมา ``analytics`` เอง
    ถึงจะอยู่ในคลัสเตอร์เดียวกัน — role ``of_analytics_ro`` เป็นของ analytics-pipeline คนเดียว
    (SPEC §2 และกติกา §7.2)

    งานนี้ถูกตั้งเวลาไว้ 04:00 UTC ทั้งที่ ``OF_ANALYTICS_MV_REFRESH_CRON`` คือ 03:15 —
    สี่สิบห้านาทีนั้นคือระยะเผื่อสำหรับรอบ ``REFRESH ... CONCURRENTLY`` ที่ยาวกว่าปกติ
    ถ้าดึงเร็วกว่านั้นเราจะได้ตัวเลขของเมื่อวานซืนโดยไม่มีอะไรบอกว่าผิด
    """

    settings = get_settings()
    target = (
        dt.date.fromisoformat(business_date)
        if business_date
        else dt.date.today() - dt.timedelta(days=1)
    )
    stored = 0
    skipped = 0

    with scoped(_service_context(tenant_id)):
        client = AnalyticsClient(settings)
        try:
            rows = list(client.lane_performance(business_date=target))
        except httpx.HTTPError as exc:
            # analytics-pipeline ล่มไม่ใช่เหตุฉุกเฉินของเรา: โมเดลอุปสงค์ใช้หน้าต่าง
            # ``OF_PRICING_DEMAND_WINDOW_DAYS`` วัน การขาดไปหนึ่งวันขยับ uplift ได้ไม่กี่ bp
            log.warning("analytics-pipeline unreachable: %s", exc)
            raise self.retry(exc=exc)
        finally:
            client.close()

        with session_scope() as session:
            for row in rows:
                existing = session.execute(
                    select(DemandObservation).where(
                        DemandObservation.tenant_id == tenant_id,
                        DemandObservation.origin_unlocode == row.origin_unlocode,
                        DemandObservation.destination_unlocode == row.destination_unlocode,
                        DemandObservation.business_date == target,
                    )
                ).scalar_one_or_none()
                if existing is not None:
                    # แถวเดิมไม่ถูกเขียนทับ: วิวต้นทางถูก refresh ใหม่ทุกคืนและตัวเลข
                    # ย้อนหลังขยับได้ ถ้าปล่อยให้ทับ โมเดลจะให้ราคาที่ต่างกันสำหรับ
                    # input ชุดเดียวกันเมื่อคิดซ้ำ ซึ่งอธิบายกับลูกค้าไม่ได้
                    skipped += 1
                    continue
                session.add(
                    DemandObservation(
                        tenant_id=tenant_id,
                        origin_unlocode=row.origin_unlocode,
                        destination_unlocode=row.destination_unlocode,
                        business_date=target,
                        booked_count=row.shipment_count,
                        capacity_slots=None,
                        avg_transit_seconds=row.avg_transit_seconds,
                    )
                )
                stored += 1

    log.info(
        "stored %d demand observation(s) for %s on %s (%d already present)",
        stored,
        tenant_id,
        target,
        skipped,
    )
    return {"stored": stored, "skipped": skipped}
