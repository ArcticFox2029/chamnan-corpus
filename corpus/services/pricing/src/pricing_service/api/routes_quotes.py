"""เส้นทาง HTTP ของใบเสนอราคา — สี่ปลายทางใต้ ``/v1/quotes``

ผู้เรียกหลักคือ billing-service ตอนร่างใบแจ้งหนี้ (``POST /v1/invoices`` ของฝั่งนั้นเรียก
``POST /v1/quotes`` ของเราก่อน แล้วค่อยเอาบรรทัดที่ได้ไปทำ ``billing.invoice_lines``)
รองลงมาคือคอนโซลของผู้ปฏิบัติงานใน ``web/`` และงานเสนอราคาล่วงหน้าของฝ่ายขาย
"""

from __future__ import annotations

import datetime as dt

import httpx
from fastapi import APIRouter, Depends, Query, Request, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from pricing_service import quote_builder
from pricing_service.api.deps import Ctx, require_scope
from pricing_service.api.errors import (
    CurrencyPairUnavailable,
    LaneNotCovered,
    QuoteAlreadyAccepted,
    QuoteExpired,
    UpstreamUnavailable,
)
from pricing_service.api.errors import PricingError
from pricing_service.api.schemas import QuoteRequest, QuoteResponse
from pricing_service.clients.container_registry import ContainerRegistryClient
from pricing_service.clients.customs import CustomsClient
from pricing_service.clients.routing import RoutingClient
from pricing_service.config import get_settings
from pricing_service.db.models_quotes import Quote
from pricing_service.db.session import session_scope
from pricing_service.engine import rating
from pricing_service.engine.fx import NoUsableRate
from pricing_service.metrics import QUOTES_RATED

router = APIRouter(prefix="/v1/quotes", tags=["quotes"])


class QuoteNotFound(PricingError):
    code = "quote_not_found"
    http_status = 404


def _clients(request: Request) -> tuple[ContainerRegistryClient, RoutingClient, CustomsClient]:
    """คืน client ทั้งสามตัวจาก app state สร้างครั้งเดียวตอน lifespan ไม่ใช่ต่อ request"""

    state = request.app.state
    settings = get_settings()
    if not hasattr(state, "registry"):
        state.registry = ContainerRegistryClient(settings)
        state.routing = RoutingClient(settings)
        state.customs = CustomsClient(settings)
    return state.registry, state.routing, state.customs


