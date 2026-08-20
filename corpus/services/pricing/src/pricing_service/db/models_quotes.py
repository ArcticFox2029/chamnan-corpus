"""ตารางฝั่ง "ราคาที่ออกไปแล้ว": ``pricing.quotes`` กับ ``pricing.quote_lines``

quote หนึ่งใบคือภาพนิ่งของราคา ณ วินาทีที่ออก — ทั้งอัตราแลกเปลี่ยน, แถว rate card ที่ใช้
และตัวเลข uplift จากโมเดลอุปสงค์ ถูกแช่ลงแถวนี้หมด เพื่อให้ billing-service สร้าง
``billing.invoice_lines`` ได้โดยไม่ต้องคำนวณซ้ำ และ reconciliation-service ตรวจย้อนได้ว่า
ยอดบนใบแจ้งหนี้มาจากไหน
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import (
    CheckConstraint,
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
    Metres,
    Money,
    Ref,
    Timestamp,
    new_id,
    utcnow_default,
)

QUOTE_STATUSES = ("draft", "issued", "accepted", "expired", "superseded")
"""``accepted`` ตั้งได้ทางเดียวคือผ่าน ``POST /v1/quotes/{quote_id}/accept``"""


class Quote(Base):
    """ใบเสนอราคาหนึ่งใบ

    ``shipment_id`` เป็น logical FK ไป ``freight.shipments`` และเป็น ``NULL`` ได้ เพราะฝ่ายขาย
    ขอราคาล่วงหน้าก่อนจะมี shipment จริงอยู่บ่อย ๆ ส่วน ``superseded_by_quote_id`` ทำให้
    การคิดราคาใหม่ (เช่นหลัง ``route.replanned``) เป็นการ *เพิ่มแถว* ไม่ใช่แก้ของเดิม
    ซึ่งเป็นกติกาเดียวกับ SPEC §7.6
    """

    __tablename__ = "quotes"
    __table_args__ = (
        CheckConstraint(
            "total_minor = subtotal_minor + duty_estimate_minor + tax_estimate_minor",
            name="quote_total_is_consistent",
        ),
        CheckConstraint("valid_until_at > issued_at", name="quote_validity_is_forward"),
        CheckConstraint(
            "status <> 'accepted' OR accepted_at IS NOT NULL", name="quote_accepted_needs_timestamp"
        ),
        UniqueConstraint("tenant_id", "idempotency_key"),
        Index(
            "quotes_open_for_shipment_idx",
            "shipment_id",
            postgresql_where="status IN ('issued','accepted')",
        ),
    )

    quote_id: Mapped[Id] = mapped_column(default=lambda: new_id("quo"))
    tenant_id: Mapped[Ref]
    shipment_id: Mapped[Ref | None]
    rate_card_id: Mapped[str] = mapped_column(ForeignKey("rate_cards.rate_card_id"))
    lane_id: Mapped[Ref | None]
    route_id: Mapped[Ref | None]
    route_version: Mapped[int | None] = mapped_column(Integer)
    strategy: Mapped[str] = mapped_column(String(24), default="cheapest")
    status: Mapped[str] = mapped_column(String(12), default="draft")

    currency: Mapped[Currency]
    subtotal_minor: Mapped[Money] = mapped_column(default=0)
    duty_estimate_minor: Mapped[Money] = mapped_column(default=0)
    tax_estimate_minor: Mapped[Money] = mapped_column(default=0)
    total_minor: Mapped[Money] = mapped_column(default=0)

    billable_distance_m: Mapped[Metres] = mapped_column(default=0)
    chargeable_weight_kg: Mapped[int] = mapped_column(Integer, default=0)
    demand_uplift_bp: Mapped[BasisPoints] = mapped_column(default=0)

    # อัตราแลกเปลี่ยนที่แช่ไว้ ณ วินาทีที่ออกใบ ถ้า ``currency`` ตรงกับสกุลของ rate card อยู่แล้ว
    # ทั้งสองคอลัมน์นี้จะเป็น NULL — ไม่ได้เก็บอัตรา 1:1 ปลอม ๆ ไว้ให้สับสน
    fx_rate_micros: Mapped[int | None]
    fx_rate_recorded_at: Mapped[Timestamp | None]
    fx_source: Mapped[str | None] = mapped_column(String(48))

    # ข้อมูลดิบที่ใช้ตัดสินราคา เก็บไว้เพื่อ audit และ reconciliation ไม่เคยถูกอ่านตอนคิดราคา
    rating_inputs: Mapped[dict] = mapped_column(JSONB, default=dict)

    issued_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())
    valid_until_at: Mapped[Timestamp]
    accepted_at: Mapped[Timestamp | None]
    accepted_by: Mapped[Ref | None]
    superseded_by_quote_id: Mapped[Ref | None]
    invoice_id: Mapped[Ref | None]
    idempotency_key: Mapped[str | None] = mapped_column(String(120))
    trace_id: Mapped[str | None] = mapped_column(String(32))
    engine_version: Mapped[str] = mapped_column(String(16), default="4.2.0")

    lines: Mapped[list["QuoteLine"]] = relationship(
        back_populates="quote", cascade="all, delete-orphan", order_by="QuoteLine.seq_no"
    )

    def is_live(self, now: dt.datetime) -> bool:
        """ยังใช้อ้างอิงได้อยู่ไหม — ``issued`` และยังไม่หมดอายุ"""

        return self.status == "issued" and self.valid_until_at > now


class QuoteLine(Base):
    """หนึ่งบรรทัดค่าใช้จ่าย แมปตรงกับหนึ่งแถวใน ``billing.invoice_lines``

    ``quantity_milli`` เก็บจำนวนคูณพันเป็นจำนวนเต็ม เพราะ ``billing.invoice_lines.quantity``
    เป็น ``NUMERIC(12,3)`` — การส่งเป็น float ระหว่างทางคือจุดที่เศษสตางค์เคยหายไปหนึ่งครั้ง
    """

    __tablename__ = "quote_lines"
    __table_args__ = (
        UniqueConstraint("quote_id", "seq_no"),
        CheckConstraint(
            "charge_code IN ('linehaul','fuel_surcharge','demurrage','detention','reefer_power',"
            "'customs_clearance','duty_disbursement','hazmat_handling','waiting_time')",
            name="quote_lines_charge_code_matches_billing",
        ),
        CheckConstraint(
            "source_kind IS NULL OR source_kind IN "
            "('leg','alert','declaration','assignment','manual')",
            name="quote_lines_source_kind_matches_billing",
        ),
    )

    quote_line_id: Mapped[Id] = mapped_column(default=lambda: new_id("qln"))
    quote_id: Mapped[str] = mapped_column(
        ForeignKey("quotes.quote_id", ondelete="CASCADE"), index=True
    )
    seq_no: Mapped[int] = mapped_column(Integer)
    charge_code: Mapped[str] = mapped_column(String(24))
    description: Mapped[str] = mapped_column(String(200))
    quantity_milli: Mapped[int] = mapped_column(Integer, default=1_000)
    unit_price_minor: Mapped[Money]
    amount_minor: Mapped[Money]
    source_kind: Mapped[str | None] = mapped_column(String(16))
    source_id: Mapped[Ref | None]
    rule_id: Mapped[Ref | None]

    quote: Mapped[Quote] = relationship(back_populates="lines")
