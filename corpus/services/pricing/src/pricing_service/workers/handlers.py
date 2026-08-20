"""ตรรกะที่ทำกับ event แต่ละชนิดที่ pricing-service ฟัง — หนึ่งฟังก์ชันต่อหนึ่งชื่อ event

ทุกฟังก์ชันในไฟล์นี้ทำงานอยู่ในทรานแซกชันที่ ``consumers.py`` เปิดไว้ให้แล้ว และห้าม commit เอง
เพราะการจองสิทธิ์ใน ``pricing.consumed_events`` กับผลข้างเคียงต้องลงหรือหายไปพร้อมกัน

ข้อห้ามที่บังคับใช้ตลอดทั้งไฟล์: **ไม่มี handler ตัวไหนเรียกกลับไปหาผู้ผลิต event นั้นแบบ
synchronous** (§4.19 ข้อ 2) — โดยเฉพาะ ``billing.invoice.issued`` ที่เย้ายวนให้ยิงกลับไปถาม
billing-service ว่าใบไหนกันแน่ ถ้าข้อมูลในซองไม่พอ คำตอบคือให้ผู้ผลิตเติมฟิลด์ ไม่ใช่ให้เราต่อสาย
"""

from __future__ import annotations

import datetime as dt
import logging
from typing import Callable, Final

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from pricing_service.config import get_settings
from pricing_service.db.models_market import DemandObservation
from pricing_service.db.models_quotes import Quote
from pricing_service.db.models_rate_cards import RateCardLane
from pricing_service.db.outbox import claim_event
from pricing_service.metrics import EVENTS_CONSUMED
from pricing_service.workers.envelope import Envelope

log = logging.getLogger(__name__)

Handler = Callable[[Session, Envelope], str]

# ส่วนต่างของระยะทางจริงกับระยะทางที่คิดราคาไว้ ที่ยอมให้ผ่านโดยไม่คิดราคาใหม่
DISTANCE_TOLERANCE_BP: Final[int] = 500  # 5%

# ส่วนต่างของอากรจริงกับที่ประมาณไว้ ที่ยอมให้ผ่าน — ต่ำกว่านี้การออกใบใหม่สร้างเสียงรบกวน
# มากกว่าประโยชน์ ค่านี้ตั้งใจให้แคบกว่า ``OF_RECON_TOLERANCE_MINOR`` ของ
# reconciliation-service เสมอ มิฉะนั้นเราจะเป็นฝ่ายผลิต ``duty_mismatch`` ให้เขาเอง
DUTY_TOLERANCE_MINOR: Final[int] = 200

# รหัสกฎเตือนจาก telemetry-ingest ที่กระทบราคา ตัวอื่น (เช่น battery_low) ไม่กระทบ
PRICE_RELEVANT_RULE_CODES: Final[frozenset[str]] = frozenset(
    {"temp_above_setpoint", "temp_below_setpoint", "door_open_in_transit", "shock_exceeded"}
)


def _live_quote(session: Session, tenant_id: str, shipment_id: str | None) -> Quote | None:
    """ใบเสนอราคาที่ยังมีผลของ shipment หนึ่งใบ ถ้ามีหลายใบให้เอาใบที่ออกล่าสุด

    ปกติมีได้ใบเดียวเพราะ ``quotes_open_for_shipment_idx`` แต่ระหว่างที่ใบใหม่ถูกออกและ
    ใบเก่ายังไม่ถูกทำเครื่องหมาย ``superseded`` จะมีสองใบอยู่ชั่วครู่
    """

    if not shipment_id:
        return None
    return session.execute(
        select(Quote)
        .options(selectinload(Quote.lines))
        .where(
            Quote.tenant_id == tenant_id,
            Quote.shipment_id == shipment_id,
            Quote.status.in_(("issued", "accepted")),
        )
        .order_by(Quote.issued_at.desc())
        .limit(1)
    ).scalar_one_or_none()