@router.post(
    "",
    response_model=QuoteResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_scope("pricing:quote"))],
)
async def create_quote(request: Request, payload: QuoteRequest, ctx: Ctx) -> QuoteResponse:
    """คิดราคาหนึ่งใบแล้วบันทึกเป็น ``pricing.quotes`` สถานะ ``issued``

    ทำ idempotent ด้วย ``X-OF-Idempotency-Key`` ตาม §7.5 — คีย์เดิมคืนใบเดิมพร้อม 201
    ไม่ใช่คิดใหม่แล้วได้คนละราคาเพราะดัชนีน้ำมันขยับไปสองนาที

    Raises:
        ShipmentNotRatable: shipment ถูกยกเลิกไปแล้ว
        LaneNotCovered: ไม่มีเลนใน rate card ที่ครอบคลุมคู่ท่านี้
        CurrencyPairUnavailable: ไม่มีอัตราแลกเปลี่ยนที่ยังสดพอ (retryable)
        UpstreamUnavailable: container-registry / routing-service / customs-service ไม่ตอบ
    """

    settings = get_settings()
    registry, routing_client, customs = _clients(request)

    command = quote_builder.QuoteCommand(
        tenant_id=ctx.tenant_id,
        shipment_id=payload.shipment_id,
        origin_unlocode=payload.origin_unlocode,
        destination_unlocode=payload.destination_unlocode,
        target_currency=payload.currency,
        rate_card_id=payload.rate_card_id,
        iso_size_type=payload.iso_size_type,
        gross_kg=payload.gross_kg,
        declared_value_minor=payload.declared_value_minor,
        strategy=payload.requested_strategy,
        apply_demand_model=payload.apply_demand_model,
    )

    with session_scope() as session:
        previous = quote_builder.existing_for_key(session, ctx.tenant_id, ctx.idempotency_key)
        if previous is not None:
            return _to_response(previous)

    try:
        shipment, route, declaration_count, tariff = await quote_builder.gather_facts(
            command, settings, registry=registry, routing_client=routing_client, customs=customs
        )
    except httpx.HTTPStatusError as exc:
        raise UpstreamUnavailable(
            exc.request.url.host, f"upstream returned {exc.response.status_code}"
        ) from exc
    except httpx.HTTPError as exc:
        raise UpstreamUnavailable(str(exc.request.url.host), "upstream did not respond") from exc

    today = dt.date.today()
    with session_scope() as session:
        card = quote_builder.select_rate_card(session, ctx.tenant_id, today, payload.rate_card_id)
        try:
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
        except NoUsableRate as exc:
            QUOTES_RATED.labels(outcome="fx_unavailable", strategy=command.strategy).inc()
            raise CurrencyPairUnavailable(str(exc)) from exc

        try:
            result = rating.rate_shipment(
                rating_input, demand_cap_bp=settings.pricing.demand_max_uplift_bp
            )
        except rating.LaneNotCovered as exc:
            QUOTES_RATED.labels(outcome="lane_not_covered", strategy=command.strategy).inc()
            raise LaneNotCovered(str(exc)) from exc

        quote = quote_builder.persist(
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
        return _to_response(quote)


@router.get("/{quote_id}", response_model=QuoteResponse)
async def read_quote(quote_id: str, ctx: Ctx) -> QuoteResponse:
    """อ่านใบเดิม — ไม่คิดราคาใหม่และไม่ปรับอัตราแลกเปลี่ยนให้เป็นปัจจุบัน

    ตัวเลขที่คืนคือตัวเลขที่แช่ไว้ตอนออกใบ นี่คือเหตุผลทั้งหมดที่คอลัมน์ ``fx_rate_micros``
    มีอยู่บนตาราง
    """

    with session_scope() as session:
        quote = session.execute(
            select(Quote)
            .options(selectinload(Quote.lines))
            .where(Quote.quote_id == quote_id, Quote.tenant_id == ctx.tenant_id)
        ).scalar_one_or_none()
        if quote is None:
            raise QuoteNotFound(f"quote {quote_id} does not exist for this tenant")
        return _to_response(quote)


@router.post(
    "/{quote_id}/accept",
    response_model=QuoteResponse,
    dependencies=[Depends(require_scope("pricing:quote.accept"))],
)
async def accept_quote(quote_id: str, ctx: Ctx) -> QuoteResponse:
    """ยืนยันใบเสนอราคา ล็อกตัวเลขไว้ให้ billing-service ใช้ต่อ

    หลังจากนี้ราคาบนใบนี้จะไม่เปลี่ยนอีก แม้ ``route.replanned`` จะมาถึง — งานคิดราคาใหม่
    จะออก quote ใบใหม่แล้วโยงกลับด้วย ``superseded_by_quote_id`` แทนที่จะแก้ใบที่ยืนยันแล้ว

    Raises:
        QuoteExpired: เลย ``valid_until_at`` ไปแล้ว
        QuoteAlreadyAccepted: ใบนี้ถูกยืนยันไปก่อนหน้าโดยผู้ใช้คนอื่น
    """

    now = dt.datetime.now(dt.UTC)
    with session_scope() as session:
        quote = session.execute(
            select(Quote)
            .options(selectinload(Quote.lines))
            .where(Quote.quote_id == quote_id, Quote.tenant_id == ctx.tenant_id)
            .with_for_update()
        ).scalar_one_or_none()
        if quote is None:
            raise QuoteNotFound(f"quote {quote_id} does not exist for this tenant")
        if quote.status == "accepted":
            raise QuoteAlreadyAccepted(f"quote {quote_id} was accepted at {quote.accepted_at}")
        if not quote.is_live(now):
            raise QuoteExpired(f"quote {quote_id} expired at {quote.valid_until_at}")

        quote.status = "accepted"
        quote.accepted_at = now
        quote.accepted_by = ctx.actor_id
        QUOTES_RATED.labels(outcome="accepted", strategy=quote.strategy).inc()
        return _to_response(quote)


@router.get("", response_model=dict)
async def list_quotes(
    ctx: Ctx,
    shipment_id: str | None = Query(default=None),
    status_filter: str | None = Query(default=None, alias="status"),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None),
) -> dict:
    """ค้นใบเสนอราคาแบบ cursor เท่านั้น ตาม §0.5 — ไม่มี offset ที่ไหนในแพลตฟอร์ม

    cursor คือ ``quote_id`` ของแถวสุดท้ายที่ส่งไป ซึ่งใช้ได้เพราะ ULID เรียงตามเวลาอยู่แล้ว
    จึงไม่ต้องมี cursor แบบเข้ารหัสให้ดูแลเพิ่ม
    """

    with session_scope() as session:
        stmt = select(Quote).where(Quote.tenant_id == ctx.tenant_id).order_by(Quote.quote_id.desc())
        if shipment_id:
            stmt = stmt.where(Quote.shipment_id == shipment_id)
        if status_filter:
            stmt = stmt.where(Quote.status == status_filter)
        if cursor:
            stmt = stmt.where(Quote.quote_id < cursor)

        rows = list(session.execute(stmt.limit(limit + 1)).scalars())
        page, next_cursor = rows[:limit], (rows[limit].quote_id if len(rows) > limit else None)
        return {
            "items": [
                {
                    "quote_id": q.quote_id,
                    "shipment_id": q.shipment_id,
                    "status": q.status,
                    "currency": q.currency,
                    "total_minor": q.total_minor,
                    "issued_at": q.issued_at,
                    "valid_until_at": q.valid_until_at,
                }
                for q in page
            ],
            "next_cursor": next_cursor,
        }


