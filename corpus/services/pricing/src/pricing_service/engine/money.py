"""เลขคณิตของเงินทั้งหมดในเซอร์วิสนี้ — จำนวนเต็มหน่วยย่อยล้วน ไม่มี float แม้แต่ที่เดียว

ทำไมต้องมีโมดูลนี้แทนที่จะคูณกันตรง ๆ: การคูณด้วย basis point แล้วปัดเศษเป็นจุดที่เงินหาย
ทีละสตางค์ และเมื่อเอาไปกระจายลงหลายบรรทัด ผลรวมของบรรทัดจะไม่เท่ากับยอดรวมที่โฆษณาไว้
ฟังก์ชัน ``allocate`` ในไฟล์นี้แก้ปัญหานั้นด้วยการกระจายเศษที่เหลือแบบ largest-remainder
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_EVEN, Decimal, localcontext
from typing import Final, Iterable, Sequence

BASIS_POINT_SCALE: Final[int] = 10_000
"""1250 bp = 12.50 % ตามที่ §0.2 กำหนด"""

MICRO_SCALE: Final[int] = 1_000_000
"""ตัวหารของอัตราแลกเปลี่ยนที่เก็บใน ``pricing.fx_rates.rate_micros``"""

MILLI_SCALE: Final[int] = 1_000
"""ตัวหารของ ``pricing.quote_lines.quantity_milli``"""

# สกุลเงินที่ไม่มีหน่วยย่อย (หรือมีสามหลัก) — ใช้ตอนแปลงเป็นข้อความให้มนุษย์อ่านเท่านั้น
# ตัวเลขบนสายยังเป็นหน่วยย่อยของสกุลนั้นเสมอ
_EXPONENTS: Final[dict[str, int]] = {
    "JPY": 0,
    "KRW": 0,
    "VND": 0,
    "CLP": 0,
    "BHD": 3,
    "KWD": 3,
    "TND": 3,
    "OMR": 3,
}
_DEFAULT_EXPONENT: Final[int] = 2


class CurrencyMismatch(ValueError):
    """บวกเงินคนละสกุลเข้าด้วยกัน — เป็น bug เสมอ ไม่ใช่กรณีที่ผู้ใช้ป้อนผิด"""


@dataclass(frozen=True, slots=True, order=False)
class Money:
    """จำนวนเงินหนึ่งก้อน: จำนวนเต็มหน่วยย่อย + รหัสสกุลเงิน

    ทั้งสองส่วนเดินทางด้วยกันตลอด ตาม SPEC §7.4 ที่ห้ามเงินออกจากเซอร์วิสโดยไม่มีสกุลกำกับ
    """

    minor: int
    currency: str

    def __post_init__(self) -> None:
        if len(self.currency) != 3 or not self.currency.isupper():
            raise ValueError(f"currency must be an ISO 4217 alpha-3 code, got {self.currency!r}")

    # ---- การดำเนินการพื้นฐาน ----------------------------------------------------

    def _same(self, other: "Money") -> None:
        if self.currency != other.currency:
            raise CurrencyMismatch(f"{self.currency} vs {other.currency}")

    def __add__(self, other: "Money") -> "Money":
        self._same(other)
        return Money(self.minor + other.minor, self.currency)

    def __sub__(self, other: "Money") -> "Money":
        self._same(other)
        return Money(self.minor - other.minor, self.currency)

    def __mul__(self, factor: int) -> "Money":
        if not isinstance(factor, int):
            raise TypeError("multiply Money by an integer only; use mul_bp for rates")
        return Money(self.minor * factor, self.currency)

    def __lt__(self, other: "Money") -> bool:
        self._same(other)
        return self.minor < other.minor

    def __bool__(self) -> bool:
        return self.minor != 0

    def capped_at(self, ceiling: "Money | None") -> "Money":
        """คืนค่าที่ไม่เกินเพดาน ใช้กับ ``surcharge_rules.cap_minor``"""

        if ceiling is None:
            return self
        self._same(ceiling)
        return self if self.minor <= ceiling.minor else ceiling

    def at_least(self, floor: "Money") -> "Money":
        """คืนค่าที่ไม่ต่ำกว่าพื้น ใช้กับ ``rate_card_lanes.minimum_charge_minor``"""

        self._same(floor)
        return self if self.minor >= floor.minor else floor

    def format_human(self) -> str:
        """แปลงเป็นข้อความสำหรับล็อกและ description ของบรรทัด — ห้ามใช้ในการคำนวณต่อ"""

        exponent = _EXPONENTS.get(self.currency, _DEFAULT_EXPONENT)
        if exponent == 0:
            return f"{self.minor} {self.currency}"
        divisor = 10**exponent
        whole, remainder = divmod(abs(self.minor), divisor)
        sign = "-" if self.minor < 0 else ""
        return f"{sign}{whole}.{remainder:0{exponent}d} {self.currency}"

    @classmethod
    def zero(cls, currency: str) -> "Money":
        return cls(0, currency)


def total(amounts: Iterable[Money], currency: str) -> Money:
    """รวมเงินหลายก้อน โดยบังคับสกุลไว้ล่วงหน้าเพื่อให้ list ว่างยังคืนค่าที่ถูกต้อง"""

    running = 0
    for amount in amounts:
        if amount.currency != currency:
            raise CurrencyMismatch(f"expected {currency}, got {amount.currency}")
        running += amount.minor
    return Money(running, currency)


def mul_bp(amount: Money, basis_points: int, *, rounding: str = ROUND_HALF_EVEN) -> Money:
    """คูณจำนวนเงินด้วยอัตราที่เป็น basis point แล้วปัดเศษหนึ่งครั้งเดียวตอนท้าย

    Args:
        amount: จำนวนตั้งต้น
        basis_points: อัตรา เช่น 1250 = 12.50 %
        rounding: โหมดปัดเศษจาก ``OF_PRICING_ROUNDING_MODE``

    Returns:
        Money: ผลลัพธ์ในสกุลเดิม

    การใช้ ``Decimal`` ตรงนี้ไม่ได้เปิดช่องให้ float เข้ามา เพราะ input เป็นจำนวนเต็มทั้งคู่
    และผลลัพธ์ถูกแปลงกลับเป็นจำนวนเต็มทันที Decimal ทำหน้าที่แค่ควบคุมการปัดเศษเท่านั้น
    """

    if basis_points < 0:
        raise ValueError("basis points must not be negative")
    with localcontext() as ctx:
        ctx.prec = 34
        scaled = (Decimal(amount.minor) * Decimal(basis_points)) / Decimal(BASIS_POINT_SCALE)
        return Money(int(scaled.quantize(Decimal(1), rounding=rounding)), amount.currency)


def mul_milli(amount: Money, quantity_milli: int, *, rounding: str = ROUND_HALF_EVEN) -> Money:
    """คูณราคาต่อหน่วยด้วยจำนวนที่เก็บเป็นพันเท่า (``quantity_milli``)"""

    with localcontext() as ctx:
        ctx.prec = 34
        scaled = (Decimal(amount.minor) * Decimal(quantity_milli)) / Decimal(MILLI_SCALE)
        return Money(int(scaled.quantize(Decimal(1), rounding=rounding)), amount.currency)


def convert(amount: Money, to_currency: str, rate_micros: int, *, rounding: str = ROUND_HALF_EVEN) -> Money:
    """แปลงสกุลเงินด้วยอัตราที่เก็บเป็น micro-unit

    Args:
        amount: จำนวนในสกุลตั้งต้น
        to_currency: สกุลปลายทาง
        rate_micros: 1 ``amount.currency`` = ``rate_micros`` / 1e6 ``to_currency``

    Raises:
        ValueError: เมื่ออัตราไม่เป็นบวก ซึ่งแปลว่าตาราง ``pricing.fx_rates`` เสียหาย

    หมายเหตุเรื่องหน่วยย่อย: เราไม่ปรับ exponent ระหว่างสกุล (เช่น EUR สองหลัก → JPY ศูนย์หลัก)
    ในฟังก์ชันนี้ ตัวอัตราที่ผู้ให้บริการส่งมาคิดเป็น "หน่วยย่อยต่อหน่วยย่อย" อยู่แล้ว
    การไปปรับซ้ำคือที่มาของบั๊กคูณเกินร้อยเท่าที่เคยเจอกับใบแจ้งหนี้สาย apac-jp
    """

    if rate_micros <= 0:
        raise ValueError("rate_micros must be positive")
    if amount.currency == to_currency:
        return amount
    with localcontext() as ctx:
        ctx.prec = 34
        scaled = (Decimal(amount.minor) * Decimal(rate_micros)) / Decimal(MICRO_SCALE)
        return Money(int(scaled.quantize(Decimal(1), rounding=rounding)), to_currency)


def allocate(amount: Money, weights: Sequence[int]) -> list[Money]:
    """กระจายเงินก้อนหนึ่งลงหลายส่วนตามน้ำหนัก โดยผลรวมเท่ากับต้นทางเป๊ะ ๆ

    ใช้วิธี largest remainder: ปัดลงก่อนทุกส่วน แล้วแจกเศษที่เหลือทีละหนึ่งหน่วยย่อยให้ส่วนที่
    เศษมากที่สุดก่อน เสมอกันให้ index น้อยกว่าได้ไป — deterministic ล้วน ไม่มีการสุ่ม

    Args:
        amount: ยอดที่ต้องกระจายให้ครบ
        weights: น้ำหนักจำนวนเต็มไม่ติดลบ อย่างน้อยหนึ่งตัวต้องมากกว่าศูนย์

    Returns:
        list[Money]: ยาวเท่ากับ ``weights`` และ ``sum(result) == amount``

    ตัวอย่างที่ทำให้ฟังก์ชันนี้มีอยู่: ค่าธรรมเนียมน้ำมัน 1,000 หน่วยย่อยกระจายลงสาม leg
    ที่ระยะทางเท่ากัน ถ้าปัดทีละส่วนจะได้ 333×3 = 999 แล้วยอดรวมของ quote จะไม่ตรงกับ
    ยอดรวมของ ``billing.invoice_lines`` ซึ่ง reconciliation-service จะเปิดเป็น discrepancy
    """

    if not weights:
        return []
    if any(w < 0 for w in weights):
        raise ValueError("weights must not be negative")
    weight_sum = sum(weights)
    if weight_sum == 0:
        # ไม่มีข้อมูลจะแบ่ง: ยัดทั้งก้อนไว้ที่ส่วนแรกดีกว่าคืนศูนย์ทั้งแถวแล้วทำเงินหาย
        return [amount] + [Money.zero(amount.currency) for _ in weights[1:]]

    shares: list[int] = []
    remainders: list[tuple[int, int]] = []
    for index, weight in enumerate(weights):
        numerator = amount.minor * weight
        share, remainder = divmod(numerator, weight_sum)
        shares.append(share)
        remainders.append((remainder, -index))

    leftover = amount.minor - sum(shares)
    for _, negative_index in sorted(remainders, reverse=True)[:leftover]:
        shares[-negative_index] += 1

    return [Money(share, amount.currency) for share in shares]
