"""งานที่ "ออกใบใหม่แทนใบเก่า" และงานดูแลบ้าน: คิดราคาใหม่รายลำ, คิดใหม่ทั้ง rate card,
ทำใบที่หมดอายุให้หมดอายุจริง และกวาด seen-set ของ event ที่พ้นระยะ retention แล้ว

หลักการเดียวที่ทุกงานในไฟล์นี้ยึด: **ไม่มีการแก้ตัวเลขบนใบที่ออกไปแล้ว** ราคาที่เปลี่ยนคือ
ใบใหม่ที่ชี้กลับไปหาใบเก่าผ่าน ``superseded_by_quote_id`` แนวเดียวกับที่ §7.6 บังคับกับ
การแก้ declaration และการออก credit note ฝั่ง billing-service

งานทุกตัวถูกเรียกซ้ำได้ปลอดภัย: ตัวคิดราคาใหม่กันซ้ำด้วย advisory lock ต่อ shipment และด้วย
ช่วงพัก ``OF_PRICING_REPRICE_COOLDOWN_SECONDS`` ซึ่งมีไว้กัน "พายุ replan" แบบเดียวกับที่
``OF_ROUTING_REPLAN_COOLDOWN_SECONDS`` กันให้ routing-service
"""

from __future__ import annotations

import asyncio
import datetime as dt
import logging
from typing import Final

from celery.utils.log import get_task_logger
from sqlalchemy import delete, select, update

from pricing_service.clients.container_registry import ContainerRegistryClient
from pricing_service.clients.customs import CustomsClient
from pricing_service.clients.routing import RoutingClient
from pricing_service.config import Settings, get_settings
from pricing_service.context import RequestContext, new_trace_id, scoped
from pricing_service.db.models_market import RepricingRun
from pricing_service.db.models_quotes import Quote
from pricing_service.db.models_rate_cards import RateCard
from pricing_service.db.outbox import ConsumedEvent
from pricing_service.db.session import advisory_lock, session_scope
from pricing_service.engine import rating
from pricing_service.metrics import QUOTES_RATED
from pricing_service.workers.celery_app import app
from pricing_service import VERSION, quote_builder

log: logging.Logger = get_task_logger(__name__)

# เหตุผลที่ข้ามช่วงพักได้ เพราะข้อมูลตั้งต้นเปลี่ยนไปจริง ไม่ใช่แค่สัญญาณรบกวน
FORCE_REASONS: Final[frozenset[str]] = frozenset(
    {
        "duty_assessed",
        "duty_currency_changed",
        "shipment_sealed",
        "proof_of_delivery",
        "rate_card_activated",
    }
)

# seen-set ต้องอยู่นานกว่า retention ที่ยาวที่สุดในบรรดาหัวข้อที่เราฟัง (90 วัน ของ
# of.customs.v1 และ of.billing.v1) เผื่อไว้อีกสิบวันสำหรับการ replay ด้วยมือ
CONSUMED_EVENT_RETENTION_DAYS: Final[int] = 100


def _task_context(tenant_id: str, trace_id: str | None) -> RequestContext:
    """บริบทของงานเบื้องหลัง — สืบ trace เดิมต่อถ้ามาจาก event, สร้างใหม่ถ้ามาจาก beat"""

    return RequestContext(
        tenant_id=tenant_id,
        trace_id=trace_id or new_trace_id(),
        actor_kind="service",
        actor_id="svc:pricing-service",
    )


async def _gather(command: quote_builder.QuoteCommand, settings: Settings) -> tuple:
    """เปิด client สามตัว ดึงข้อเท็จจริง แล้วปิดให้เรียบร้อย

    Celery task เป็นโค้ด synchronous ส่วน client เป็น async เราจึงยอมจ่ายค่า ``asyncio.run``
    หนึ่งครั้งต่องาน แทนที่จะทำ client ซ้ำอีกชุดเป็นเวอร์ชัน sync แล้วต้องแก้บั๊กสองที่ตลอดไป
    """

    registry = ContainerRegistryClient(settings)
    routing_client = RoutingClient(settings)
    customs = CustomsClient(settings)
    try:
        return await quote_builder.gather_facts(
            command, settings, registry=registry, routing_client=routing_client, customs=customs
        )
    finally:
        await registry.aclose()
        await routing_client.aclose()
        await customs.aclose()