def _to_response(quote: Quote) -> QuoteResponse:
    """แปลงแถวในฐานข้อมูลเป็น payload ขาออก

    ``quantity_milli`` ถูกส่งออกไปตามที่เก็บ ไม่แปลงเป็นทศนิยม — ผู้บริโภคหลักคือ
    billing-service ซึ่งจะแปลงเป็น ``NUMERIC(12,3)`` เองตอน insert
    """

    return QuoteResponse.model_validate(
        {
            "quote_id": quote.quote_id,
            "tenant_id": quote.tenant_id,
            "shipment_id": quote.shipment_id,
            "rate_card_id": quote.rate_card_id,
            "currency": quote.currency,
            "subtotal_minor": quote.subtotal_minor,
            "total_minor": quote.total_minor,
            "status": quote.status,
            "valid_until_at": quote.valid_until_at,
            "issued_at": quote.issued_at,
            "lines": quote_builder.as_line_payloads(quote.lines),
            "breakdown": {
                "linehaul_minor": next(
                    (line.amount_minor for line in quote.lines if line.charge_code == "linehaul"), 0
                ),
                "surcharges_minor": sum(
                    line.amount_minor for line in quote.lines if line.charge_code != "linehaul"
                ),
                "duty_estimate_minor": quote.duty_estimate_minor,
                "tax_estimate_minor": quote.tax_estimate_minor,
                "demand_uplift_bp": quote.demand_uplift_bp,
                "fx_rate_micros": quote.fx_rate_micros,
                "fx_rate_recorded_at": quote.fx_rate_recorded_at,
            },
        }
    )
