"""ตัวเย็บระหว่างโลกภายนอกกับ rating engine: ไปเก็บข้อเท็จจริงจากเซอร์วิสอื่น, อ่าน rate card
จากฐานข้อมูล, เรียก ``engine.rate_shipment`` แล้วบันทึกผลลง ``pricing.quotes`` พร้อมกับ
วางข้อความลง ``platform.outbox_messages`` ในทรานแซกชันเดียวกัน

แยกออกจาก ``api/routes_quotes.py`` เพราะเส้นทางเดียวกันนี้ถูกใช้จากสามที่: HTTP, Celery
(งานคิดราคาใหม่เป็นชุด) และ Kafka consumer (เมื่อ ``route.replanned`` หรือ
``customs.declaration.cleared`` มาถึง)
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass
from typing import Sequence

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from pricing_service.api.errors import LaneNotCovered as LaneNotCoveredHttp
from pricing_service.api.errors import RateCardNotFound, ShipmentNotRatable
from pricing_service.clients.container_registry import ContainerRegistryClient, ShipmentView
from pricing_service.clients.customs import CustomsClient
from pricing_service.clients.routing import RoutingClient, RouteView
from pricing_service.config import Settings
from pricing_service.context import RequestContext
from pricing_service.db.models_market import DemandObservation, FuelIndexPoint, FxRate
from pricing_service.db.models_quotes import Quote, QuoteLine
from pricing_service.db.models_rate_cards import RateBreak, RateCard, RateCardLane, SurchargeRule
from pricing_service.db.outbox import TOPICS, enqueue
from pricing_service.engine import rating
from pricing_service.engine.demand import DemandPoint, compute_uplift
from pricing_service.engine.fx import NoUsableRate, RateQuote, pick_rate
from pricing_service.engine.money import Money
from pricing_service.engine.surcharges import SurchargeContext, SurchargeRuleView
from pricing_service.metrics import CHARGE_LINES_EMITTED, DEMAND_UPLIFT_BP, QUOTES_RATED

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class QuoteCommand:
    """สิ่งที่ผู้เรียกอยากได้ ก่อนที่เราจะไปหาข้อเท็จจริงมาเติม"""

    tenant_id: str
    shipment_id: str | None
    origin_unlocode: str | None
    destination_unlocode: str | None
    target_currency: str | None
    rate_card_id: str | None
    iso_size_type: str | None
    gross_kg: int | None
    declared_value_minor: int | None
    strategy: str = "cheapest"
    apply_demand_model: bool = True
    hs_code: str | None = None
    origin_country: str | None = None
    destination_country: str | None = None


def select_rate_card(session: Session, tenant_id: str, on_date: dt.date, explicit_id: str | None) -> RateCard:
    """เลือก rate card ที่จะใช้

    ถ้าผู้เรียกระบุ ``rate_card_id`` มา ใช้ตัวนั้นแต่ยังตรวจว่ามีผลในวันนั้นจริง ถ้าไม่ระบุ
    เลือกตัวที่ ``priority`` น้อยที่สุดในบรรดาที่ยังไม่ retired และช่วงวันครอบคลุมวันนั้น

    Raises:
        RateCardNotFound: ไม่มีชุดราคาที่ใช้ได้เลย ซึ่งแปลว่า tenant ยังไม่ถูก onboard เสร็จ
    """

    stmt = (
        select(RateCard)
        .where(
            RateCard.tenant_id == tenant_id,
            RateCard.retired_at.is_(None),
            RateCard.effective_from_on <= on_date,
        )
        .options(selectinload(RateCard.lanes).selectinload(RateCardLane.breaks))
        .options(selectinload(RateCard.surcharges))
        .order_by(RateCard.priority, RateCard.effective_from_on.desc())
    )
    if explicit_id:
        stmt = stmt.where(RateCard.rate_card_id == explicit_id)

    for card in session.execute(stmt).scalars():
        if card.effective_to_on is None or card.effective_to_on > on_date:
            return card
    raise RateCardNotFound(f"no active rate card for tenant {tenant_id} on {on_date.isoformat()}")


def lane_views(card: RateCard) -> tuple[rating.LaneView, ...]:
    """แปลง ORM object เป็น view ที่ engine กิน — engine ไม่รู้จัก SQLAlchemy โดยตั้งใจ"""

    views: list[rating.LaneView] = []
    for lane in card.lanes:
        if not lane.is_active:
            continue
        breaks = tuple(
            (b.from_kg, b.to_kg, b.multiplier_bp)
            for b in sorted(lane.breaks, key=lambda rb: rb.from_kg)
        )
        views.append(
            rating.LaneView(
                lane_id=lane.lane_id,
                origin_unlocode=lane.origin_unlocode,
                destination_unlocode=lane.destination_unlocode,
                mode=lane.mode,
                base_minor=lane.base_minor,
                per_km_minor=lane.per_km_minor,
                minimum_charge_minor=lane.minimum_charge_minor,
                transit_days=lane.transit_days,
                equipment_multipliers_bp=dict(lane.equipment_multipliers_bp or {}),
                breaks=breaks,
            )
        )
    return tuple(views)


def surcharge_views(card: RateCard) -> tuple[SurchargeRuleView, ...]:
    return tuple(
        SurchargeRuleView(
            rule_id=rule.rule_id,
            charge_code=rule.charge_code,
            basis=rule.basis,
            amount_minor=rule.amount_minor,
            rate_bp=rule.rate_bp,
            free_units=rule.free_units,
            cap_minor=rule.cap_minor,
            applies_when=rule.applies_when,
            sort_order=rule.sort_order,
        )
        for rule in card.surcharges
    )


def demand_points(
    session: Session, tenant_id: str, origin: str, destination: str, window_days: int, today: dt.date
) -> list[DemandPoint]:
    """อ่านประวัติอุปสงค์ของเลนหนึ่งเส้นจาก ``pricing.demand_observations``

    แถวพวกนี้ถูกเติมโดยงาน ``pricing.ingest_demand`` ที่คุยกับ analytics-pipeline —
    เราไม่ query สคีมา ``analytics`` เอง แม้จะอยู่คลัสเตอร์เดียวกัน (SPEC §7.2)
    """

    cutoff = today - dt.timedelta(days=window_days)
    rows = session.execute(
        select(DemandObservation)
        .where(
            DemandObservation.tenant_id == tenant_id,
            DemandObservation.origin_unlocode == origin,
            DemandObservation.destination_unlocode == destination,
            DemandObservation.business_date >= cutoff,
        )
        .order_by(DemandObservation.business_date)
    ).scalars()
    return [
        DemandPoint(
            business_date=row.business_date,
            booked_count=row.booked_count,
            capacity_slots=row.capacity_slots,
            quoted_count=row.quoted_count,
            accepted_count=row.accepted_count,
        )
        for row in rows
    ]


def fx_candidates(session: Session, base: str, quote: str, source: str) -> list[RateQuote]:
    """ดึงอัตราที่เกี่ยวข้องกับคู่นี้ รวมทั้งขาที่ผ่านสกุลกลาง เผื่อ ``pick_rate`` ต้องทำสามเส้า"""

    rows = session.execute(
        select(FxRate)
        .where(
            FxRate.source == source,
            FxRate.base_currency.in_([base, quote, "EUR"]),
            FxRate.quote_currency.in_([base, quote, "EUR"]),
        )
        .order_by(FxRate.observed_at.desc())
        .limit(200)
    ).scalars()
    return [
        RateQuote(
            base_currency=row.base_currency,
            quote_currency=row.quote_currency,
            rate_micros=row.rate_micros,
            source=row.source,
            observed_at=row.observed_at,
        )
        for row in rows
    ]


def latest_fuel_index(session: Session, region_code: str, source: str) -> int | None:
    row = session.execute(
        select(FuelIndexPoint.index_micros)
        .where(FuelIndexPoint.region_code == region_code, FuelIndexPoint.source == source)
        .order_by(FuelIndexPoint.effective_on.desc())
        .limit(1)
    ).scalar_one_or_none()
    return int(row) if row is not None else None


def build_surcharge_context(
    shipment: ShipmentView | None,
    route: RouteView | None,
    *,
    linehaul: Money,
    distance_m: int,
    declaration_count: int,
    assessed_duty: Money | None,
    dwell_days: int,
    detention_days: int,
    reefer_hours: int,
    waiting_minutes: int,
    source_ids: dict[str, str],
) -> SurchargeContext:
    """ยกธงทุกตัวที่กฎค่าธรรมเนียมอาจอ้างถึง

    ชื่อธงต้องอยู่ใน ``engine.surcharges.SUPPORTED_FLAGS`` เท่านั้น การยกธงที่ไม่มีในรายการ
    ไม่ทำให้พัง แต่จะไม่มีกฎข้อไหนเห็นมันเลย — ซึ่งแย่กว่า เพราะเงียบ
    """

    flags: set[str] = {"always"}
    fields: dict[str, str] = {}

    if shipment is not None:
        fields["shipment.status"] = shipment.status
        fields["shipment.incoterm"] = shipment.incoterm
        fields["shipment.region_code"] = shipment.region_code
        if shipment.has_reefer:
            flags.add("container.is_reefer")
        if shipment.hazard_class_codes:
            flags.add("container.is_hazmat")
        if shipment.status == "at_risk":
            flags.add("shipment.has_open_alert")
        if shipment.containers:
            fields["container.iso_size_type"] = shipment.containers[0].iso_size_type

    if route is not None:
        fields["route.primary_mode"] = route.primary_mode
        if route.is_multimodal:
            flags.add("route.is_multimodal")
        if route.has_border_crossing:
            flags.add("route.has_border_crossing")
            flags.add("shipment.is_cross_border")

    if declaration_count > 0:
        flags.add("shipment.is_import")
    if dwell_days > 0:
        flags.add("shipment.exceeded_free_time")

    return SurchargeContext(
        flags=frozenset(flags),
        fields=fields,
        linehaul=linehaul,
        billable_distance_m=distance_m,
        dwell_days=dwell_days,
        detention_days=detention_days,
        reefer_hours=reefer_hours,
        waiting_minutes=waiting_minutes,
        hazard_class_codes=shipment.hazard_class_codes if shipment else (),
        declaration_count=declaration_count,
        assessed_duty=assessed_duty,
        leg_distances_m=route.leg_distances_m if route else (),
        source_ids=source_ids,
    )


async def gather_facts(
    command: QuoteCommand,
    settings: Settings,
    *,
    registry: ContainerRegistryClient,
    routing_client: RoutingClient,
    customs: CustomsClient,
) -> tuple[ShipmentView | None, RouteView | None, int, dict]:
    """ไปเก็บข้อเท็จจริงจากสามเซอร์วิสต้นทาง

    Returns:
        tuple: (shipment, route, จำนวน declaration, อัตราภาษีที่ resolve ได้)

    ลำดับการเรียกไม่สำคัญเชิงความถูกต้อง แต่เราเรียก container-registry ก่อนเสมอ เพราะถ้า
    shipment อยู่ในสถานะที่คิดราคาไม่ได้ อีกสองเซอร์วิสก็ไม่ต้องถูกกวนเลย
    """

    shipment: ShipmentView | None = None
    route: RouteView | None = None
    declaration_count = 0
    tariff: dict = {}

    if command.shipment_id:
        shipment = await registry.get_shipment(command.shipment_id)
        if not shipment.is_ratable:
            raise ShipmentNotRatable(
                f"shipment {shipment.shipment_id} is {shipment.status} and cannot be rated"
            )
        route = await routing_client.current_route(command.shipment_id)
        declarations = await customs.declarations_for_shipment(command.shipment_id)
        declaration_count = len(declarations)

    if command.hs_code and command.destination_country:
        view = await customs.lookup_tariff(
            hs_code=command.hs_code,
            destination_country=command.destination_country,
            origin_country=command.origin_country,
            on_date=dt.date.today(),
        )
        if view is not None:
            tariff = {
                "tariff_id": view.tariff_id,
                "duty_rate_bp": view.duty_rate_bp,
                "vat_rate_bp": view.vat_rate_bp,
                "preferential_scheme": view.preferential_scheme,
            }

    return shipment, route, declaration_count, tariff


def persist(
    session: Session,
    ctx: RequestContext,
    result: rating.RatingResult,
    command: QuoteCommand,
    *,
    settings: Settings,
    rate_card: RateCard,
    route: RouteView | None,
    tariff: dict,
) -> Quote:
    """บันทึก quote พร้อมบรรทัด และวางข้อความลง outbox ในทรานแซกชันเดียวกัน

    ทรานแซกชันเดียวกันเป็นข้อบังคับของ SPEC §7.3 ไม่ใช่ทางเลือก — quote ที่มีอยู่จริงแต่
    ไม่มีใครรู้ กับ event ที่บอกว่ามี quote ที่ไม่มีอยู่ ผิดพอ ๆ กัน
    """

    now = dt.datetime.now(dt.UTC)
    quote = Quote(
        tenant_id=ctx.tenant_id,
        shipment_id=command.shipment_id,
        rate_card_id=rate_card.rate_card_id,
        lane_id=result.lane_id,
        route_id=route.route_id if route else None,
        route_version=route.version if route else None,
        strategy=command.strategy,
        status="issued",
        currency=result.currency,
        subtotal_minor=result.subtotal.minor,
        duty_estimate_minor=result.duty_estimate.minor,
        tax_estimate_minor=result.tax_estimate.minor,
        total_minor=result.grand_total.minor,
        billable_distance_m=result.billable_distance_m,
        chargeable_weight_kg=result.chargeable_weight_kg,
        demand_uplift_bp=result.demand_uplift_bp,
        fx_rate_micros=result.fx_rate.rate_micros if result.fx_rate else None,
        fx_rate_recorded_at=result.fx_rate.observed_at if result.fx_rate else None,
        fx_source=result.fx_rate.source if result.fx_rate else None,
        rating_inputs={**result.inputs_digest, "tariff": tariff},
        issued_at=now,
        valid_until_at=now + dt.timedelta(minutes=settings.pricing.quote_ttl_minutes),
        idempotency_key=ctx.idempotency_key,
        trace_id=ctx.trace_id,
    )
    session.add(quote)

    for line in result.lines:
        session.add(
            QuoteLine(
                quote_id=quote.quote_id,
                seq_no=line.seq_no,
                charge_code=line.charge_code,
                description=line.description,
                quantity_milli=line.quantity_milli,
                unit_price_minor=line.unit_price.minor,
                amount_minor=line.amount.minor,
                source_kind=line.source_kind,
                source_id=line.source_id,
                rule_id=line.rule_id,
            )
        )
        CHARGE_LINES_EMITTED.labels(charge_code=line.charge_code).inc()

    # partition key เป็น shipment_id ทุกครั้งที่มี เพราะการรับประกันลำดับเพียงอย่างเดียวของ
    # แพลตฟอร์มคือ "เรียงต่อหนึ่ง shipment" (§4) quote ที่ไม่มี shipment ใช้ id ของตัวเอง
    enqueue(
        session,
        aggregate_type="quote",
        aggregate_id=quote.quote_id,
        event_name="pricing.quote.issued",
        topic=TOPICS["platform"],
        partition_key=command.shipment_id or quote.quote_id,
        payload={
            "quote_id": quote.quote_id,
            "tenant_id": quote.tenant_id,
            "shipment_id": quote.shipment_id,
            "rate_card_id": quote.rate_card_id,
            "currency": quote.currency,
            "subtotal_minor": quote.subtotal_minor,
            "total_minor": quote.total_minor,
            "demand_uplift_bp": quote.demand_uplift_bp,
            "valid_until_at": quote.valid_until_at.isoformat().replace("+00:00", "Z"),
            "issued_at": quote.issued_at.isoformat().replace("+00:00", "Z"),
        },
    )

    QUOTES_RATED.labels(outcome="issued", strategy=command.strategy).inc()
    if result.demand_uplift_bp:
        DEMAND_UPLIFT_BP.labels(
            lane=f"{command.origin_unlocode}-{command.destination_unlocode}"
        ).observe(result.demand_uplift_bp)
    return quote


def build_rating_input(
    command: QuoteCommand,
    settings: Settings,
    *,
    rate_card: RateCard,
    shipment: ShipmentView | None,
    route: RouteView | None,
    session: Session,
    tariff: dict,
    declaration_count: int,
    today: dt.date,
) -> rating.RatingInput:
    """ประกอบ ``RatingInput`` ให้ครบทุกฟิลด์ก่อนส่งเข้า engine

    Raises:
        LaneNotCoveredHttp: เมื่อยังไม่รู้ต้นทาง/ปลายทางเลย ซึ่งเกิดเมื่อผู้เรียกไม่ส่ง
            ``shipment_id`` และไม่ส่งคู่ท่ามาด้วย
    """

    origin = command.origin_unlocode or (shipment.origin_unlocode if shipment else None)
    destination = command.destination_unlocode or (
        shipment.destination_unlocode if shipment else None
    )
    if not origin or not destination:
        raise LaneNotCoveredHttp("origin and destination UN/LOCODEs could not be resolved")

    mode = route.primary_mode if route else "road"
    distance_m = route.total_distance_m if route else 0
    gross_kg = command.gross_kg or (shipment.total_gross_kg if shipment else 0)
    iso_size_type = command.iso_size_type or (
        shipment.containers[0].iso_size_type if shipment and shipment.containers else None
    )
    target_currency = (
        command.target_currency
        or (shipment.currency if shipment else None)
        or settings.pricing.default_currency
    )

    demand_signal = None
    if command.apply_demand_model:
        points = demand_points(
            session,
            command.tenant_id,
            origin,
            destination,
            settings.pricing.demand_window_days,
            today,
        )
        demand_signal = compute_uplift(
            points,
            alpha_bp=settings.pricing.demand_smoothing_alpha_bp,
            max_uplift_bp=settings.pricing.demand_max_uplift_bp,
            window_days=settings.pricing.demand_window_days,
            today=today,
        )

    fx_rate: RateQuote | None = None
    if target_currency != rate_card.currency:
        try:
            fx_rate = pick_rate(
                fx_candidates(session, rate_card.currency, target_currency, settings.pricing.fx_rate_source),
                base_currency=rate_card.currency,
                quote_currency=target_currency,
                now=dt.datetime.now(dt.UTC),
                staleness_limit_minutes=settings.pricing.fx_staleness_limit_minutes,
            )
        except NoUsableRate:
            # ปล่อยให้ชั้น API แปลงเป็น currency_pair_unavailable (retryable) — การเสนอราคา
            # ด้วยอัตราเก่าเกินขีดแย่กว่าการบอกลูกค้าให้รอสองนาที
            raise

    fuel_index = latest_fuel_index(
        session, settings.platform.region_code, settings.pricing.fuel_index_source
    )

    # ค่า linehaul ที่แท้จริงยังไม่รู้จนกว่า engine จะคิดเสร็จ (มันขึ้นกับขั้นน้ำหนักและ
    # uplift ของโมเดลอุปสงค์) เราจึงใส่ศูนย์ไว้ก่อน แล้ว ``rate_shipment`` จะแทนค่าลงใน
    # บริบทให้ก่อนเรียกกฎค่าธรรมเนียม — กฎแบบ percent_of_linehaul คิดจากยอดหลัง uplift
    linehaul_unknown_yet = Money.zero(rate_card.currency)
    surcharge_ctx = build_surcharge_context(
        shipment,
        route,
        linehaul=linehaul_unknown_yet,
        distance_m=distance_m,
        declaration_count=declaration_count,
        assessed_duty=None,
        dwell_days=0,
        detention_days=0,
        reefer_hours=0,
        waiting_minutes=0,
        source_ids={"customs_clearance": command.shipment_id or ""},
    )

    return rating.RatingInput(
        tenant_id=command.tenant_id,
        rate_card_id=rate_card.rate_card_id,
        rate_card_currency=rate_card.currency,
        target_currency=target_currency,
        origin_unlocode=origin,
        destination_unlocode=destination,
        mode=mode,
        chargeable_weight_kg=gross_kg,
        iso_size_type=iso_size_type,
        distance_m=distance_m,
        leg_distances_m=route.leg_distances_m if route else (),
        lanes=lane_views(rate_card),
        surcharge_rules=surcharge_views(rate_card),
        surcharge_context=surcharge_ctx,
        demand=demand_signal,
        fx_rate=fx_rate,
        customs_value_minor=command.declared_value_minor
        or (shipment.declared_value_minor if shipment else 0),
        duty_rate_bp=int(tariff.get("duty_rate_bp", 0)),
        vat_rate_bp=int(tariff.get("vat_rate_bp", 0)),
        fuel_index_micros=fuel_index,
        fuel_baseline_micros=settings.pricing.fuel_baseline_index_micros,
        shipment_id=command.shipment_id,
        route_id=route.route_id if route else None,
        route_version=route.version if route else None,
        strategy=command.strategy,
    )


def existing_for_key(session: Session, tenant_id: str, key: str | None) -> Quote | None:
    """คืน quote เดิมของ ``X-OF-Idempotency-Key`` เดียวกัน ถ้ามี

    SPEC §7.5 บังคับให้คำขอที่เปลี่ยนสถานะเป็น idempotent อย่างน้อย 24 ชั่วโมง เราเก็บนานกว่านั้น
    เพราะ unique index อยู่บนตาราง quote อยู่แล้วและการลบทิ้งไม่ได้ประหยัดอะไรเลย
    """

    if not key:
        return None
    return session.execute(
        select(Quote)
        .options(selectinload(Quote.lines))
        .where(Quote.tenant_id == tenant_id, Quote.idempotency_key == key)
    ).scalar_one_or_none()


def supersede(session: Session, old: Quote, new_quote_id: str) -> None:
    """ทำเครื่องหมายว่า quote เดิมถูกแทนที่ ไม่ใช่ลบทิ้ง

    เป็นแนวเดียวกับ §7.6: การแก้ไขคือการเพิ่มแถวใหม่ ทั้งฝั่งศุลกากร ฝั่งใบแจ้งหนี้ และที่นี่
    """

    old.status = "superseded"
    old.superseded_by_quote_id = new_quote_id


def as_line_payloads(lines: Sequence[QuoteLine]) -> list[dict]:
    """แปลงบรรทัดที่อ่านจากฐานข้อมูลกลับเป็น payload ของ API"""

    return [
        {
            "seq_no": line.seq_no,
            "charge_code": line.charge_code,
            "description": line.description,
            "quantity_milli": line.quantity_milli,
            "unit_price_minor": line.unit_price_minor,
            "amount_minor": line.amount_minor,
            "source_kind": line.source_kind,
            "source_id": line.source_id,
        }
        for line in lines
    ]
