"""คิดค่าธรรมเนียมทุกตัวที่ไม่ใช่ค่าระวางพื้นฐาน แล้วคายออกมาเป็นบรรทัดที่มี ``charge_code``
ตรงกับที่ ``billing.invoice_lines`` ยอมรับเท่านั้น

รายการที่ผลิตได้จากไฟล์นี้: ``fuel_surcharge``, ``demurrage``, ``detention``, ``reefer_power``,
``hazmat_handling``, ``waiting_time``, ``customs_clearance`` และ ``duty_disbursement``
ส่วน ``linehaul`` เป็นของ ``engine/rating.py``

ตัวตีความเงื่อนไข ``applies_when`` อยู่ในไฟล์นี้ด้วย และตั้งใจให้มันโง่: รองรับแค่ชื่อธง
กับการเปรียบเทียบเท่ากับสตริง ไม่มี ``eval`` ไม่มีวงเล็บ ไม่มีเลขคณิต — กฎราคาไม่ใช่ที่ทางของ
ภาษาโปรแกรมย่อย ๆ
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Sequence

from pricing_service.engine.money import Money, allocate, mul_bp

# --- บริบทที่เงื่อนไขอ้างถึงได้ -------------------------------------------------------
# ชื่อเหล่านี้คือ "คำศัพท์" ทั้งหมดที่ applies_when รู้จัก การเพิ่มคำใหม่ต้องเพิ่มที่นี่
# พร้อมกับที่เอกสารของทีมพาณิชย์ มิฉะนั้นกฎที่ตั้งไว้จะเงียบ ๆ ไม่เคยเข้าเงื่อนไขเลย
SUPPORTED_FLAGS = frozenset(
    {
        "always",
        "container.is_reefer",
        "container.is_hazmat",
        "shipment.is_cross_border",
        "shipment.is_import",
        "shipment.has_open_alert",
        "shipment.exceeded_free_time",
        "route.has_border_crossing",
        "route.is_multimodal",
    }
)

SUPPORTED_FIELDS = frozenset(
    {
        "shipment.status",
        "shipment.incoterm",
        "shipment.region_code",
        "route.primary_mode",
        "container.iso_size_type",
    }
)


@dataclass(frozen=True, slots=True)
class SurchargeContext:
    """ข้อเท็จจริงทั้งหมดที่กฎค่าธรรมเนียมมองเห็น

    ค่าพวกนี้ถูกประกอบใน ``engine/rating.py`` จากสิ่งที่ client ไปดึงมา: shipment กับตู้จาก
    container-registry, route กับ leg จาก routing-service, ผลอากรจาก customs-service
    และ alert ที่ยังเปิดอยู่จาก event ``telemetry.alert.raised`` ที่เราสะสมไว้
    """

    flags: frozenset[str]
    fields: Mapping[str, str]
    linehaul: Money
    billable_distance_m: int
    free_time_days: int = 0
    dwell_days: int = 0
    detention_days: int = 0
    reefer_hours: int = 0
    waiting_minutes: int = 0
    hazard_class_codes: tuple[str, ...] = ()
    declaration_count: int = 0
    assessed_duty: Money | None = None
    fuel_index_micros: int | None = None
    fuel_baseline_micros: int | None = None
    leg_distances_m: tuple[int, ...] = ()
    source_ids: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class SurchargeRuleView:
    """กฎหนึ่งข้อในรูปที่ engine ใช้ — สำเนา read-only ของ ``pricing.surcharge_rules``"""

    rule_id: str
    charge_code: str
    basis: str
    amount_minor: int
    rate_bp: int
    free_units: int
    cap_minor: int | None
    applies_when: str
    sort_order: int


@dataclass(frozen=True, slots=True)
class SurchargeLine:
    """หนึ่งบรรทัดที่พร้อมกลายเป็น ``pricing.quote_lines`` แล้วต่อไปเป็น ``billing.invoice_lines``"""

    charge_code: str
    description: str
    quantity_milli: int
    unit_price: Money
    amount: Money
    rule_id: str | None = None
    source_kind: str | None = None
    source_id: str | None = None


class UnknownPredicate(ValueError):
    """``applies_when`` อ้างถึงคำที่ไม่มีในคำศัพท์ — ยกตอนโหลด rate card ไม่ใช่ตอนคิดราคา"""


def evaluate_predicate(expression: str, ctx: SurchargeContext) -> bool:
    """ตีความเงื่อนไขหนึ่งข้อ

    รูปแบบที่รองรับมีสองแบบเท่านั้น:

    * ธงเปล่า ๆ เช่น ``container.is_reefer`` — จริงเมื่อธงนั้นถูกยกใน ``ctx.flags``
    * เทียบเท่ากับสตริง เช่น ``shipment.status == 'held_at_customs'``

    Args:
        expression: ค่าจาก ``pricing.surcharge_rules.applies_when``
        ctx: บริบทของ shipment ที่กำลังคิดราคา

    Returns:
        bool: เข้าเงื่อนไขหรือไม่

    Raises:
        UnknownPredicate: เมื่อชื่อที่อ้างถึงไม่อยู่ใน ``SUPPORTED_FLAGS``/``SUPPORTED_FIELDS``
    """

    text = expression.strip()
    if not text or text == "always":
        return True

    if "==" in text:
        left, right = (part.strip() for part in text.split("==", 1))
        if left not in SUPPORTED_FIELDS:
            raise UnknownPredicate(f"{left} is not a comparable field")
        wanted = right.strip("'\"")
        return ctx.fields.get(left) == wanted

    if text.startswith("!"):
        return not evaluate_predicate(text[1:], ctx)

    if text not in SUPPORTED_FLAGS:
        raise UnknownPredicate(f"{text} is not a known flag")
    return text in ctx.flags


# --- ตัวคิดตาม basis -----------------------------------------------------------------


def _billable_units(rule: SurchargeRuleView, ctx: SurchargeContext) -> int:
    """จำนวนหน่วยที่คิดเงินได้จริง หลังหักโควตาฟรีของกฎข้อนั้น

    หน่วยขึ้นกับ ``basis``: กิโลเมตรสำหรับ ``per_km``, วันสำหรับ ``per_day``,
    ชั่วโมงสำหรับ ``per_hour`` ส่วน ``flat`` และแบบเปอร์เซ็นต์คืน 1 เสมอ
    """

    if rule.basis == "per_km":
        kilometres = ctx.billable_distance_m // 1_000
        return max(0, kilometres - rule.free_units)
    if rule.basis == "per_day":
        days = ctx.dwell_days if rule.charge_code == "demurrage" else ctx.detention_days
        return max(0, days - max(rule.free_units, ctx.free_time_days))
    if rule.basis == "per_hour":
        hours = ctx.reefer_hours if rule.charge_code == "reefer_power" else ctx.waiting_minutes // 60
        return max(0, hours - rule.free_units)
    return 1


def _amount_for(rule: SurchargeRuleView, ctx: SurchargeContext, currency: str) -> Money:
    """คำนวณยอดของกฎหนึ่งข้อ ก่อนใส่เพดาน"""

    if rule.basis == "percent_of_linehaul":
        return mul_bp(ctx.linehaul, rule.rate_bp)
    if rule.basis == "percent_of_duty":
        if ctx.assessed_duty is None:
            return Money.zero(currency)
        return mul_bp(ctx.assessed_duty, rule.rate_bp)
    units = _billable_units(rule, ctx)
    return Money(rule.amount_minor * units, currency)


def fuel_surcharge_bp(index_micros: int, baseline_micros: int, pass_through_bp: int) -> int:
    """แปลงส่วนต่างดัชนีน้ำมันเป็นอัตราค่าธรรมเนียม (basis point)

    สูตร: ``(index - baseline) / baseline × pass_through`` โดยถ้าดัชนีต่ำกว่า baseline
    ผลลัพธ์คือศูนย์ ไม่ใช่ค่าติดลบ — สัญญามาตรฐานของแพลตฟอร์มไม่มีการคืนเงินค่าน้ำมัน

    การหารทำบนจำนวนเต็มล้วน ปัดลง ซึ่งเอนเข้าหาลูกค้าอย่างสม่ำเสมอ ทีมพาณิชย์ยอมรับ
    ความเอนทิศนี้อย่างชัดแจ้งตอน review รอบเดือนพฤศจิกายน
    """

    if baseline_micros <= 0 or index_micros <= baseline_micros:
        return 0
    delta = index_micros - baseline_micros
    return delta * pass_through_bp // baseline_micros


def apply_rules(
    rules: Sequence[SurchargeRuleView],
    ctx: SurchargeContext,
    *,
    currency: str,
    describe: Callable[[SurchargeRuleView, int], str] | None = None,
) -> list[SurchargeLine]:
    """เดินผ่านกฎทุกข้อตามลำดับ ``sort_order`` แล้วคายบรรทัดที่มียอดไม่เป็นศูนย์

    Args:
        rules: กฎทั้งหมดของ rate card ที่ถูกเลือกแล้ว
        ctx: บริบทของ shipment
        currency: สกุลของ rate card — ทุกบรรทัดออกมาในสกุลนี้ การแปลงเป็นสกุลลูกค้า
            เกิดขึ้นทีเดียวที่ชั้นบนใน ``engine/fx.py``
        describe: ตัวสร้างคำอธิบายบรรทัด ใช้แทนของ default เวลาต้องการภาษาอื่น

    Returns:
        list[SurchargeLine]: เรียงตาม ``sort_order`` แล้ว บรรทัดยอดศูนย์ถูกตัดทิ้ง
        เพราะใบแจ้งหนี้ที่มีบรรทัด 0.00 ทำให้ลูกค้าโทรมาถามทุกครั้ง
    """

    lines: list[SurchargeLine] = []
    for rule in sorted(rules, key=lambda r: (r.sort_order, r.charge_code)):
        if not evaluate_predicate(rule.applies_when, ctx):
            continue

        amount = _amount_for(rule, ctx, currency)
        if rule.cap_minor is not None:
            amount = amount.capped_at(Money(rule.cap_minor, currency))
        if amount.minor == 0:
            continue

        units = _billable_units(rule, ctx)
        unit_price = Money(amount.minor // units if units else amount.minor, currency)
        text = describe(rule, units) if describe else _default_description(rule, units)
        lines.append(
            SurchargeLine(
                charge_code=rule.charge_code,
                description=text,
                quantity_milli=units * 1_000,
                unit_price=unit_price,
                amount=amount,
                rule_id=rule.rule_id,
                source_kind=_source_kind_for(rule.charge_code),
                source_id=ctx.source_ids.get(rule.charge_code),
            )
        )
    return lines


def _source_kind_for(charge_code: str) -> str | None:
    """แมป ``charge_code`` ไปเป็น ``source_kind`` ที่ ``billing.invoice_lines`` ยอมรับ

    ค่าที่คืนได้มีเฉพาะ ``leg`` ``alert`` ``declaration`` ``assignment`` ``manual`` เท่านั้น
    ตาม CHECK ของตารางนั้น — reconciliation-service ใช้คู่ ``(source_kind, source_id)``
    ในการจับคู่ย้อนกลับ ค่าที่ผิดจะทำให้มันเปิด ``unbilled_accessorial`` ทิ้งไว้
    """

    return {
        "linehaul": "leg",
        "fuel_surcharge": "leg",
        "demurrage": "leg",
        "detention": "assignment",
        "waiting_time": "assignment",
        "reefer_power": "alert",
        "hazmat_handling": None,
        "customs_clearance": "declaration",
        "duty_disbursement": "declaration",
    }.get(charge_code)


def _default_description(rule: SurchargeRuleView, units: int) -> str:
    """คำอธิบายบรรทัดเป็นภาษาอังกฤษเสมอ — ข้อความบนสายและบนใบแจ้งหนี้ไม่ตามภาษาของทีม"""

    label = rule.charge_code.replace("_", " ").title()
    if rule.basis == "per_day":
        return f"{label} — {units} chargeable day(s)"
    if rule.basis == "per_hour":
        return f"{label} — {units} chargeable hour(s)"
    if rule.basis == "per_km":
        return f"{label} — {units} km"
    if rule.basis == "percent_of_linehaul":
        return f"{label} — {rule.rate_bp / 100:.2f}% of linehaul"
    if rule.basis == "percent_of_duty":
        return f"{label} — {rule.rate_bp / 100:.2f}% of assessed duty"
    return label


def spread_across_legs(amount: Money, leg_distances_m: Sequence[int]) -> list[Money]:
    """กระจายค่าธรรมเนียมหนึ่งก้อนลงราย leg ตามระยะทาง

    ใช้ตอน billing-service ขอ breakdown ราย leg เพื่อผูก ``source_id`` เป็น ``leg_…``
    ผลรวมของชิ้นส่วนเท่ากับต้นทางเป๊ะเสมอ เพราะเรียก ``allocate`` ไม่ได้ปัดเองทีละชิ้น
    """

    return allocate(amount, list(leg_distances_m))


def context_from_facts(facts: Mapping[str, Any]) -> SurchargeContext:
    """ประกอบ ``SurchargeContext`` จาก dict ดิบที่ ``engine/rating.py`` เตรียมไว้

    แยกออกมาเป็นฟังก์ชันเพื่อให้เทสต์ป้อน dict ตรง ๆ ได้โดยไม่ต้องมี HTTP client จริง
    """

    return SurchargeContext(
        flags=frozenset(facts.get("flags", ())),
        fields=dict(facts.get("fields", {})),
        linehaul=facts["linehaul"],
        billable_distance_m=int(facts.get("billable_distance_m", 0)),
        free_time_days=int(facts.get("free_time_days", 0)),
        dwell_days=int(facts.get("dwell_days", 0)),
        detention_days=int(facts.get("detention_days", 0)),
        reefer_hours=int(facts.get("reefer_hours", 0)),
        waiting_minutes=int(facts.get("waiting_minutes", 0)),
        hazard_class_codes=tuple(facts.get("hazard_class_codes", ())),
        declaration_count=int(facts.get("declaration_count", 0)),
        assessed_duty=facts.get("assessed_duty"),
        fuel_index_micros=facts.get("fuel_index_micros"),
        fuel_baseline_micros=facts.get("fuel_baseline_micros"),
        leg_distances_m=tuple(facts.get("leg_distances_m", ())),
        source_ids=dict(facts.get("source_ids", {})),
    )


def free_time_expired(gate_in_at: dt.datetime, now: dt.datetime, free_days: int) -> bool:
    """เช็คว่าเลยเวลาปลอด demurrage แล้วหรือยัง

    ``gate_in_at`` มาจากรายการสแกนชนิด ``gate_in`` ใน ``freight.shipment_scan_events``
    ซึ่งเรารู้ผ่าน event ``shipment.scanned`` — ไม่ได้ query ตารางนั้นเอง
    """

    return (now - gate_in_at) > dt.timedelta(days=free_days)
