"""แกนกลางของการคิดราคา: รับข้อเท็จจริงที่รวบรวมมาแล้ว คืนออกมาเป็นชุดบรรทัดค่าใช้จ่าย
กับยอดรวม โดยไม่แตะฐานข้อมูลและไม่ยิง HTTP เลยแม้แต่ครั้งเดียว

ลำดับการคิดตายตัวและห้ามสลับ เพราะแต่ละขั้นเป็นฐานของขั้นถัดไป:

1. หาเลนใน rate card ที่ตรงกับ origin/destination/mode
2. คิด ``linehaul`` จาก base + ระยะทาง แล้วคูณด้วยขั้นน้ำหนักและตัวคูณชนิดตู้
3. บวก uplift จากโมเดลอุปสงค์ (ไม่เกินเพดานของ ``OF_PRICING_DEMAND_MAX_UPLIFT_BP``)
4. คิดค่าธรรมเนียมทุกข้อจาก ``engine/surcharges.py`` โดยใช้ linehaul หลัง uplift เป็นฐาน
5. ประมาณอากรและภาษีจากอัตราที่ customs-service ตอบมา (``GET /v1/tariffs/lookup``)
6. แปลงทุกบรรทัดเป็นสกุลของลูกค้าด้วยอัตราเดียวที่ถูกแช่ไว้กับ quote
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from typing import Sequence

from pricing_service.engine.demand import DemandSignal
from pricing_service.engine.fx import RateQuote, convert_all, reconcile_rounding
from pricing_service.engine.money import BASIS_POINT_SCALE, Money, convert, mul_bp, total
from pricing_service.engine.surcharges import (
    SurchargeContext,
    SurchargeLine,
    SurchargeRuleView,
    apply_rules,
    fuel_surcharge_bp,
)


class LaneNotCovered(LookupError):
    """ไม่มีเลนใน rate card ที่ครอบคลุมคู่ท่านี้ — ชั้น API แปลงเป็น HTTP 422"""


class RateBreakGap(ValueError):
    """ขั้นน้ำหนักของเลนมีช่องโหว่ ทำให้น้ำหนักบางช่วงไม่มีตัวคูณ

    ถือเป็น configuration bug ไม่ใช่กรณีปกติ: การเงียบแล้วใช้ตัวคูณ 1.0 แทนเคยทำให้
    ตู้หนัก 28 ตันถูกคิดราคาเท่าตู้เปล่าอยู่สามสัปดาห์ก่อนจะมีคนสังเกต
    """


@dataclass(frozen=True, slots=True)
class LaneView:
    """สำเนา read-only ของ ``pricing.rate_card_lanes`` หนึ่งแถว พร้อมขั้นน้ำหนักของมัน"""

    lane_id: str
    origin_unlocode: str
    destination_unlocode: str
    mode: str
    base_minor: int
    per_km_minor: int
    minimum_charge_minor: int
    transit_days: int
    equipment_multipliers_bp: dict[str, int]
    breaks: tuple[tuple[int, int | None, int], ...]
    """แต่ละสมาชิกคือ ``(from_kg, to_kg, multiplier_bp)`` เรียงจากเบาไปหนัก"""


@dataclass(frozen=True, slots=True)
class RatingInput:
    """ข้อเท็จจริงครบชุดที่ต้องใช้คิดราคาหนึ่งใบ

    ทุกฟิลด์ถูกเติมโดยชั้นบน (``api/routes_quotes.py`` หรือ Celery task) จาก:
    container-registry (``GET /v1/shipments/{shipment_id}``), routing-service
    (``GET /v1/shipments/{shipment_id}/route``) และ customs-service (``GET /v1/tariffs/lookup``)
    """

    tenant_id: str
    rate_card_id: str
    rate_card_currency: str
    target_currency: str
    origin_unlocode: str
    destination_unlocode: str
    mode: str
    chargeable_weight_kg: int
    iso_size_type: str | None
    distance_m: int
    leg_distances_m: tuple[int, ...] = ()
    lanes: tuple[LaneView, ...] = ()
    surcharge_rules: tuple[SurchargeRuleView, ...] = ()
    surcharge_context: SurchargeContext | None = None
    demand: DemandSignal | None = None
    fx_rate: RateQuote | None = None
    customs_value_minor: int = 0
    duty_rate_bp: int = 0
    vat_rate_bp: int = 0
    fuel_index_micros: int | None = None
    fuel_baseline_micros: int | None = None
    fuel_pass_through_bp: int = 10_000
    shipment_id: str | None = None
    route_id: str | None = None
    route_version: int | None = None
    strategy: str = "cheapest"
    rated_at: dt.datetime = field(default_factory=lambda: dt.datetime.now(dt.UTC))


@dataclass(frozen=True, slots=True)
class RatedLine:
    """หนึ่งบรรทัดในผลลัพธ์สุดท้าย อยู่ในสกุลของลูกค้าแล้ว"""

    seq_no: int
    charge_code: str
    description: str
    quantity_milli: int
    unit_price: Money
    amount: Money
    source_kind: str | None = None
    source_id: str | None = None
    rule_id: str | None = None


@dataclass(frozen=True, slots=True)
class RatingResult:
    """ผลลัพธ์ทั้งใบ พร้อมตัวเลขกลางทางที่ ``pricing.quotes`` เก็บไว้เพื่อตรวจย้อน"""

    lane_id: str
    currency: str
    lines: tuple[RatedLine, ...]
    subtotal: Money
    duty_estimate: Money
    tax_estimate: Money
    grand_total: Money
    demand_uplift_bp: int
    billable_distance_m: int
    chargeable_weight_kg: int
    fx_rate: RateQuote | None
    inputs_digest: dict[str, object]


def select_lane(inp: RatingInput) -> LaneView:
    """เลือกเลนที่ตรงที่สุดสำหรับคู่ท่าและโหมดที่ขอมา

    ถ้ามีเลนของโหมดที่ขอ ใช้ตัวนั้น ถ้าไม่มีแต่มีเลน ``road`` ของคู่เดียวกัน ใช้ ``road``
    เป็นตัวสำรอง (เป็นการตัดสินใจเชิงพาณิชย์: การขนส่งทางถนนมีให้เสมอ) ถ้าไม่มีทั้งคู่ ยก
    ``LaneNotCovered`` แทนที่จะเดา

    Raises:
        LaneNotCovered: เมื่อไม่มีเลนไหนครอบคลุม
    """

    same_pair = [
        lane
        for lane in inp.lanes
        if lane.origin_unlocode == inp.origin_unlocode
        and lane.destination_unlocode == inp.destination_unlocode
    ]
    if not same_pair:
        raise LaneNotCovered(f"{inp.origin_unlocode}->{inp.destination_unlocode}")

    exact = [lane for lane in same_pair if lane.mode == inp.mode]
    if exact:
        return exact[0]
    road = [lane for lane in same_pair if lane.mode == "road"]
    if road:
        return road[0]
    raise LaneNotCovered(f"{inp.origin_unlocode}->{inp.destination_unlocode} mode={inp.mode}")


def weight_multiplier_bp(lane: LaneView, weight_kg: int) -> int:
    """หาตัวคูณของขั้นน้ำหนักที่ครอบคลุมน้ำหนักนี้

    ขั้นถูกนิยามเป็น ``[from_kg, to_kg)`` และขั้นสุดท้ายต้องเปิดปลาย ถ้าไม่มีขั้นไหนครอบคลุม
    เลย แปลว่าเลนตั้งค่าไม่ครบ ซึ่งเป็นความผิดพลาดที่ต้องดัง ไม่ใช่ใช้ค่า default เงียบ ๆ

    Raises:
        RateBreakGap: เมื่อน้ำหนักตกอยู่ในช่องโหว่ของตาราง
    """

    if not lane.breaks:
        return BASIS_POINT_SCALE
    for from_kg, to_kg, multiplier_bp in lane.breaks:
        if weight_kg >= from_kg and (to_kg is None or weight_kg < to_kg):
            return multiplier_bp
    raise RateBreakGap(f"lane {lane.lane_id} has no break covering {weight_kg} kg")


def equipment_multiplier_bp(lane: LaneView, iso_size_type: str | None) -> int:
    """ตัวคูณตามชนิดตู้ (``freight.containers.iso_size_type``)

    ตู้ที่ไม่ได้ระบุไว้ในสัญญาใช้ 10000 (ไม่ปรับ) — ไม่ยกข้อผิดพลาด เพราะชนิดตู้ใหม่ ๆ
    โผล่มาเรื่อย ๆ และการปฏิเสธคิดราคาทั้งใบเพราะรหัสตู้ที่ไม่รู้จักไม่คุ้มกัน
    """

    if not iso_size_type:
        return BASIS_POINT_SCALE
    return lane.equipment_multipliers_bp.get(iso_size_type, BASIS_POINT_SCALE)


def compute_linehaul(lane: LaneView, inp: RatingInput) -> Money:
    """คิดค่าระวางพื้นฐานของเลนหนึ่งเส้น

    สูตร::

        raw   = base_minor + per_km_minor × ceil(distance_m / 1000)
        rated = raw × weight_multiplier × equipment_multiplier
        final = max(rated, minimum_charge_minor)

    ระยะทางปัดขึ้นเป็นกิโลเมตร ซึ่งเป็นธรรมเนียมของอุตสาหกรรม ไม่ใช่ผลของการปัดเศษเลข
    """

    currency = inp.rate_card_currency
    kilometres = -(-inp.distance_m // 1_000)
    raw = Money(lane.base_minor + lane.per_km_minor * kilometres, currency)
    weighted = mul_bp(raw, weight_multiplier_bp(lane, inp.chargeable_weight_kg))
    equipped = mul_bp(weighted, equipment_multiplier_bp(lane, inp.iso_size_type))
    return equipped.at_least(Money(lane.minimum_charge_minor, currency))


def apply_demand(linehaul: Money, demand: DemandSignal | None, cap_bp: int) -> tuple[Money, int]:
    """บวก uplift ของโมเดลอุปสงค์เข้ากับ linehaul

    Returns:
        tuple[Money, int]: (linehaul หลังปรับ, uplift ที่ใช้จริงเป็น basis point)

    uplift ถูกตัดที่ ``cap_bp`` อีกชั้นถึงแม้ ``engine/demand.py`` จะตัดมาแล้ว — กันกรณีที่
    ค่าถูกอ่านมาจาก quote เก่าที่ออกตอนเพดานยังสูงกว่านี้
    """

    if demand is None or demand.uplift_bp <= 0:
        return linehaul, 0
    uplift_bp = min(demand.uplift_bp, cap_bp)
    return linehaul + mul_bp(linehaul, uplift_bp), uplift_bp


def estimate_duty(inp: RatingInput) -> tuple[Money, Money]:
    """ประมาณอากรและภาษีมูลค่าเพิ่มจากอัตราที่ customs-service ตอบกลับมา

    Returns:
        tuple[Money, Money]: (อากร, ภาษี) ในสกุลของ rate card

    นี่คือ *การประมาณ* เท่านั้น ตัวเลขที่ผูกพันจริงมาทีหลังใน event
    ``customs.declaration.cleared`` (ฟิลด์ ``assessed_duty_minor`` / ``assessed_vat_minor``)
    ซึ่ง consumer ของเราใช้ตั้ง quote ใหม่ทับใบเดิม ห้ามเอาตัวเลขจากที่นี่ไปยิงใส่
    ``billing.invoices.duty_minor`` โดยตรง — คอลัมน์นั้นมีเจ้าของคือ customs-service
    """

    currency = inp.rate_card_currency
    if inp.customs_value_minor <= 0:
        return Money.zero(currency), Money.zero(currency)
    customs_value = Money(inp.customs_value_minor, currency)
    duty = mul_bp(customs_value, inp.duty_rate_bp)
    # ฐานภาษีคือมูลค่าศุลกากรบวกอากร ตามหลักของสหภาพยุโรป ไม่ใช่มูลค่าเปล่า
    vat = mul_bp(customs_value + duty, inp.vat_rate_bp)
    return duty, vat


def _fuel_rule(inp: RatingInput) -> SurchargeRuleView | None:
    """สร้างกฎน้ำมันขึ้นมาแบบ on the fly จากดัชนีล่าสุด

    ค่าธรรมเนียมน้ำมันไม่ได้ถูกตั้งเป็นแถวคงที่ใน ``pricing.surcharge_rules`` เพราะอัตรา
    เปลี่ยนทุกสัปดาห์ตามดัชนี การเก็บเป็นแถวแปลว่าต้องเขียนทับทุกสัปดาห์ ซึ่งขัดกับหลัก
    append-only ของตารางนั้น
    """

    if inp.fuel_index_micros is None or inp.fuel_baseline_micros is None:
        return None
    rate_bp = fuel_surcharge_bp(
        inp.fuel_index_micros, inp.fuel_baseline_micros, inp.fuel_pass_through_bp
    )
    if rate_bp <= 0:
        return None
    return SurchargeRuleView(
        rule_id="srg_derived_fuel",
        charge_code="fuel_surcharge",
        basis="percent_of_linehaul",
        amount_minor=0,
        rate_bp=rate_bp,
        free_units=0,
        cap_minor=None,
        applies_when="always",
        sort_order=10,
    )


def rate_shipment(inp: RatingInput, *, demand_cap_bp: int) -> RatingResult:
    """คิดราคาหนึ่งใบให้ครบทุกขั้น แล้วคืนผลที่พร้อมบันทึกลง ``pricing.quotes``

    Args:
        inp: ข้อเท็จจริงครบชุด
        demand_cap_bp: ``OF_PRICING_DEMAND_MAX_UPLIFT_BP``

    Returns:
        RatingResult: บรรทัดทั้งหมดในสกุล ``inp.target_currency`` พร้อมยอดรวมที่
        ``subtotal + duty + tax == grand_total`` เสมอ — ความสัมพันธ์เดียวกับ CHECK
        ``invoice_total_is_consistent`` บน ``billing.invoices``

    Raises:
        LaneNotCovered: ไม่มีเลนที่ครอบคลุม
        RateBreakGap: ขั้นน้ำหนักของเลนไม่ครบ
    """

    lane = select_lane(inp)
    base_currency = inp.rate_card_currency

    linehaul = compute_linehaul(lane, inp)
    linehaul, uplift_bp = apply_demand(linehaul, inp.demand, demand_cap_bp)

    ctx = inp.surcharge_context or SurchargeContext(
        flags=frozenset({"always"}),
        fields={},
        linehaul=linehaul,
        billable_distance_m=inp.distance_m,
        leg_distances_m=inp.leg_distances_m,
    )
    # บริบทถูกสร้างก่อนจะรู้ linehaul หลัง uplift จึงต้องเปลี่ยนค่านั้นให้ตรงก่อนคิดค่าธรรมเนียม
    # แบบเปอร์เซ็นต์ มิฉะนั้นค่าน้ำมันจะคิดจากฐานเก่าและต่ำกว่าที่ควรอยู่เสมอ
    ctx = SurchargeContext(
        flags=ctx.flags,
        fields=ctx.fields,
        linehaul=linehaul,
        billable_distance_m=ctx.billable_distance_m or inp.distance_m,
        free_time_days=ctx.free_time_days,
        dwell_days=ctx.dwell_days,
        detention_days=ctx.detention_days,
        reefer_hours=ctx.reefer_hours,
        waiting_minutes=ctx.waiting_minutes,
        hazard_class_codes=ctx.hazard_class_codes,
        declaration_count=ctx.declaration_count,
        assessed_duty=ctx.assessed_duty,
        fuel_index_micros=inp.fuel_index_micros,
        fuel_baseline_micros=inp.fuel_baseline_micros,
        leg_distances_m=ctx.leg_distances_m or inp.leg_distances_m,
        source_ids=ctx.source_ids,
    )

    rules = list(inp.surcharge_rules)
    fuel = _fuel_rule(inp)
    if fuel is not None:
        rules.append(fuel)

    surcharge_lines: list[SurchargeLine] = apply_rules(rules, ctx, currency=base_currency)

    duty, vat = estimate_duty(inp)

    # ---- ประกอบบรรทัดในสกุลของ rate card ก่อน แล้วค่อยแปลงทีเดียว ----------------
    base_lines: list[tuple[str, str, int, Money, Money, str | None, str | None, str | None]] = [
        (
            "linehaul",
            f"Linehaul {lane.origin_unlocode}-{lane.destination_unlocode} via {lane.mode}",
            1_000,
            linehaul,
            linehaul,
            "leg",
            inp.route_id,
            None,
        )
    ]
    for line in surcharge_lines:
        base_lines.append(
            (
                line.charge_code,
                line.description,
                line.quantity_milli,
                line.unit_price,
                line.amount,
                line.source_kind,
                line.source_id,
                line.rule_id,
            )
        )

    amounts = [row[4] for row in base_lines]
    subtotal_base = total(amounts, base_currency)

    rate = inp.fx_rate
    if rate is None or inp.target_currency == base_currency:
        converted_amounts = amounts
        converted_units = [row[3] for row in base_lines]
        subtotal = Money(subtotal_base.minor, inp.target_currency)
        duty_out = Money(duty.minor, inp.target_currency)
        vat_out = Money(vat.minor, inp.target_currency)
    else:
        converted_amounts = convert_all(amounts, inp.target_currency, rate)
        converted_units = convert_all([row[3] for row in base_lines], inp.target_currency, rate)
        subtotal = convert(subtotal_base, inp.target_currency, rate.rate_micros)
        # แปลงยอดรวมแยกจากบรรทัด แล้วดันเศษที่ต่างกันไม่กี่หน่วยย่อยเข้าบรรทัดใหญ่สุด
        # เพื่อให้ผลรวมของบรรทัดเท่ากับยอดรวมที่โฆษณาไว้เป๊ะ
        converted_amounts = reconcile_rounding(converted_amounts, subtotal)
        duty_out = convert(duty, inp.target_currency, rate.rate_micros)
        vat_out = convert(vat, inp.target_currency, rate.rate_micros)

    lines = tuple(
        RatedLine(
            seq_no=index + 1,
            charge_code=row[0],
            description=row[1],
            quantity_milli=row[2],
            unit_price=converted_units[index],
            amount=converted_amounts[index],
            source_kind=row[5],
            source_id=row[6],
            rule_id=row[7],
        )
        for index, row in enumerate(base_lines)
    )

    grand_total = Money(subtotal.minor + duty_out.minor + vat_out.minor, inp.target_currency)

    return RatingResult(
        lane_id=lane.lane_id,
        currency=inp.target_currency,
        lines=lines,
        subtotal=subtotal,
        duty_estimate=duty_out,
        tax_estimate=vat_out,
        grand_total=grand_total,
        demand_uplift_bp=uplift_bp,
        billable_distance_m=inp.distance_m,
        chargeable_weight_kg=inp.chargeable_weight_kg,
        fx_rate=rate,
        inputs_digest={
            "rate_card_id": inp.rate_card_id,
            "lane_id": lane.lane_id,
            "route_id": inp.route_id,
            "route_version": inp.route_version,
            "strategy": inp.strategy,
            "distance_m": inp.distance_m,
            "chargeable_weight_kg": inp.chargeable_weight_kg,
            "iso_size_type": inp.iso_size_type,
            "duty_rate_bp": inp.duty_rate_bp,
            "vat_rate_bp": inp.vat_rate_bp,
            "fuel_index_micros": inp.fuel_index_micros,
            "demand_reason": inp.demand.reason if inp.demand else "not_applied",
            "rated_at": inp.rated_at.isoformat().replace("+00:00", "Z"),
        },
    )


def chargeable_weight_kg(gross_kg: int, volume_cm3: int | None, mode: str) -> int:
    """คำนวณน้ำหนักที่ใช้คิดเงิน = ค่าที่มากกว่าระหว่างน้ำหนักจริงกับน้ำหนักเชิงปริมาตร

    ตัวหารเชิงปริมาตรต่างกันตามโหมด: ทางอากาศ 6000 cm³/kg, ทางถนนกับราง 3000,
    ส่วนทางทะเลและเรือลำเลียงคิดตามน้ำหนักจริงล้วน ตัวเลขเหล่านี้เป็นธรรมเนียม IATA/CMR
    ไม่ใช่ค่าที่เราตั้งเอง จึงไม่ได้ทำให้ตั้งค่าได้ผ่าน environment
    """

    divisors = {"air": 6_000, "road": 3_000, "rail": 3_000}
    divisor = divisors.get(mode)
    if divisor is None or not volume_cm3:
        return gross_kg
    volumetric = -(-volume_cm3 // divisor)
    return max(gross_kg, volumetric)


def summarise(result: RatingResult) -> dict[str, int]:
    """ยุบผลลัพธ์เป็นยอดต่อ ``charge_code`` — ใช้ในล็อกและใน dashboard ของ console"""

    buckets: dict[str, int] = {}
    for line in result.lines:
        buckets[line.charge_code] = buckets.get(line.charge_code, 0) + line.amount.minor
    return buckets


def lines_for_billing(result: RatingResult) -> Sequence[dict[str, object]]:
    """แปลงผลลัพธ์เป็นรูปที่ billing-service เอาไปสร้าง ``billing.invoice_lines`` ได้ตรง ๆ

    ``quantity`` ถูกส่งเป็นสตริงทศนิยมสามหลักเพื่อให้ตรงกับ ``NUMERIC(12,3)`` ปลายทาง
    โดยไม่ต้องผ่าน float ระหว่างทาง — เป็นจุดที่ SPEC §7.4 พูดถึงตรง ๆ
    """

    payload: list[dict[str, object]] = []
    for line in result.lines:
        whole, milli = divmod(line.quantity_milli, 1_000)
        payload.append(
            {
                "seq_no": line.seq_no,
                "charge_code": line.charge_code,
                "description": line.description,
                "quantity": f"{whole}.{milli:03d}",
                "unit_price_minor": line.unit_price.minor,
                "amount_minor": line.amount.minor,
                "currency": line.amount.currency,
                "source_kind": line.source_kind,
                "source_id": line.source_id,
            }
        )
    return payload