def _schedule_reprice(envelope: Envelope, *, reason: str, countdown: int = 0) -> None:
    """สั่งงานคิดราคาใหม่แบบ asynchronous

    ส่งด้วย ``send_task`` ตามชื่อ ไม่ import ตัวฟังก์ชัน task เข้ามา — process ของ consumer
    จึงไม่ต้องโหลดโค้ดของ worker ทั้งชุด และการแก้ signature ของ task ไม่ทำให้ consumer พัง
    ตอน deploy คนละรอบกัน
    """

    from pricing_service.workers.celery_app import app  # นำเข้าในฟังก์ชันเพื่อเลี่ยง import วน

    app.send_task(
        "pricing.reprice_shipment",
        kwargs={
            "tenant_id": envelope.tenant_id,
            "shipment_id": envelope.get("shipment_id"),
            "reason": reason,
            "trace_id": envelope.trace_id,
        },
        countdown=countdown,
    )


def on_shipment_created(session: Session, envelope: Envelope) -> str:
    """``shipment.created`` (ผลิตโดย container-registry) — ตั้งคิวออกราคาชี้แนะให้ shipment ใหม่

    หน่วงไว้หนึ่งนาทีโดยตั้งใจ: routing-service ยังไม่ได้วาง ``routing.routes`` เวอร์ชันแรก
    ตอนที่ event นี้ออก การคิดราคาทันทีจะได้ระยะทางเป็นศูนย์แล้วตกไปใช้ ``minimum_charge_minor``
    ซึ่งดูเหมือนราคาจริงจนกว่าจะมีคนสังเกต
    """

    shipment_id = envelope.require("shipment_id")
    log.info("scheduling indicative quote for %s", shipment_id)
    _schedule_reprice(envelope, reason="shipment_created", countdown=60)
    return "applied"


def on_shipment_scanned(session: Session, envelope: Envelope) -> str:
    """``shipment.scanned`` (ผลิตโดย container-registry) — เฉพาะการสแกนที่ปิดงาน

    เราสนใจ ``scan_type = 'proof_of_delivery'`` ตัวเดียว ซึ่งเป็นชนิดเดียวกับที่
    billing-service ใช้เป็นสัญญาณว่าออกใบแจ้งหนี้ได้แล้ว (§4.4) — จังหวะนั้นคือจังหวะสุดท้าย
    ที่ราคายังแก้ได้ก่อนจะกลายเป็นใบแจ้งหนี้

    ส่วนการนับ free time สำหรับ ``demurrage``/``detention`` ไม่ได้เก็บสะสมที่นี่: ตอนคิดราคา
    เราอ่านรอยสแกนทั้งเส้นจาก ``GET /v1/shipments/{shipment_id}/scans`` ของ container-registry
    ซึ่งเป็นเจ้าของข้อมูลจริง การเก็บสำเนานาฬิกาไว้ฝั่งเราจะทำให้มีสองความจริงทันทีที่มี
    การแก้รอยสแกนย้อนหลัง
    """

    if envelope.get("scan_type") != "proof_of_delivery":
        return "ignored"

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None:
        return "ignored"

    log.info("proof of delivery on %s, final repricing", envelope.get("shipment_id"))
    _schedule_reprice(envelope, reason="proof_of_delivery")
    return "applied"


def on_status_changed(session: Session, envelope: Envelope) -> str:
    """``shipment.status.changed`` — สถานะปลายทางตัดสินว่าใบเสนอราคายังมีความหมายไหม

    ``cancelled`` ทำให้ใบที่ยังเปิดอยู่หมดอายุทันที ส่วน ``sealed`` แปลว่ารายการตู้และน้ำหนัก
    นิ่งแล้ว (container-registry ปฏิเสธการเพิ่มตู้หลังจากนี้) จึงเป็นจังหวะที่ควรออกใบสุดท้าย
    ก่อนที่ billing-service จะมาอ่านตอนร่างใบแจ้งหนี้
    """

    to_status = envelope.require("to_status")
    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))

    if to_status == "cancelled":
        if quote is None:
            return "ignored"
        quote.status = "expired"
        log.info("expired quote %s because the shipment was cancelled", quote.quote_id)
        return "applied"

    if to_status == "sealed":
        _schedule_reprice(envelope, reason="shipment_sealed")
        return "applied"

    # ``at_risk`` และ ``held_at_customs`` ไม่ขยับราคาเอง — ค่าธรรมเนียมที่ตามมาจากสองสถานะนั้น
    # มาจาก telemetry.alert.raised และจากจำนวน declaration ตามลำดับ ไม่ได้มาจากตัวสถานะ
    return "ignored"