@app.task(name="pricing.reprice_shipment", bind=True, max_retries=3, default_retry_delay=180)
def reprice_shipment(  # type: ignore[no-untyped-def]
    self,
    tenant_id: str,
    shipment_id: str | None,
    reason: str,
    trace_id: str | None = None,
) -> dict[str, object]:
    """ออกใบเสนอราคาใหม่ให้ shipment หนึ่งลำ แล้วทำเครื่องหมายใบเดิมว่าถูกแทนที่

    Args:
        tenant_id: ``tnt_…`` เจ้าของ shipment
        shipment_id: ``shp_…`` — ถ้าเป็น ``None`` งานจบทันที (ใบเสนอราคาแบบไม่ผูก shipment
            ไม่มีเหตุการณ์ต้นทางที่จะทำให้ต้องคิดใหม่)
        reason: ที่มาของการคิดใหม่ เช่น ``route_replanned`` ``duty_assessed``
        trace_id: trace เดิมจาก event ต้นทาง ถ้ามี

    Returns:
        dict: ``{"quote_id": …, "superseded": …}`` หรือ ``{"skipped": เหตุผล}``

    งานนี้เป็นทางเดียวที่ใบใหม่เกิดขึ้นโดยไม่มีคนกด — ทุกเส้นทางอื่นมาจาก
    ``POST /v1/quotes`` ที่มีผู้ใช้จริงอยู่ปลายสาย
    """

    if not shipment_id:
        return {"skipped": "no_shipment"}

    settings = get_settings()
    now = dt.datetime.now(dt.UTC)

    with scoped(_task_context(tenant_id, trace_id)) as ctx:
        with session_scope() as session:
            if not advisory_lock(session, f"reprice:{shipment_id}"):
                log.info("another worker is already repricing %s", shipment_id)
                return {"skipped": "locked"}

            previous = session.execute(
                select(Quote)
                .where(
                    Quote.tenant_id == tenant_id,
                    Quote.shipment_id == shipment_id,
                    Quote.status.in_(("issued", "accepted")),
                )
                .order_by(Quote.issued_at.desc())
                .limit(1)
            ).scalar_one_or_none()

            cooldown = dt.timedelta(seconds=settings.pricing.reprice_cooldown_seconds)
            if (
                previous is not None
                and reason not in FORCE_REASONS
                and now - previous.issued_at < cooldown
            ):
                log.info("quote %s is inside the reprice cooldown", previous.quote_id)
                return {"skipped": "cooldown"}

            command = quote_builder.QuoteCommand(
                tenant_id=tenant_id,
                shipment_id=shipment_id,
                origin_unlocode=None,
                destination_unlocode=None,
                target_currency=previous.currency if previous else None,
                rate_card_id=None,
                iso_size_type=None,
                gross_kg=None,
                declared_value_minor=None,
                strategy=previous.strategy if previous else "cheapest",
            )

        shipment, route, declaration_count, tariff = asyncio.run(_gather(command, settings))

        today = now.date()
        with session_scope() as session:
            card = quote_builder.select_rate_card(session, tenant_id, today, None)
            rating_input = quote_builder.build_rating_input(
                command,
                settings,
                rate_card=card,
                shipment=shipment,
                route=route,
                session=session,
                tariff=tariff,
                declaration_count=declaration_count,
                today=today,
            )
            result = rating.rate_shipment(
                rating_input, demand_cap_bp=settings.pricing.demand_max_uplift_bp
            )
            fresh = quote_builder.persist(
                session,
                ctx,
                result,
                command,
                settings=settings,
                rate_card=card,
                route=route,
                tariff=tariff,
            )
            session.flush()

            superseded: str | None = None
            if previous is not None:
                stale = session.get(Quote, previous.quote_id)
                if stale is not None and stale.status in ("issued", "accepted"):
                    quote_builder.supersede(session, stale, fresh.quote_id)
                    superseded = stale.quote_id

            QUOTES_RATED.labels(outcome="repriced", strategy=command.strategy).inc()
            log.info(
                "repriced %s because %s: %s replaces %s",
                shipment_id,
                reason,
                fresh.quote_id,
                superseded or "nothing",
            )
            return {"quote_id": fresh.quote_id, "superseded": superseded, "reason": reason}


