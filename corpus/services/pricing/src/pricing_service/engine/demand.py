"""โมเดลอุปสงค์ขนาดเล็กที่ตัดสินว่าจะบวกราคาขึ้นกี่ basis point สำหรับเลนหนึ่งเส้น

เขียนด้วย Python ล้วน ไม่มี numpy และไม่มี dependency ทางสถิติใด ๆ — ข้อมูลเข้าเป็นจำนวนเต็ม
รายวันไม่กี่สิบจุดต่อเลน ค่าใช้จ่ายในการคำนวณเทียบไม่ได้กับค่าใช้จ่ายที่จะเกิดถ้ามีคนเผลอ
ปล่อยให้ ``float64`` ไหลเข้าไปในสายราคา

โมเดลมีสามชั้นและทุกชั้นทำงานบนจำนวนเต็มหรือ ``Decimal``:
1. ปรับฤดูกาลรายวันด้วยดัชนีวันในสัปดาห์ (multiplicative, normalise ให้เฉลี่ยเป็น 1)
2. ปรับเรียบด้วย exponential smoothing โดยใช้ ``OF_PRICING_DEMAND_SMOOTHING_ALPHA_BP``
3. แปลงอัตราการใช้ความจุ (utilisation) เป็น uplift ผ่านเส้นโลจิสติกที่ถูกตัดยอดด้วย
   ``OF_PRICING_DEMAND_MAX_UPLIFT_BP``
"""

from __future__ import annotations

import datetime as dt
import math
from dataclasses import dataclass
from decimal import Decimal
from typing import Sequence

from pricing_service.engine.money import BASIS_POINT_SCALE

# จุดกึ่งกลางของเส้นโลจิสติก: utilisation เท่านี้ให้ uplift ครึ่งหนึ่งของเพดาน
# ค่านี้มาจากการ fit ย้อนหลังของทีมพาณิชย์ ไม่ใช่จากทฤษฎี และถูก review ปีละครั้ง
_MIDPOINT_BP = 7_800
# ความชันของเส้น ยิ่งมากยิ่งเปลี่ยนเร็วรอบ ๆ จุดกึ่งกลาง
_STEEPNESS = 9.0
# จำนวนจุดข้อมูลขั้นต่ำก่อนจะยอมให้โมเดลขยับราคาเลย ต่ำกว่านี้คืน 0 เสมอ
MIN_OBSERVATIONS = 14


@dataclass(frozen=True, slots=True)
class DemandPoint:
    """หนึ่งแถวจาก ``pricing.demand_observations`` ที่ถูกอ่านเข้ามาแล้ว"""

    business_date: dt.date
    booked_count: int
    capacity_slots: int | None
    quoted_count: int = 0
    accepted_count: int = 0


@dataclass(frozen=True, slots=True)
class DemandSignal:
    """ผลลัพธ์ของโมเดล พร้อมตัวเลขกลางทางที่ทำให้อธิบายราคาให้ลูกค้าได้

    Attributes:
        uplift_bp: ค่าที่จะเอาไปคูณกับ ``linehaul`` — ศูนย์ได้ ติดลบไม่ได้
        smoothed_bookings_milli: อุปสงค์ที่ปรับเรียบแล้ว คูณพันเพื่อคงความละเอียด
        utilisation_bp: อัตราการใช้ความจุที่ประเมินได้
        observations_used: จำนวนจุดข้อมูลที่เข้าเงื่อนไข
        reason: สาเหตุแบบสั้นที่โผล่ไปอยู่ใน ``pricing.quotes.rating_inputs``
    """

    uplift_bp: int
    smoothed_bookings_milli: int
    utilisation_bp: int
    observations_used: int
    reason: str


