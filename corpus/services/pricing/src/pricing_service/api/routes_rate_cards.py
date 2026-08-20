"""เส้นทาง HTTP สำหรับดูแลชุดราคา: ``/v1/rate-cards`` และเลนกับขั้นน้ำหนักที่อยู่ใต้มัน

ผู้ใช้จริงคือหน้าจอ pricing ในคอนโซล (``web/``) ที่ทีมพาณิชย์ใช้ ไม่ใช่เซอร์วิสอื่น —
เซอร์วิสอื่นสนใจแค่ผลลัพธ์ที่ ``/v1/quotes`` คายออกมา
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from pricing_service.api.deps import Ctx, require_scope
from pricing_service.api.errors import PricingError, RateCardNotFound
from pricing_service.api.schemas import LaneCreate, RateBreakCreate, RateCardCreate
from pricing_service.db.models_rate_cards import RateBreak, RateCard, RateCardLane
from pricing_service.db.session import session_scope

router = APIRouter(prefix="/v1/rate-cards", tags=["rate-cards"])


class RateBreakOverlap(PricingError):
    """ขั้นน้ำหนักใหม่ทับกับขั้นที่มีอยู่

    ตรวจในโค้ดเพราะ ``pricing.rate_breaks`` ไม่มี EXCLUDE constraint แบบที่
    ``customs.tariff_schedules`` มีบน ``valid_period`` — ช่วงตรงนี้เป็นจำนวนเต็ม ไม่ใช่ range
    type และการเพิ่ม btree_gist เข้ามาเพื่อตารางเดียวไม่คุ้ม
    """

    code = "rate_break_overlap"
    http_status = 409


@router.post("", status_code=status.HTTP_201_CREATED, dependencies=[Depends(require_scope("pricing:ratecard.write"))])
async def create_rate_card(payload: RateCardCreate, ctx: Ctx) -> dict:
    """สร้างชุดราคาใหม่ ยังไม่มีเลน — เลนถูกเพิ่มทีหลังทีละเส้น

    ชุดราคาที่ยังไม่มีเลนถือว่าใช้งานได้ตามกฎหมายของโมเดล แต่จะทำให้ทุก quote ตอบ 422
    (``lane_not_covered``) ซึ่งชัดเจนกว่าการห้ามสร้างชุดเปล่า
    """

    with session_scope() as session:
        card = RateCard(
            tenant_id=ctx.tenant_id,
            name=payload.name,
            currency=payload.currency,
            carrier_id=payload.carrier_id,
            priority=payload.priority,
            effective_from_on=payload.effective_from_on,
            effective_to_on=payload.effective_to_on,
            created_by=ctx.actor_id,
        )
        session.add(card)
        session.flush()
        return {"rate_card_id": card.rate_card_id, "name": card.name, "currency": card.currency}


@router.get("", dependencies=[Depends(require_scope("pricing:ratecard.read"))])
async def list_rate_cards(
    ctx: Ctx,
    active_on: dt.date | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None),
) -> dict:
    """รายการชุดราคาของ tenant เรียงตาม ``priority`` แล้วตามวันเริ่มมีผล"""

    with session_scope() as session:
        stmt = (
            select(RateCard)
            .where(RateCard.tenant_id == ctx.tenant_id, RateCard.retired_at.is_(None))
            .order_by(RateCard.priority, RateCard.rate_card_id)
        )
        if active_on:
            stmt = stmt.where(RateCard.effective_from_on <= active_on)
        if cursor:
            stmt = stmt.where(RateCard.rate_card_id > cursor)

        rows = list(session.execute(stmt.limit(limit + 1)).scalars())
        page = rows[:limit]
        return {
            "items": [
                {
                    "rate_card_id": card.rate_card_id,
                    "name": card.name,
                    "currency": card.currency,
                    "carrier_id": card.carrier_id,
                    "priority": card.priority,
                    "effective_from_on": card.effective_from_on,
                    "effective_to_on": card.effective_to_on,
                }
                for card in page
            ],
            "next_cursor": rows[limit].rate_card_id if len(rows) > limit else None,
        }


@router.get("/{rate_card_id}", dependencies=[Depends(require_scope("pricing:ratecard.read"))])
async def read_rate_card(rate_card_id: str, ctx: Ctx) -> dict:
    """อ่านชุดราคาพร้อมเลนและขั้นน้ำหนักทั้งหมดในครั้งเดียว

    ใช้ ``selectinload`` สองชั้นแทน join เพราะเลนหนึ่งชุดมีได้หลายร้อยเส้นและแต่ละเส้นมี
    ขั้นน้ำหนักไม่กี่ขั้น — join แบบ cartesian จะคูณแถวจนตอบช้ากว่าสองคิวรีแยกกัน
    """

    with session_scope() as session:
        card = session.execute(
            select(RateCard)
            .options(selectinload(RateCard.lanes).selectinload(RateCardLane.breaks))
            .options(selectinload(RateCard.surcharges))
            .where(RateCard.rate_card_id == rate_card_id, RateCard.tenant_id == ctx.tenant_id)
        ).scalar_one_or_none()
        if card is None:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")

        return {
            "rate_card_id": card.rate_card_id,
            "name": card.name,
            "currency": card.currency,
            "priority": card.priority,
            "effective_from_on": card.effective_from_on,
            "effective_to_on": card.effective_to_on,
            "lanes": [
                {
                    "lane_id": lane.lane_id,
                    "origin_unlocode": lane.origin_unlocode,
                    "destination_unlocode": lane.destination_unlocode,
                    "mode": lane.mode,
                    "base_minor": lane.base_minor,
                    "per_km_minor": lane.per_km_minor,
                    "minimum_charge_minor": lane.minimum_charge_minor,
                    "transit_days": lane.transit_days,
                    "equipment_multipliers_bp": lane.equipment_multipliers_bp,
                    "breaks": [
                        {
                            "from_kg": rb.from_kg,
                            "to_kg": rb.to_kg,
                            "multiplier_bp": rb.multiplier_bp,
                        }
                        for rb in sorted(lane.breaks, key=lambda b: b.from_kg)
                    ],
                }
                for lane in card.lanes
                if lane.is_active
            ],
        }


@router.post(
    "/{rate_card_id}/lanes",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_scope("pricing:ratecard.write"))],
)
async def add_lane(rate_card_id: str, payload: LaneCreate, ctx: Ctx) -> dict:
    """เพิ่มเลนหนึ่งเส้นเข้าชุดราคา

    ``origin_unlocode``/``destination_unlocode`` ต้องเป็นรหัสเดียวกับที่
    ``freight.facilities.unlocode`` ใช้ เราไม่ตรวจกับ container-registry ตอนสร้าง เพราะ
    ทีมพาณิชย์ตั้งราคาล่วงหน้าให้ท่าที่ยังไม่มีสถานที่ในระบบอยู่บ่อยครั้ง
    """

    with session_scope() as session:
        card = session.get(RateCard, rate_card_id)
        if card is None or card.tenant_id != ctx.tenant_id:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")
        lane = RateCardLane(
            rate_card_id=rate_card_id,
            origin_unlocode=payload.origin_unlocode,
            destination_unlocode=payload.destination_unlocode,
            mode=payload.mode,
            base_minor=payload.base_minor,
            per_km_minor=payload.per_km_minor,
            minimum_charge_minor=payload.minimum_charge_minor,
            transit_days=payload.transit_days,
            equipment_multipliers_bp={},
        )
        session.add(lane)
        session.flush()
        return {"lane_id": lane.lane_id}


@router.post(
    "/{rate_card_id}/lanes/{lane_id}/breaks",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_scope("pricing:ratecard.write"))],
)
async def add_break(rate_card_id: str, lane_id: str, payload: RateBreakCreate, ctx: Ctx) -> dict:
    """เพิ่มขั้นน้ำหนัก โดยตรวจการทับซ้อนกับขั้นที่มีอยู่ก่อน

    Raises:
        RateBreakOverlap: ช่วงใหม่ทับของเดิม — ขั้นที่ทับกันทำให้ ``weight_multiplier_bp``
            ได้ตัวคูณตัวใดตัวหนึ่งแบบไม่กำหนดแน่นอน ซึ่งแปลว่าราคาไม่ deterministic
    """

    with session_scope() as session:
        lane = session.execute(
            select(RateCardLane)
            .options(selectinload(RateCardLane.breaks))
            .join(RateCard)
            .where(
                RateCardLane.lane_id == lane_id,
                RateCardLane.rate_card_id == rate_card_id,
                RateCard.tenant_id == ctx.tenant_id,
            )
        ).scalar_one_or_none()
        if lane is None:
            raise RateCardNotFound(f"lane {lane_id} does not exist on rate card {rate_card_id}")

        new_to = payload.to_kg if payload.to_kg is not None else 10**9
        for existing in lane.breaks:
            existing_to = existing.to_kg if existing.to_kg is not None else 10**9
            if payload.from_kg < existing_to and existing.from_kg < new_to:
                raise RateBreakOverlap(
                    f"[{payload.from_kg}, {payload.to_kg}) overlaps "
                    f"[{existing.from_kg}, {existing.to_kg})"
                )

        rate_break = RateBreak(
            lane_id=lane_id,
            from_kg=payload.from_kg,
            to_kg=payload.to_kg,
            multiplier_bp=payload.multiplier_bp,
        )
        session.add(rate_break)
        session.flush()
        return {"break_id": rate_break.break_id}


@router.delete(
    "/{rate_card_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=[Depends(require_scope("pricing:ratecard.write"))],
)
async def retire_rate_card(rate_card_id: str, ctx: Ctx) -> None:
    """ปลดระวางชุดราคา — ตั้ง ``retired_at`` ไม่ได้ลบแถว

    quote ที่ออกไปแล้วยังชี้มาที่แถวนี้ผ่าน foreign key และต้องอธิบายตัวเองได้ตลอดอายุ
    การเก็บเอกสาร (``OF_CUSTOMS_RETENTION_YEARS`` = 10 ปีสำหรับงานศุลกากร)
    """

    with session_scope() as session:
        card = session.get(RateCard, rate_card_id)
        if card is None or card.tenant_id != ctx.tenant_id:
            raise RateCardNotFound(f"rate card {rate_card_id} does not exist for this tenant")
        card.retired_at = dt.datetime.now(dt.UTC)
