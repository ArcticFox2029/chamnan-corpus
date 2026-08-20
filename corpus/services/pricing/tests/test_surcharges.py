"""เทสต์ค่าธรรมเนียม: ทุกบรรทัดที่ engine ผลิตต้องมี ``charge_code`` ที่
``billing.invoice_lines`` ยอมรับ และค่าธรรมเนียมน้ำมันต้องเป็นศูนย์ที่จุดฐาน ไม่ใช่เต็มจำนวน
"""

from __future__ import annotations

from pricing_service.db.models_rate_cards import CHARGE_CODES
from pricing_service.engine.money import Money
from pricing_service.engine.surcharges import fuel_surcharge_bp, spread_across_legs


def test_charge_codes_match_the_billing_check_constraint() -> None:
    """รายการนี้เป็นสำเนาของ CHECK บน ``billing.invoice_lines.charge_code``

    ถ้ามีใครเติมรหัสใหม่ที่นี่โดยไม่ได้แก้ฝั่ง billing-service ก่อน ใบแจ้งหนี้จะถูกปฏิเสธ
    ตอน ``POST /v1/invoices/{invoice_id}/lines`` ซึ่งไกลจากจุดที่ผิดไปสองเซอร์วิส
    """

    assert set(CHARGE_CODES) == {
        "linehaul",
        "fuel_surcharge",
        "demurrage",
        "detention",
        "reefer_power",
        "customs_clearance",
        "duty_disbursement",
        "hazmat_handling",
        "waiting_time",
    }


def test_fuel_at_baseline_costs_nothing() -> None:
    """ดัชนีเท่ากับ ``OF_PRICING_FUEL_BASELINE_INDEX_MICROS`` แปลว่าไม่มีค่าธรรมเนียม"""

    assert fuel_surcharge_bp(1_450_000, 1_450_000, 10_000) == 0


def test_fuel_above_baseline_scales_with_the_pass_through() -> None:
    """ดัชนีขึ้น 10% และส่งผ่าน 50% ต้องได้ครึ่งหนึ่งของส่วนต่าง"""

    full = fuel_surcharge_bp(1_595_000, 1_450_000, 10_000)
    half = fuel_surcharge_bp(1_595_000, 1_450_000, 5_000)
    assert full > 0
    assert half * 2 == full or abs(half * 2 - full) <= 1  # เผื่อการปัดเศษหนึ่งหน่วย


def test_fuel_below_baseline_is_floored_at_zero() -> None:
    """น้ำมันถูกกว่าฐานไม่ได้แปลว่าเราคืนเงินให้ลูกค้า — สัญญาไม่ได้เขียนไว้อย่างนั้น"""

    assert fuel_surcharge_bp(1_200_000, 1_450_000, 10_000) == 0


def test_spread_across_legs_preserves_the_total() -> None:
    """กระจายลง leg ตามระยะทางแล้วยอดรวมต้องไม่ขยับแม้แต่หน่วยย่อยเดียว"""

    parts = spread_across_legs(Money(10_001, "EUR"), [12_000, 8_000, 5_000])
    assert sum(p.minor for p in parts) == 10_001
    assert parts[0].minor >= parts[1].minor >= parts[2].minor
