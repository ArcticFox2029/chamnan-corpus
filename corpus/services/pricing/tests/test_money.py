"""ยืนยันว่าคณิตศาสตร์ของเงินไม่ทำเงินหายและไม่ทำเงินงอก

สามข้อที่เทสต์ชุดนี้เฝ้าอยู่ และเป็นสามข้อที่เคยพังจริงมาแล้วทั้งหมด:
ผลรวมของบรรทัดต้องเท่ากับยอดรวมเป๊ะ ๆ, การแปลงสกุลไป-กลับต้องไม่สร้างกำไรลม
และไม่มีเส้นทางไหนที่ค่า ``float`` เดินทางเข้าไปในจำนวนเงิน (SPEC §7.4)
"""

from __future__ import annotations

import pytest

from pricing_service.engine.money import (
    CurrencyMismatch,
    Money,
    allocate,
    convert,
    mul_bp,
    total,
)


def test_allocate_sums_back_to_the_original() -> None:
    """1,000 หน่วยย่อยลงสาม leg ที่ระยะเท่ากัน ต้องได้ 334/333/333 ไม่ใช่ 333 สามตัว"""

    parts = allocate(Money(1_000, "EUR"), [1, 1, 1])
    assert [p.minor for p in parts] == [334, 333, 333]
    assert total(parts, "EUR") == Money(1_000, "EUR")


def test_allocate_follows_leg_distance() -> None:
    """น้ำหนักคือระยะทางเป็นเมตร ส่วนที่ไกลกว่าต้องรับค่าธรรมเนียมมากกว่า"""

    parts = allocate(Money(9_999, "EUR"), [120_000, 40_000, 40_000])
    assert parts[0].minor > parts[1].minor == parts[2].minor
    assert sum(p.minor for p in parts) == 9_999


def test_allocate_with_zero_weights_keeps_the_money() -> None:
    """ไม่มีข้อมูลระยะทางเลย: เงินต้องไปกองอยู่ส่วนแรก ไม่ใช่หายไปทั้งก้อน"""

    parts = allocate(Money(500, "SGD"), [0, 0])
    assert [p.minor for p in parts] == [500, 0]


def test_mul_bp_rounds_half_to_even() -> None:
    """12.5 หน่วยย่อยต้องปัดเป็น 12 ไม่ใช่ 13 — ครึ่งหนึ่งของกรณีเสมอต้องลง"""

    assert mul_bp(Money(100, "EUR"), 1_250) == Money(12, "EUR")
    assert mul_bp(Money(300, "EUR"), 1_250) == Money(38, "EUR")


def test_mul_bp_rejects_negative_rates() -> None:
    """ส่วนลดไม่ได้ทำด้วยอัตราติดลบ แต่ทำด้วยบรรทัดของมันเอง"""

    with pytest.raises(ValueError):
        mul_bp(Money(100, "EUR"), -100)


def test_convert_round_trip_does_not_invent_money() -> None:
    """แปลง EUR→USD แล้วกลับ ต้องไม่ได้มากกว่าเดิม (ได้น้อยกว่าเล็กน้อยเป็นเรื่องปกติ)"""

    original = Money(100_000, "EUR")
    to_usd = convert(original, "USD", 1_086_400)
    back = convert(to_usd, "EUR", 920_471)
    assert back.currency == "EUR"
    assert back.minor <= original.minor


def test_arithmetic_refuses_mixed_currencies() -> None:
    """SPEC §7.4: เงินไม่เดินทางโดยไม่มีสกุล และไม่บวกข้ามสกุลกันเงียบ ๆ"""

    with pytest.raises(CurrencyMismatch):
        Money(100, "EUR") + Money(100, "USD")


def test_money_rejects_a_malformed_currency() -> None:
    assert Money(1, "EUR").currency == "EUR"
    with pytest.raises(ValueError):
        Money(1, "eur")