def weekday_indices(points: Sequence[DemandPoint]) -> dict[int, int]:
    """คำนวณดัชนีฤดูกาลรายวันในสัปดาห์ คืนค่าเป็น basis point (10000 = ไม่ปรับ)

    วันที่ไม่มีข้อมูลเลยจะได้ 10000 แทนที่จะหายไปจาก dict เพื่อให้ผู้เรียกไม่ต้องเช็ค None
    ทุกครั้ง วันจันทร์คือ 0 ตาม ``date.weekday()``

    เหตุที่ต้องมี: ท่าเรือยุโรปรับจองวันศุกร์มากกว่าวันอาทิตย์ราวสามเท่า ถ้าไม่หักฤดูกาลออก
    โมเดลจะขึ้นราคาทุกวันศุกร์เป็นระบบ ซึ่งลูกค้าจับได้ภายในสองสัปดาห์
    """

    if not points:
        return {day: BASIS_POINT_SCALE for day in range(7)}

    sums: dict[int, int] = {day: 0 for day in range(7)}
    counts: dict[int, int] = {day: 0 for day in range(7)}
    for point in points:
        day = point.business_date.weekday()
        sums[day] += point.booked_count
        counts[day] += 1

    overall_total = sum(sums.values())
    overall_count = sum(counts.values())
    if overall_count == 0 or overall_total == 0:
        return {day: BASIS_POINT_SCALE for day in range(7)}

    overall_mean = Decimal(overall_total) / Decimal(overall_count)
    indices: dict[int, int] = {}
    for day in range(7):
        if counts[day] == 0 or overall_mean == 0:
            indices[day] = BASIS_POINT_SCALE
            continue
        day_mean = Decimal(sums[day]) / Decimal(counts[day])
        indices[day] = int((day_mean / overall_mean * BASIS_POINT_SCALE).to_integral_value())
    return indices


def deseasonalise(points: Sequence[DemandPoint], indices: dict[int, int]) -> list[int]:
    """หารอุปสงค์รายวันด้วยดัชนีของวันนั้น คืนเป็นจำนวนเต็มคูณพัน

    ดัชนีที่เป็นศูนย์ (วันที่ไม่เคยมีการจองเลยตลอดหน้าต่าง) ถูกกันไว้ที่ 1 bp เพื่อไม่ให้หารด้วยศูนย์
    ผลที่ได้จะดูสูงผิดปกติ แต่ชั้น smoothing ข้างล่างกลืนมันได้
    """

    result: list[int] = []
    for point in points:
        index_bp = max(indices.get(point.business_date.weekday(), BASIS_POINT_SCALE), 1)
        value_milli = point.booked_count * 1_000 * BASIS_POINT_SCALE // index_bp
        result.append(value_milli)
    return result


def exponential_smooth(series_milli: Sequence[int], alpha_bp: int) -> int:
    """ปรับเรียบแบบ single exponential smoothing บนจำนวนเต็ม

    Args:
        series_milli: อนุกรมที่เรียงตามเวลาจากเก่าไปใหม่ หน่วยคูณพันแล้ว
        alpha_bp: น้ำหนักของค่าล่าสุด เป็น basis point เช่น 2500 = 0.25

    Returns:
        int: ค่าที่ปรับเรียบแล้ว หน่วยคูณพันเช่นเดิม

    สูตรคือ ``s_t = α·x_t + (1-α)·s_{t-1}`` แต่ทำบนจำนวนเต็มเพื่อให้ผลลัพธ์ซ้ำได้เป๊ะทุก
    สถาปัตยกรรม — โมเดลนี้มีอิทธิพลต่อราคาจริง จึงต้อง reproducible ไม่ใช่แค่ "ใกล้เคียง"
    """

    if not series_milli:
        return 0
    alpha = max(1, min(alpha_bp, BASIS_POINT_SCALE))
    smoothed = series_milli[0]
    for value in series_milli[1:]:
        smoothed = (alpha * value + (BASIS_POINT_SCALE - alpha) * smoothed) // BASIS_POINT_SCALE
    return smoothed