def on_route_replanned(session: Session, envelope: Envelope) -> str:
    """``route.replanned`` (ผลิตโดย routing-service) — ระยะทางเปลี่ยน ราคาต้องเปลี่ยนตาม

    เทียบ ``version`` ในซองกับ ``pricing.quotes.route_version`` ที่แช่ไว้ตอนออกใบ ถ้าใบปัจจุบัน
    อ้างอิงเวอร์ชันที่ใหม่กว่าหรือเท่ากันอยู่แล้วแปลว่ามี consumer อีกตัวชิงคิดไปก่อน — ข้าม
    """

    if not envelope.get("legs_changed"):
        return "ignored"

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None:
        return "ignored"

    new_version = int(envelope.require("version"))
    if quote.route_version is not None and quote.route_version >= new_version:
        return "ignored"

    log.info(
        "route %s moved to version %d, repricing quote %s",
        envelope.get("route_id"),
        new_version,
        quote.quote_id,
    )
    _schedule_reprice(envelope, reason="route_replanned")
    return "applied"


def on_assignment_released(session: Session, envelope: Envelope) -> str:
    """``fleet.assignment.released`` (ผลิตโดย fleet-service) — ระยะทางที่วิ่งจริงมาถึงแล้ว

    ``distance_travelled_m`` คือระยะทางจริงจาก telematics ส่วน ``billable_distance_m`` บนใบ
    เป็นระยะทางที่วางแผนไว้ ต่างกันเกิน ``DISTANCE_TOLERANCE_BP`` เมื่อไหร่แปลว่ารถเลี่ยงเส้นทาง
    จริง ๆ ไม่ใช่ GPS เพี้ยน และค่า linehaul ควรถูกออกใหม่ก่อนที่ reconciliation-service
    จะเจอเองแล้วเปิด ``unbilled_accessorial``
    """

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None or not quote.billable_distance_m:
        return "ignored"

    actual_m = int(envelope.get("distance_travelled_m") or 0)
    if actual_m <= 0:
        return "ignored"

    delta_bp = abs(actual_m - quote.billable_distance_m) * 10_000 // quote.billable_distance_m
    if delta_bp <= DISTANCE_TOLERANCE_BP:
        return "ignored"

    log.info(
        "distance variance %d bp on quote %s (planned %d m, actual %d m)",
        delta_bp,
        quote.quote_id,
        quote.billable_distance_m,
        actual_m,
    )
    _schedule_reprice(envelope, reason="distance_variance")
    return "applied"


def on_alert_raised(session: Session, envelope: Envelope) -> str:
    """``telemetry.alert.raised`` (ผลิตโดย telemetry-ingest) — เหตุการณ์ที่กลายเป็นค่าธรรมเนียม

    เราไม่เรียก telemetry-ingest กลับไปถามรายละเอียดเพิ่ม (§4.19 ข้อ 2) ซองมีครบพอจะตัดสินแล้ว
    ตู้เย็นที่หลุด setpoint แปลว่าเครื่องทำความเย็นทำงานหนักขึ้น ซึ่งเข้ากฎ ``reefer_power``
    ส่วนประตูที่เปิดระหว่างวิ่งเข้ากฎ ``hazmat_handling`` เฉพาะเมื่อตู้นั้นประกาศวัตถุอันตราย
    ไว้ใน ``freight.container_hazard_classes`` — ตัวคิดจริงอยู่ใน ``engine/surcharges.py``
    """

    rule_code = envelope.require("rule_code")
    if rule_code not in PRICE_RELEVANT_RULE_CODES:
        return "ignored"
    if envelope.get("severity") not in ("high", "critical"):
        return "ignored"

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None:
        return "ignored"

    log.info(
        "alert %s (%s) will be priced onto shipment %s",
        envelope.get("alert_id"),
        rule_code,
        envelope.get("shipment_id"),
    )
    _schedule_reprice(envelope, reason=f"alert:{rule_code}")
    return "applied"


