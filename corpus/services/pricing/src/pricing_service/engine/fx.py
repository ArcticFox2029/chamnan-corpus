"""เลือกอัตราแลกเปลี่ยนที่ "ใช้ได้" สำหรับ quote หนึ่งใบ และแปลงสกุลเงินด้วยอัตรานั้น

กติกาที่ทั้งไฟล์นี้ยึด: อัตราถูกเลือกครั้งเดียวตอนออกใบ แล้วแช่ลง ``pricing.quotes.fx_rate_micros``
ห้ามคำนวณใหม่ตอนอ่าน — billing-service ก็แช่อัตราตอนออกใบแจ้งหนี้เหมือนกัน
(``OF_BILLING_FX_RATE_SOURCE`` "rates are frozen on issue") ถ้าฝั่งใดฝั่งหนึ่งไปคิดสด
ยอดสองใบจะต่างกันโดยไม่มีใครผิด และ reconciliation-service จะเปิด ``duty_mismatch`` ทิ้งไว้
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import Iterable, Sequence

from pricing_service.engine.money import MICRO_SCALE, Money, convert


@dataclass(frozen=True, slots=True)
class RateQuote:
    """อัตราหนึ่งจุดที่หยิบออกมาจาก ``pricing.fx_rates`` แล้ว"""

    base_currency: str
    quote_currency: str
    rate_micros: int
    source: str
    observed_at: dt.datetime

    def age_seconds(self, now: dt.datetime) -> int:
        return max(0, int((now - self.observed_at).total_seconds()))

    def inverted(self) -> "RateQuote":
        """กลับทิศอัตรา — ใช้เมื่อในตารางมีแค่ทิศเดียวของคู่นั้น

        การปัดเศษของทิศกลับทำที่นี่ครั้งเดียว ไม่ได้เก็บลงตาราง เพื่อไม่ให้มีสองแถวที่
        คูณกลับไปกลับมาแล้วไม่ได้ 1.000000
        """

        return RateQuote(
            base_currency=self.quote_currency,
            quote_currency=self.base_currency,
            rate_micros=round(MICRO_SCALE * MICRO_SCALE / self.rate_micros),
            source=self.source,
            observed_at=self.observed_at,
        )


class NoUsableRate(LookupError):
    """ไม่มีอัตราที่ยังสดพอ — ผู้เรียกควรแปลงเป็น ``currency_pair_unavailable`` (retryable)"""


def pick_rate(
    candidates: Iterable[RateQuote],
    *,
    base_currency: str,
    quote_currency: str,
    now: dt.datetime,
    staleness_limit_minutes: int,
    pivot_currency: str = "EUR",
) -> RateQuote:
    """เลือกอัตราที่ดีที่สุดสำหรับคู่หนึ่ง ตามลำดับความชอบสามชั้น

    1. อัตราตรงทิศ ที่ใหม่ที่สุดและยังไม่เกิน ``staleness_limit_minutes``
    2. อัตราทิศกลับของคู่เดียวกัน กลับด้านให้
    3. สามเส้าผ่าน ``pivot_currency`` — ต้องมีทั้งสองขาและใช้ ``observed_at`` ของขาที่เก่ากว่า
       เป็นอายุของผลลัพธ์ เพราะความสดของคู่ที่ได้จะดีกว่าขาที่แย่ที่สุดไม่ได้

    Args:
        candidates: แถวจาก ``pricing.fx_rates`` ที่ผู้เรียกดึงมาแล้ว (ไม่จำกัดลำดับ)
        base_currency: สกุลของ rate card
        quote_currency: สกุลที่ลูกค้าจะถูกเรียกเก็บ
        now: เวลาอ้างอิง ส่งเข้ามาเพื่อให้เทสต์กำหนดเองได้
        staleness_limit_minutes: ``OF_PRICING_FX_STALENESS_LIMIT_MINUTES``
        pivot_currency: สกุลกลางที่ใช้ทำสามเส้า

    Raises:
        NoUsableRate: เมื่อทั้งสามชั้นล้มเหลว
    """

    if base_currency == quote_currency:
        return RateQuote(base_currency, quote_currency, MICRO_SCALE, "identity", now)

    limit = staleness_limit_minutes * 60
    fresh = [c for c in candidates if c.age_seconds(now) <= limit]

    direct = [c for c in fresh if c.base_currency == base_currency and c.quote_currency == quote_currency]
    if direct:
        return max(direct, key=lambda c: c.observed_at)

    reverse = [c for c in fresh if c.base_currency == quote_currency and c.quote_currency == base_currency]
    if reverse:
        return max(reverse, key=lambda c: c.observed_at).inverted()

    if pivot_currency not in (base_currency, quote_currency):
        left = _leg(fresh, base_currency, pivot_currency)
        right = _leg(fresh, pivot_currency, quote_currency)
        if left and right:
            combined = round(left.rate_micros * right.rate_micros / MICRO_SCALE)
            return RateQuote(
                base_currency=base_currency,
                quote_currency=quote_currency,
                rate_micros=combined,
                source=f"{left.source}+{right.source}",
                observed_at=min(left.observed_at, right.observed_at),
            )

    raise NoUsableRate(f"no rate for {base_currency}->{quote_currency} within {limit}s")


def _leg(candidates: Sequence[RateQuote], base: str, quote: str) -> RateQuote | None:
    """หาขาหนึ่งของสามเส้า ยอมรับทั้งทิศตรงและทิศกลับ"""

    forward = [c for c in candidates if c.base_currency == base and c.quote_currency == quote]
    if forward:
        return max(forward, key=lambda c: c.observed_at)
    backward = [c for c in candidates if c.base_currency == quote and c.quote_currency == base]
    if backward:
        return max(backward, key=lambda c: c.observed_at).inverted()
    return None


def convert_all(amounts: Sequence[Money], to_currency: str, rate: RateQuote) -> list[Money]:
    """แปลงหลายก้อนด้วยอัตราเดียวกัน

    แปลงทีละบรรทัดโดยตั้งใจ ไม่ใช่แปลงยอดรวมแล้วค่อยกระจาย เพราะบรรทัดใน
    ``billing.invoice_lines`` ต้องมี ``amount_minor`` ของตัวเองที่ถูกต้องในสกุลปลายทาง
    ผู้เรียกมีหน้าที่เทียบผลรวมกับ ``convert`` ของยอดรวมแล้วปรับเศษที่บรรทัดสุดท้าย
    """

    return [convert(amount, to_currency, rate.rate_micros) for amount in amounts]


def reconcile_rounding(lines: list[Money], expected_total: Money) -> list[Money]:
    """ดันเศษที่หายไปจากการปัดรายบรรทัดเข้าไปที่บรรทัดที่มียอดมากที่สุด

    ส่วนต่างที่เป็นไปได้คือไม่กี่หน่วยย่อยเท่านั้น การเลือกบรรทัดใหญ่ที่สุดทำให้ผลกระทบ
    เชิงสัดส่วนน้อยที่สุด และทำให้ผลลัพธ์ deterministic เวลาเทียบกับใบแจ้งหนี้
    """

    if not lines:
        return lines
    difference = expected_total.minor - sum(line.minor for line in lines)
    if difference == 0:
        return lines
    target = max(range(len(lines)), key=lambda i: lines[i].minor)
    adjusted = list(lines)
    adjusted[target] = Money(adjusted[target].minor + difference, adjusted[target].currency)
    return adjusted