def utilisation_bp(points: Sequence[DemandPoint], smoothed_milli: int) -> int:
    """ประเมินอัตราการใช้ความจุเป็น basis point

    ถ้าเลนไหนไม่เคยประกาศ ``capacity_slots`` เลย เราถอยไปใช้ค่าสูงสุดในประวัติเป็นตัวแทน
    ความจุ ซึ่งเป็นการประเมินแบบอนุรักษ์นิยม: utilisation จะไม่มีทางเกิน 10000 และโมเดล
    จะขึ้นราคาน้อยกว่าความเป็นจริง ซึ่งเป็นทิศทางที่ยอมรับได้มากกว่าอีกทาง
    """

    declared = [p.capacity_slots for p in points if p.capacity_slots]
    if declared:
        capacity_milli = (sum(declared) // len(declared)) * 1_000
    else:
        peak = max((p.booked_count for p in points), default=0)
        capacity_milli = peak * 1_000
    if capacity_milli <= 0:
        return 0
    return min(BASIS_POINT_SCALE, smoothed_milli * BASIS_POINT_SCALE // capacity_milli)


def _logistic_bp(utilisation: int, max_uplift_bp: int) -> int:
    """แปลง utilisation เป็น uplift ด้วยเส้นโลจิสติก

    ``math.exp`` เป็น float แต่ float ตัวนี้ไม่เคยแตะจำนวนเงิน — ผลลัพธ์ถูกปัดเป็น
    basis point จำนวนเต็มก่อนออกจากฟังก์ชัน แล้วการคูณกับเงินทำด้วย ``mul_bp`` ทั้งหมด
    """

    x = (utilisation - _MIDPOINT_BP) / BASIS_POINT_SCALE
    ratio = 1.0 / (1.0 + math.exp(-_STEEPNESS * x))
    return int(round(ratio * max_uplift_bp))


def compute_uplift(
    points: Sequence[DemandPoint],
    *,
    alpha_bp: int,
    max_uplift_bp: int,
    window_days: int,
    today: dt.date,
) -> DemandSignal:
    """เรียกทั้งสามชั้นตามลำดับแล้วคืน uplift ที่พร้อมใช้

    Args:
        points: ประวัติของเลน ไม่จำเป็นต้องเรียงมาก่อน
        alpha_bp: ``OF_PRICING_DEMAND_SMOOTHING_ALPHA_BP``
        max_uplift_bp: ``OF_PRICING_DEMAND_MAX_UPLIFT_BP`` — เพดานแข็ง
        window_days: ``OF_PRICING_DEMAND_WINDOW_DAYS`` นับถอยหลังจาก ``today``
        today: วันอ้างอิง

    Returns:
        DemandSignal: uplift พร้อมเหตุผล ถ้าข้อมูลน้อยกว่า ``MIN_OBSERVATIONS`` จะได้ 0
        พร้อม ``reason='insufficient_history'`` — เงียบ ๆ ไม่ขึ้นราคา ดีกว่าขึ้นจากข้อมูลบาง
    """

    cutoff = today - dt.timedelta(days=window_days)
    window = sorted(
        (p for p in points if cutoff <= p.business_date <= today),
        key=lambda p: p.business_date,
    )
    if len(window) < MIN_OBSERVATIONS:
        return DemandSignal(0, 0, 0, len(window), "insufficient_history")

    indices = weekday_indices(window)
    deseasonalised = deseasonalise(window, indices)
    smoothed = exponential_smooth(deseasonalised, alpha_bp)
    utilisation = utilisation_bp(window, smoothed)
    uplift = min(_logistic_bp(utilisation, max_uplift_bp), max_uplift_bp)

    # ต่ำกว่าครึ่งเปอร์เซ็นต์ไม่คุ้มจะอธิบายให้ลูกค้าฟัง ปัดทิ้งเป็นศูนย์ไปเลย
    if uplift < 50:
        return DemandSignal(0, smoothed, utilisation, len(window), "below_noise_floor")

    return DemandSignal(uplift, smoothed, utilisation, len(window), "logistic_utilisation")
