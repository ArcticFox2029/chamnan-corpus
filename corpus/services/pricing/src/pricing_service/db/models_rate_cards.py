"""ตารางฝั่ง "ราคาตั้ง" ทั้งหมด: ``pricing.rate_cards``, ``pricing.rate_card_lanes``,
``pricing.rate_breaks`` และ ``pricing.surcharge_rules``

สี่ตารางนี้เป็นข้อมูลอ้างอิงที่เปลี่ยนช้าและ **ไม่เคยถูกแก้ทับ** — การขึ้นราคาคือการปิดช่วง
ของแถวเดิมแล้ว insert แถวใหม่ วิธีเดียวกับที่ ``customs.tariff_schedules`` ใช้ เพื่อให้
quote ที่ออกไปเมื่อวานยังอธิบายตัวเองได้ด้วยแถวที่มันอ้างถึง
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from pricing_service.db.base import (
    Base,
    BasisPoints,
    Currency,
    Id,
    Kilograms,
    Money,
    Ref,
    Timestamp,
    new_id,
    utcnow_default,
)

CHARGE_CODES = (
    "linehaul",
    "fuel_surcharge",
    "demurrage",
    "detention",
    "reefer_power",
    "customs_clearance",
    "duty_disbursement",
    "hazmat_handling",
    "waiting_time",
)
"""สำเนาของ CHECK บน ``billing.invoice_lines.charge_code`` — ค่าที่เราผลิตต้องอยู่ในนี้เท่านั้น"""

TRANSPORT_MODES = ("road", "rail", "sea", "air", "barge")
"""ตรงกับ ``routing.route_legs.mode``"""


class RateCard(Base):
    """ชุดราคาหนึ่งชุดของ tenant หนึ่งราย มีผลระหว่างสองวันที่

    ``carrier_id`` เป็น logical FK ไป ``fleet.carriers`` — ตั้งค่าเมื่อชุดราคานี้ผูกกับผู้ขนส่ง
    รายเดียว ถ้าเป็น ``NULL`` แปลว่าใช้ได้กับทุกราย ส่วน ``priority`` ตัดสินตอนมีหลายชุดซ้อนกัน
    ตัวเลขน้อยชนะ
    """

    __tablename__ = "rate_cards"
    __table_args__ = (
        UniqueConstraint("tenant_id", "name", "effective_from_on"),
        CheckConstraint(
            "effective_to_on IS NULL OR effective_to_on > effective_from_on",
            name="rate_cards_period_is_forward",
        ),
        Index("rate_cards_active_idx", "tenant_id", "priority", postgresql_where="retired_at IS NULL"),
    )

    rate_card_id: Mapped[Id] = mapped_column(default=lambda: new_id("rcd"))
    tenant_id: Mapped[Ref]
    name: Mapped[str] = mapped_column(String(120))
    currency: Mapped[Currency]
    carrier_id: Mapped[Ref | None]
    priority: Mapped[int] = mapped_column(Integer, default=100)
    effective_from_on: Mapped[dt.date] = mapped_column(Date)
    effective_to_on: Mapped[dt.date | None] = mapped_column(Date)
    created_by: Mapped[Ref]
    created_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())
    retired_at: Mapped[Timestamp | None]

    lanes: Mapped[list["RateCardLane"]] = relationship(
        back_populates="rate_card", cascade="all, delete-orphan"
    )
    surcharges: Mapped[list["SurchargeRule"]] = relationship(
        back_populates="rate_card", cascade="all, delete-orphan"
    )


class RateCardLane(Base):
    """ราคาต่อเส้นทางหนึ่งคู่ท่า ในโหมดขนส่งหนึ่งโหมด

    สูตรฐานคือ ``base_minor + per_km_minor × ระยะทาง`` โดยระยะทางมาจากผลรวม
    ``routing.route_legs.distance_m`` ของ route ที่ ``is_current`` แล้วค่อยเทียบกับ
    ``minimum_charge_minor`` เอาค่าที่มากกว่า
    """

    __tablename__ = "rate_card_lanes"
    __table_args__ = (
        UniqueConstraint("rate_card_id", "origin_unlocode", "destination_unlocode", "mode"),
        CheckConstraint(
            "origin_unlocode <> destination_unlocode", name="lanes_endpoints_differ"
        ),
        CheckConstraint(
            "mode IN ('road','rail','sea','air','barge')", name="lanes_mode_is_known"
        ),
    )

    lane_id: Mapped[Id] = mapped_column(default=lambda: new_id("rln"))
    rate_card_id: Mapped[str] = mapped_column(
        ForeignKey("rate_cards.rate_card_id", ondelete="CASCADE"), index=True
    )
    origin_unlocode: Mapped[str] = mapped_column(String(5))
    destination_unlocode: Mapped[str] = mapped_column(String(5))
    mode: Mapped[str] = mapped_column(String(8))
    base_minor: Mapped[Money]
    per_km_minor: Mapped[Money]
    minimum_charge_minor: Mapped[Money]
    transit_days: Mapped[int] = mapped_column(Integer)
    # ตัวคูณตามชนิดตู้ เก็บเป็น JSON เล็ก ๆ คีย์คือ freight.containers.iso_size_type
    # เช่น {"45R1": 11500, "22G1": 10000} หน่วยเป็น basis point
    # ใช้ JSONB เพราะจำนวนชนิดตู้ที่ตกลงไว้ต่างกันมากในแต่ละสัญญา การแตกเป็นตารางแยก
    # ทำให้คิวรีราคาต้อง join เพิ่มอีกชั้นโดยไม่ได้อะไรกลับมา
    equipment_multipliers_bp: Mapped[dict[str, int]] = mapped_column(JSONB, default=dict)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)

    rate_card: Mapped[RateCard] = relationship(back_populates="lanes")
    breaks: Mapped[list["RateBreak"]] = relationship(
        back_populates="lane", cascade="all, delete-orphan", order_by="RateBreak.from_kg"
    )


class RateBreak(Base):
    """ขั้นน้ำหนักของเลนหนึ่งเส้น: ``[from_kg, to_kg)`` คิดตัวคูณเป็น basis point

    ขั้นสุดท้ายเปิดปลายด้วย ``to_kg IS NULL`` เสมอ ตัว engine จะตรวจว่าครอบคลุมตั้งแต่ 0
    ถึงอนันต์แบบไม่มีช่องโหว่ก่อนใช้งาน — ถ้ามีช่องว่างคือ configuration bug ไม่ใช่ราคา 0
    """

    __tablename__ = "rate_breaks"
    __table_args__ = (
        UniqueConstraint("lane_id", "from_kg"),
        CheckConstraint("to_kg IS NULL OR to_kg > from_kg", name="rate_breaks_range_is_forward"),
        CheckConstraint("multiplier_bp > 0", name="rate_breaks_multiplier_is_positive"),
    )

    break_id: Mapped[Id] = mapped_column(default=lambda: new_id("rbk"))
    lane_id: Mapped[str] = mapped_column(
        ForeignKey("rate_card_lanes.lane_id", ondelete="CASCADE"), index=True
    )
    from_kg: Mapped[Kilograms]
    to_kg: Mapped[Kilograms | None]
    multiplier_bp: Mapped[BasisPoints]

    lane: Mapped[RateCardLane] = relationship(back_populates="breaks")


class SurchargeRule(Base):
    """กฎค่าธรรมเนียมหนึ่งข้อ ผูกกับ rate card ไม่ใช่กับเลน เพราะส่วนใหญ่ใช้ทั้งชุดราคา

    ``applies_when`` เป็น expression สั้น ๆ ที่ ``engine.surcharges`` ตีความเอง (ไม่ใช่ ``eval``)
    เช่น ``container.is_reefer`` หรือ ``shipment.status == 'held_at_customs'`` — ตัวแปรที่
    อ้างถึงได้มีเฉพาะที่ประกาศไว้ใน ``engine/surcharges.py``
    """

    __tablename__ = "surcharge_rules"
    __table_args__ = (
        UniqueConstraint("rate_card_id", "charge_code", "applies_when"),
        CheckConstraint("rate_bp >= 0 AND amount_minor >= 0", name="surcharge_amounts_non_negative"),
        CheckConstraint(
            "cap_minor IS NULL OR cap_minor >= amount_minor", name="surcharge_cap_above_amount"
        ),
    )

    rule_id: Mapped[Id] = mapped_column(default=lambda: new_id("srg"))
    rate_card_id: Mapped[str] = mapped_column(
        ForeignKey("rate_cards.rate_card_id", ondelete="CASCADE"), index=True
    )
    charge_code: Mapped[str] = mapped_column(String(24))
    basis: Mapped[str] = mapped_column(String(24))
    amount_minor: Mapped[Money] = mapped_column(default=0)
    rate_bp: Mapped[BasisPoints] = mapped_column(default=0)
    free_units: Mapped[int] = mapped_column(Integer, default=0)
    cap_minor: Mapped[Money | None]
    applies_when: Mapped[str] = mapped_column(String(120), default="always")
    sort_order: Mapped[int] = mapped_column(Integer, default=100)

    rate_card: Mapped[RateCard] = relationship(back_populates="surcharges")