def on_declaration_cleared(session: Session, envelope: Envelope) -> str:
    """``customs.declaration.cleared`` (ผลิตโดย customs-service) — อากรตัวจริงมาแทนตัวประมาณ

    ตัวเลขที่เราใส่ไว้ตอนออกใบมาจาก ``GET /v1/tariffs/lookup`` ซึ่งเป็นการประมาณและไม่ผูกพัน
    ส่วนตัวเลขในซองนี้คือสิ่งที่ศุลกากรประเมินจริง ต่างกันเกิน ``DUTY_TOLERANCE_MINOR`` เมื่อไหร่
    เราออกใบใหม่ที่มาแทนใบเดิม — ไม่ใช่แก้ตัวเลขบนใบเดิม ตามกติกา §7.6

    สังเกตว่าเรา *ไม่* แตะ ``billing.invoices.duty_minor`` ทั้งที่รู้ค่าที่ถูกต้องแล้ว นั่นเป็น
    งานของ billing-service ซึ่งก็ฟัง event ใบเดียวกันนี้อยู่
    """

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None:
        return "ignored"

    assessed = int(envelope.get("assessed_duty_minor") or 0)
    assessed_vat = int(envelope.get("assessed_vat_minor") or 0)
    currency = envelope.get("currency")

    if currency and currency != quote.currency:
        # อากรถูกประเมินคนละสกุลกับที่เสนอราคา — ต้องคิดใหม่ทั้งใบเพื่อให้ FX ถูกแช่ใหม่พร้อมกัน
        _schedule_reprice(envelope, reason="duty_currency_changed")
        return "applied"

    estimated = quote.duty_estimate_minor + quote.tax_estimate_minor
    if abs(estimated - (assessed + assessed_vat)) <= DUTY_TOLERANCE_MINOR:
        return "ignored"

    log.info(
        "declaration %s cleared at %d + %d, quote %s estimated %d",
        envelope.get("declaration_id"),
        assessed,
        assessed_vat,
        quote.quote_id,
        estimated,
    )
    _schedule_reprice(envelope, reason="duty_assessed")
    return "applied"


def on_invoice_issued(session: Session, envelope: Envelope) -> str:
    """``billing.invoice.issued`` — ผูกเลขใบแจ้งหนี้กลับมาที่ใบเสนอราคาที่เป็นต้นทาง

    นี่คือขาเดียวที่เรารู้ผลของ billing-service และเป็นขาที่ทำให้ไม่ต้องมี HTTP client ของ
    billing-service อยู่ในเซอร์วิสนี้เลย ถ้ายอดต่างกัน เราแค่บันทึกไว้ ไม่แก้ไขอะไรทั้งสองฝั่ง —
    การจับคู่สามทางเป็นหน้าที่ของ reconciliation-service ซึ่งฟัง event ใบเดียวกันนี้
    """

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None:
        return "ignored"

    quote.invoice_id = envelope.require("invoice_id")
    invoiced_total = int(envelope.get("total_minor") or 0)
    if envelope.get("currency") == quote.currency and invoiced_total != quote.total_minor:
        log.warning(
            "invoice %s totals %d but quote %s totals %d — leaving both untouched",
            quote.invoice_id,
            invoiced_total,
            quote.quote_id,
            quote.total_minor,
        )
    return "applied"