@app.task(name="pricing.reprice_rate_card", bind=True, max_retries=1, default_retry_delay=600)
def reprice_rate_card(self, tenant_id: str, rate_card_id: str) -> dict[str, int]:  # type: ignore[no-untyped-def]
    """คิดราคาใหม่ให้ทุกใบที่ยังมีผลของ rate card หนึ่งชุด หลังชุดใหม่เริ่มมีผล

    แตกงานย่อยหนึ่งงานต่อหนึ่ง shipment แทนที่จะวนคิดในงานเดียว เพราะการล้มกลางทางของ
    shipment ลำที่ 800 ไม่ควรทำให้อีก 799 ลำที่ทำไปแล้วต้องทำซ้ำ — และคิวจะได้ไม่ถูกงานเดียว
    ยึดไว้นานเป็นสิบนาทีจน ``pricing.refresh_fx_rates`` ที่อยู่คนละคิวเริ่มดูเหมือนค้างไปด้วย

    Returns:
        dict: จำนวนใบที่ถูกจัดคิวคิดใหม่ ไม่ใช่จำนวนที่คิดเสร็จ
    """

    queued = 0
    with scoped(_task_context(tenant_id, None)):
        with session_scope() as session:
            card = session.get(RateCard, rate_card_id)
            if card is None:
                log.warning("rate card %s vanished before repricing started", rate_card_id)
                return {"queued": 0}

            run = RepricingRun(
                tenant_id=tenant_id,
                trigger="rate_card_activated",
                rate_card_id=rate_card_id,
                engine_version=VERSION,
            )
            session.add(run)

            shipment_ids = session.execute(
                select(Quote.shipment_id)
                .where(
                    Quote.tenant_id == tenant_id,
                    Quote.rate_card_id == rate_card_id,
                    Quote.status == "issued",
                    Quote.shipment_id.is_not(None),
                )
                .distinct()
            ).scalars()

            for shipment_id in shipment_ids:
                reprice_shipment.delay(
                    tenant_id=tenant_id,
                    shipment_id=shipment_id,
                    reason="rate_card_activated",
                )
                queued += 1

            run.quotes_examined = queued
            run.state = "succeeded" if queued else "partial"
            run.finished_at = dt.datetime.now(dt.UTC)

    log.info("queued %d shipment(s) for repricing under %s", queued, rate_card_id)
    return {"queued": queued}


@app.task(name="pricing.expire_quotes")
def expire_quotes() -> dict[str, int]:
    """ทำใบที่เลย ``valid_until_at`` ให้เป็น ``expired`` ทุกสิบนาที

    ทำไมต้องมีงานนี้ทั้งที่ ``Quote.is_live`` ก็เช็กเวลาอยู่แล้ว: เพราะ billing-service อ่าน
    ตารางผ่าน API ของเราด้วยตัวกรอง ``status`` และรายงานฝั่งพาณิชย์ก็นับจากคอลัมน์เดียวกัน
    การปล่อยให้ "หมดอายุแล้วแต่ยังเขียนว่า issued" ทำให้สองที่นั้นเห็นคนละความจริง

    ใบที่ ``accepted`` ไม่ถูกแตะ แม้จะเลยวันหมดอายุ — ลูกค้ารับราคาไปแล้ว การหมดอายุย้อนหลัง
    จะทำให้ใบแจ้งหนี้ที่อ้างถึงมันกลายเป็นใบที่ไม่มีต้นเรื่อง
    """

    now = dt.datetime.now(dt.UTC)
    with session_scope() as session:
        result = session.execute(
            update(Quote)
            .where(Quote.status == "issued", Quote.valid_until_at <= now)
            .values(status="expired")
        )
        expired = int(result.rowcount or 0)

    if expired:
        log.info("expired %d quote(s)", expired)
    return {"expired": expired}


@app.task(name="pricing.prune_consumed_events")
def prune_consumed_events() -> dict[str, int]:
    """ลบแถวใน ``pricing.consumed_events`` ที่เก่ากว่า retention ของหัวข้อที่ยาวที่สุด

    ลบเป็นชุดเล็กแล้ววนซ้ำ ไม่ใช่ ``DELETE`` ก้อนเดียว: ตารางนี้โตวันละหลักแสนแถวและการลบ
    ทั้งเดือนในทรานแซกชันเดียวเคยทำให้ autovacuum ตามไม่ทันจน bloat ไปหลายกิกะไบต์
    """

    cutoff = dt.datetime.now(dt.UTC) - dt.timedelta(days=CONSUMED_EVENT_RETENTION_DAYS)
    removed = 0
    with session_scope() as session:
        while True:
            batch = session.execute(
                select(ConsumedEvent.event_id)
                .where(ConsumedEvent.consumed_at < cutoff)
                .limit(5_000)
            ).scalars().all()
            if not batch:
                break
            session.execute(delete(ConsumedEvent).where(ConsumedEvent.event_id.in_(batch)))
            removed += len(batch)
            if removed >= 250_000:
                # เพดานต่อรอบ งานนี้รันทุกวันอยู่แล้ว ส่วนที่เหลือรอพรุ่งนี้ได้
                break

    log.info("pruned %d consumed-event rows older than %s", removed, cutoff.date())
    return {"pruned": removed}
