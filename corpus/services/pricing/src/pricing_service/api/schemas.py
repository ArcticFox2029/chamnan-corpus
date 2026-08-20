"""หน้าตาของ JSON ที่เข้าและออกจาก pricing-service ทุกเส้นทาง

กฎที่ยึดตลอดทั้งไฟล์: เงินเป็นจำนวนเต็มหน่วยย่อยคู่กับ ``currency`` เสมอ, อัตราเป็น basis point,
ระยะทางเป็นเมตร, น้ำหนักเป็นกิโลกรัม, เวลาเป็น RFC 3339 ลงท้าย Z — ไม่มี float โผล่ในสายราคา
แม้แต่ตัวเดียว (SPEC §0.2 และ §7.4)
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# ค่าเดียวกับ CHECK constraint บน billing.invoice_lines.charge_code — ถ้าเพิ่มค่าใหม่ที่นี่
# โดยไม่ไปเพิ่มใน migration ของ billing-service ก่อน ใบแจ้งหนี้จะ insert ไม่ผ่าน
ChargeCode = Literal[
    "linehaul",
    "fuel_surcharge",
    "demurrage",
    "detention",
    "reefer_power",
    "customs_clearance",
    "duty_disbursement",
    "hazmat_handling",
    "waiting_time",
]

# ตรงกับ routing.routes.strategy
RouteStrategy = Literal["cheapest", "fastest", "lowest_carbon", "customs_optimised", "manual"]

CurrencyCode = Annotated[str, Field(pattern=r"^[A-Z]{3}$")]
UnLocode = Annotated[str, Field(pattern=r"^[A-Z]{2}[A-Z2-9]{3}$")]
MinorAmount = Annotated[int, Field(ge=0)]
BasisPoints = Annotated[int, Field(ge=0, le=1_000_000)]


class _Model(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    # extra="ignore" ไม่ใช่ความหละหลวม แต่เป็นกติกา §4.19 ข้อ 3: ฟิลด์ที่ไม่รู้จักให้ข้าม
    # ไม่ใช่ปฏิเสธ ผู้ผลิต payload เพิ่มฟิลด์ได้ภายใน schema_version เดิม


class QuoteRequest(_Model):
    """คำขอคิดราคาหนึ่งใบ

    ผู้เรียกส่งมาแค่ ``shipment_id`` ก็พอ — ที่เหลือเราไปอ่านเองจาก container-registry
    (``GET /v1/shipments/{shipment_id}``) และ routing-service
    (``GET /v1/shipments/{shipment_id}/route``) ฟิลด์อื่นในนี้มีไว้สำหรับกรณีเสนอราคาล่วงหน้า
    ที่ shipment ยังไม่ถูกสร้าง
    """

    shipment_id: str | None = Field(default=None, pattern=r"^shp_[0-9A-HJKMNP-TV-Z]{26}$")
    origin_unlocode: UnLocode | None = None
    destination_unlocode: UnLocode | None = None
    incoterm: str | None = Field(default=None, min_length=3, max_length=3)
    iso_size_type: str | None = Field(default=None, pattern=r"^[0-9A-Z]{4}$")
    gross_kg: int | None = Field(default=None, ge=0, le=80_000)
    declared_value_minor: MinorAmount | None = None
    currency: CurrencyCode | None = None
    hazard_class_codes: tuple[str, ...] = ()
    requested_strategy: RouteStrategy = "cheapest"
    rate_card_id: str | None = Field(default=None, pattern=r"^rcd_[0-9A-HJKMNP-TV-Z]{26}$")
    apply_demand_model: bool = True

    @field_validator("incoterm")
    @classmethod
    def _uppercase_incoterm(cls, value: str | None) -> str | None:
        return value.upper() if value else value


class ChargeLine(_Model):
    """หนึ่งบรรทัดของ quote ซึ่งจะกลายเป็นหนึ่งแถวใน ``billing.invoice_lines`` ตรง ๆ

    ``source_kind``/``source_id`` เดินทางไปด้วยกันเพื่อให้ reconciliation-service ย้อนได้ว่า
    ค่าใช้จ่ายบรรทัดนี้เกิดจากข้อเท็จจริงใบไหน — leg, alert, declaration หรือ assignment
    """

    seq_no: int = Field(ge=1, le=999)
    charge_code: ChargeCode
    description: str
    quantity_milli: int = Field(ge=0, description="quantity x 1000, integer to keep floats out")
    unit_price_minor: int
    amount_minor: int
    source_kind: Literal["leg", "alert", "declaration", "assignment", "manual"] | None = None
    source_id: str | None = None


class QuoteBreakdown(_Model):
    """ตัวเลขระดับสรุปที่หน้าจอ console เอาไปโชว์ข้าง ๆ ตาราง"""

    linehaul_minor: int
    surcharges_minor: int
    duty_estimate_minor: int
    tax_estimate_minor: int
    demand_uplift_bp: BasisPoints
    fx_rate_micros: int | None = None
    fx_rate_recorded_at: datetime | None = None


class QuoteResponse(_Model):
    quote_id: str
    tenant_id: str
    shipment_id: str | None
    rate_card_id: str
    currency: CurrencyCode
    subtotal_minor: int
    total_minor: int
    status: Literal["draft", "issued", "accepted", "expired", "superseded"]
    valid_until_at: datetime
    issued_at: datetime
    lines: tuple[ChargeLine, ...]
    breakdown: QuoteBreakdown


class RateCardCreate(_Model):
    name: str = Field(min_length=1, max_length=120)
    currency: CurrencyCode
    effective_from_on: date
    effective_to_on: date | None = None
    carrier_id: str | None = Field(default=None, pattern=r"^car_[0-9A-HJKMNP-TV-Z]{26}$")
    priority: int = Field(default=100, ge=1, le=1_000)


class LaneCreate(_Model):
    """เลนหนึ่งเส้นของ rate card

    ``origin_unlocode``/``destination_unlocode`` เทียบกับ ``freight.facilities.unlocode``
    ไม่ใช่กับ ``geo.border_crossings.unlocode`` — จุดนี้เคยสลับกันมาแล้วครั้งหนึ่ง
    """

    origin_unlocode: UnLocode
    destination_unlocode: UnLocode
    mode: Literal["road", "rail", "sea", "air", "barge"]
    base_minor: int = Field(ge=0)
    per_km_minor: int = Field(ge=0)
    minimum_charge_minor: int = Field(ge=0)
    transit_days: int = Field(ge=0, le=120)


class RateBreakCreate(_Model):
    """ขั้นน้ำหนัก: ตั้งแต่ ``from_kg`` (รวม) ถึง ``to_kg`` (ไม่รวม) คิดตัวคูณกี่ basis point"""

    from_kg: int = Field(ge=0)
    to_kg: int | None = Field(default=None, ge=1)
    multiplier_bp: BasisPoints


class SurchargeRuleCreate(_Model):
    charge_code: ChargeCode
    basis: Literal["flat", "per_km", "per_day", "per_hour", "percent_of_linehaul", "percent_of_duty"]
    amount_minor: int = Field(default=0, ge=0)
    rate_bp: BasisPoints = 0
    free_units: int = Field(default=0, ge=0)
    cap_minor: int | None = Field(default=None, ge=0)
    applies_when: str = Field(
        default="always",
        description="expression evaluated by engine.surcharges, e.g. 'container.is_reefer'",
    )


class FxRateUpsert(_Model):
    """อัตราแลกเปลี่ยนหนึ่งคู่ เก็บเป็น micro-unit (1 000 000 = 1.000000) ไม่ใช่ float"""

    base_currency: CurrencyCode
    quote_currency: CurrencyCode
    rate_micros: int = Field(gt=0)
    source: str
    observed_at: datetime


class CursorPage(_Model):
    """ซองของทุก list endpoint ตาม SPEC §0.5 — cursor เท่านั้น ไม่มี offset ที่ไหนเลย"""

    items: tuple[dict, ...]
    next_cursor: str | None = None