def on_invoice_settled(session: Session, envelope: Envelope) -> str:
    """``billing.invoice.settled`` — ปิดวงจร และนับเป็นดีมานด์ที่ "ปิดการขาย" ได้จริง

    ตัวเลข ``accepted_count`` ใน ``pricing.demand_observations`` คือสิ่งที่ทำให้โมเดลอุปสงค์
    ต่างจากการนับ booking เฉย ๆ: เลนที่มีคนขอราคาเยอะแต่ไม่มีใครจ่ายจริง ไม่ใช่เลนที่ควรขึ้นราคา
    """

    quote = _live_quote(session, envelope.tenant_id, envelope.get("shipment_id"))
    if quote is None or quote.lane_id is None:
        return "ignored"

    lane = session.get(RateCardLane, quote.lane_id)
    if lane is None:
        return "ignored"

    business_date = envelope.occurred_at.astimezone(dt.UTC).date()
    observation = session.execute(
        select(DemandObservation).where(
            DemandObservation.tenant_id == envelope.tenant_id,
            DemandObservation.origin_unlocode == lane.origin_unlocode,
            DemandObservation.destination_unlocode == lane.destination_unlocode,
            DemandObservation.business_date == business_date,
        )
    ).scalar_one_or_none()

    if observation is None:
        observation = DemandObservation(
            tenant_id=envelope.tenant_id,
            origin_unlocode=lane.origin_unlocode,
            destination_unlocode=lane.destination_unlocode,
            business_date=business_date,
            booked_count=0,
            capacity_slots=None,
            quoted_count=1,
            accepted_count=0,
        )
        session.add(observation)

    observation.accepted_count += 1
    return "applied"


HANDLERS: Final[dict[str, Handler]] = {
    "shipment.created": on_shipment_created,
    "shipment.scanned": on_shipment_scanned,
    "shipment.status.changed": on_status_changed,
    "route.replanned": on_route_replanned,
    "fleet.assignment.released": on_assignment_released,
    "telemetry.alert.raised": on_alert_raised,
    "customs.declaration.cleared": on_declaration_cleared,
    "billing.invoice.issued": on_invoice_issued,
    "billing.invoice.settled": on_invoice_settled,
}
"""ตารางส่งต่อ — ชื่อคีย์ทุกตัวสะกดตาม SPEC §4 ตรงตัว

event ที่ไม่มีในตารางนี้ถูก ack ทิ้งอย่างเงียบ ๆ ไม่ใช่ส่งเข้า DLQ: หัวข้อ ``of.freight.v1``
มี event ที่เราไม่สนใจอยู่หลายตัว (เช่น ``fleet.assignment.created``) และการ subscribe
ทั้งหัวข้อแล้วคัดเองถูกกว่าการขอหัวข้อใหม่ต่อผู้บริโภคหนึ่งราย

กรณีที่เห็นบ่อยที่สุดของ ``unhandled`` คือ ``of.platform.v1`` ซึ่งเรา subscribe เพราะ
``route.replanned`` อยู่ที่นั่น แล้วพลอยได้ ``document.uploaded``,
``reconciliation.discrepancy.opened``, ``notification.delivery.failed`` และ
``pricing.quote.issued`` ของตัวเราเองติดมาด้วย ทั้งหมดถูกทิ้งที่บรรทัดเดียวนี้
"""


def dispatch(session: Session, envelope: Envelope) -> str:
    """เรียก handler ที่ตรงกับ ``event_name`` พร้อมกันงานซ้ำในทรานแซกชันเดียวกัน

    Args:
        session: session ที่เปิดทรานแซกชันไว้แล้ว
        envelope: ซองที่ผ่าน ``envelope.parse`` มาแล้ว

    Returns:
        str: ``applied`` / ``ignored`` / ``duplicate`` / ``unhandled`` — ค่าเดียวกับ label
        ``disposition`` ของมาตรวัด ``of_pricing_events_consumed_total``
    """

    handler = HANDLERS.get(envelope.event_name)
    if handler is None:
        EVENTS_CONSUMED.labels(event_name=envelope.event_name, disposition="unhandled").inc()
        return "unhandled"

    if not claim_event(session, envelope.event_id, envelope.event_name, handler.__name__):
        EVENTS_CONSUMED.labels(event_name=envelope.event_name, disposition="duplicate").inc()
        return "duplicate"

    settings = get_settings()
    disposition = handler(session, envelope)
    EVENTS_CONSUMED.labels(event_name=envelope.event_name, disposition=disposition).inc()
    log.debug(
        "handled %s in region %s: %s",
        envelope.event_name,
        settings.platform.region_code,
        disposition,
    )
    return disposition
