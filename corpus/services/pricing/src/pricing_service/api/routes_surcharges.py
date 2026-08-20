"""เส้นทาง HTTP ของกฎค่าธรรมเนียม ``/v1/rate-cards/{rate_card_id}/surcharges``
รวมทั้งปลายทางลองยิงกฎ (``/preview``) ที่ทีมพาณิชย์ใช้ทดสอบก่อนเปิดใช้จริง

การตรวจ ``applies_when`` เกิดที่นี่ ตอนสร้างกฎ ไม่ใช่ตอนคิดราคา — กฎที่อ้างถึงคำที่ไม่มีใน
คำศัพท์จะเงียบสนิทถ้าปล่อยผ่าน และ "กฎที่ไม่เคยเข้าเงื่อนไขเลย" เป็นบั๊กที่หายากที่สุดชนิดหนึ่ง
ที่เราเคยไล่
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from pricing_service.api.deps import Ctx, require_scope
from pricing_service.api.errors import PricingError, RateCardNotFound
from pricing_service.api.schemas import SurchargeRuleCreate
from pricing_service.db.models_rate_cards import RateCard, SurchargeRule
from pricing_service.db.session import session_scope
from pricing_service.engine.money import Money
from pricing_service.engine.surcharges import (
    SUPPORTED_FIELDS,
    SUPPORTED_FLAGS,
    SurchargeContext,
    SurchargeRuleView,
    UnknownPredicate,
    apply_rules,
    evaluate_predicate,
)

router = APIRouter(prefix="/v1/rate-cards", tags=["surcharges"])


class InvalidPredicate(PricingError):
    code = "invalid_applies_when"
    http_status = 422


@router.post(
    "/{rate_card_id}/surcharges",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_scope("pricing:ratecard.write"))],
)
async def create_surcharge(rate_card_id: str, payload: SurchargeRuleCreate, ctx: Ctx) -> dict:
    """เพิ่มกฎค่าธรรมเนียมหนึ่งข้อ

    ``charge_code`` ถูกจำกัดด้วย type ``ChargeCode`` ของ pydantic อยู่แล้ว ซึ่งเป็นรายการ
    เดียวกับ CHECK บน ``billing.invoice_lines.charge_code`` — ค่าที่หลุดออกไปนอกรายการนั้น
    จะทำให้ใบแจ้งหนี้ insert ไม่ผ่านที่ฝั่ง billing-service ทั้งใบ

    Raises:
        InvalidPredicate: ``applies_when`` อ้างถึงธงหรือฟิลด์ที่ไม่มีในคำศัพท์
    """

    _validate_predicate(payload.applies_when)

    with session_scope() as session:
        card = session.get(RateCard, rate_card_id)
        if card is None or card.tenant_id != ctx.tenant_id:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")

        rule = SurchargeRule(
            rate_card_id=rate_card_id,
            charge_code=payload.charge_code,
            basis=payload.basis,
            amount_minor=payload.amount_minor,
            rate_bp=payload.rate_bp,
            free_units=payload.free_units,
            cap_minor=payload.cap_minor,
            applies_when=payload.applies_when,
        )
        session.add(rule)
        session.flush()
        return {"rule_id": rule.rule_id, "charge_code": rule.charge_code}


@router.get("/{rate_card_id}/surcharges", dependencies=[Depends(require_scope("pricing:ratecard.read"))])
async def list_surcharges(rate_card_id: str, ctx: Ctx) -> dict:
    """กฎทั้งหมดของชุดราคา เรียงตามลำดับที่ engine จะประมวลผลจริง"""

    with session_scope() as session:
        card = session.execute(
            select(RateCard)
            .options(selectinload(RateCard.surcharges))
            .where(RateCard.rate_card_id == rate_card_id, RateCard.tenant_id == ctx.tenant_id)
        ).scalar_one_or_none()
        if card is None:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")

        return {
            "items": [
                {
                    "rule_id": rule.rule_id,
                    "charge_code": rule.charge_code,
                    "basis": rule.basis,
                    "amount_minor": rule.amount_minor,
                    "rate_bp": rule.rate_bp,
                    "free_units": rule.free_units,
                    "cap_minor": rule.cap_minor,
                    "applies_when": rule.applies_when,
                    "sort_order": rule.sort_order,
                }
                for rule in sorted(card.surcharges, key=lambda r: (r.sort_order, r.charge_code))
            ],
            "next_cursor": None,
        }


@router.post(
    "/{rate_card_id}/surcharges/preview",
    dependencies=[Depends(require_scope("pricing:ratecard.read"))],
)
async def preview_surcharges(rate_card_id: str, facts: dict, ctx: Ctx) -> dict:
    """ยิงกฎทั้งชุดใส่ข้อเท็จจริงสมมติ แล้วคืนบรรทัดที่จะเกิดขึ้น โดยไม่บันทึกอะไรเลย

    Args:
        facts: dict ที่มีคีย์ ``flags`` (รายการธง), ``fields`` (map ของฟิลด์),
            ``linehaul_minor`` และหน่วยนับต่าง ๆ เช่น ``dwell_days``

    Returns:
        dict: รายการบรรทัดพร้อมยอด — รูปเดียวกับที่จะไปโผล่ใน ``pricing.quote_lines``

    ปลายทางนี้เป็นเหตุผลที่ ``engine/surcharges.py`` ถูกเขียนให้เป็นฟังก์ชันล้วน: ทดสอบกฎ
    ได้โดยไม่ต้องมี shipment จริง ไม่ต้องแตะ container-registry และไม่ทิ้งแถวไว้ในฐานข้อมูล
    """

    with session_scope() as session:
        card = session.execute(
            select(RateCard)
            .options(selectinload(RateCard.surcharges))
            .where(RateCard.rate_card_id == rate_card_id, RateCard.tenant_id == ctx.tenant_id)
        ).scalar_one_or_none()
        if card is None:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")

        context = SurchargeContext(
            flags=frozenset(facts.get("flags", ["always"])),
            fields=dict(facts.get("fields", {})),
            linehaul=Money(int(facts.get("linehaul_minor", 0)), card.currency),
            billable_distance_m=int(facts.get("billable_distance_m", 0)),
            dwell_days=int(facts.get("dwell_days", 0)),
            detention_days=int(facts.get("detention_days", 0)),
            reefer_hours=int(facts.get("reefer_hours", 0)),
            waiting_minutes=int(facts.get("waiting_minutes", 0)),
        )
        views = [
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
        ]
        lines = apply_rules(views, context, currency=card.currency)
        return {
            "currency": card.currency,
            "items": [
                {
                    "charge_code": line.charge_code,
                    "description": line.description,
                    "quantity_milli": line.quantity_milli,
                    "unit_price_minor": line.unit_price.minor,
                    "amount_minor": line.amount.minor,
                    "rule_id": line.rule_id,
                }
                for line in lines
            ],
            "total_minor": sum(line.amount.minor for line in lines),
        }


@router.get("/vocabulary/predicates")
async def predicate_vocabulary(ctx: Ctx) -> dict:
    """คำศัพท์ทั้งหมดที่ ``applies_when`` รู้จัก — คอนโซลใช้เติม dropdown ให้ผู้ใช้

    เปิดให้ทุก scope อ่านได้ เพราะไม่ใช่ข้อมูลของ tenant ไหนเลย เป็นความสามารถของโค้ด
    """

    return {
        "flags": sorted(SUPPORTED_FLAGS),
        "fields": sorted(SUPPORTED_FIELDS),
        "operators": ["==", "!"],
    }


def _validate_predicate(expression: str) -> None:
    """ตรวจ expression ด้วยบริบทเปล่า — สนใจแค่ว่ามันตีความได้ ไม่สนผลลัพธ์"""

    probe = SurchargeContext(flags=frozenset({"always"}), fields={}, linehaul=Money(0, "EUR"), billable_distance_m=0)
    try:
        evaluate_predicate(expression, probe)
    except UnknownPredicate as exc:
        raise InvalidPredicate(str(exc)) from exc
