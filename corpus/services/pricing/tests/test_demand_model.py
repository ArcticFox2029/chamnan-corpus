"""เทสต์โมเดลอุปสงค์ — เน้นที่ "ไม่ขึ้นราคาเมื่อไม่ควรขึ้น" มากกว่าความแม่นของตัวเลข

เหตุผล: uplift ที่คลาดไป 30 bp ไม่มีใครเดือดร้อน แต่ uplift ที่โผล่มาจากข้อมูลสองสัปดาห์แรก
ของเลนใหม่ หรือที่ขึ้นทุกวันศุกร์เพราะไม่ได้หักฤดูกาล เป็นสิ่งที่ลูกค้าจับได้และเถียงได้
"""

from __future__ import annotations

import datetime as dt

from pricing_service.engine.demand import (
    MIN_OBSERVATIONS,
    DemandPoint,
    compute_uplift,
    exponential_smooth,
    weekday_indices,
)

TODAY = dt.date(2026, 3, 14)


def _series(counts: list[int], *, capacity: int | None = None) -> list[DemandPoint]:
    """สร้างประวัติย้อนหลังหนึ่งชุด วันล่าสุดคือ ``TODAY``"""

    start = TODAY - dt.timedelta(days=len(counts) - 1)
    return [
        DemandPoint(
            business_date=start + dt.timedelta(days=offset),
            booked_count=count,
            capacity_slots=capacity,
        )
        for offset, count in enumerate(counts)
    ]


def test_thin_history_never_moves_the_price() -> None:
    """ต่ำกว่า ``MIN_OBSERVATIONS`` ต้องได้ศูนย์ พร้อมเหตุผลที่อธิบายได้"""

    signal = compute_uplift(
        _series([9] * (MIN_OBSERVATIONS - 1), capacity=10),
        alpha_bp=2_500,
        max_uplift_bp=1_800,
        window_days=56,
        today=TODAY,
    )
    assert signal.uplift_bp == 0
    assert signal.reason == "insufficient_history"


def test_full_lane_lifts_up_to_the_cap_but_never_past_it() -> None:
    """เลนที่จองเต็มทุกวันติดกันสองเดือน ต้องชนเพดาน ไม่ใช่ทะลุเพดาน"""

    signal = compute_uplift(
        _series([10] * 40, capacity=10),
        alpha_bp=2_500,
        max_uplift_bp=1_800,
        window_days=56,
        today=TODAY,
    )
    assert 0 < signal.uplift_bp <= 1_800
    assert signal.utilisation_bp >= 9_000


def test_empty_lane_does_not_discount() -> None:
    """โมเดลนี้ขึ้นราคาอย่างเดียว ไม่มีทางคืนค่าติดลบ — ส่วนลดเป็นเรื่องของสัญญา ไม่ใช่ของโมเดล"""

    signal = compute_uplift(
        _series([1] * 40, capacity=50),
        alpha_bp=2_500,
        max_uplift_bp=1_800,
        window_days=56,
        today=TODAY,
    )
    assert signal.uplift_bp == 0
    assert signal.reason == "below_noise_floor"


def test_points_outside_the_window_are_ignored() -> None:
    """จุดที่เก่ากว่า ``OF_PRICING_DEMAND_WINDOW_DAYS`` ต้องไม่ถูกนับ"""

    old = [
        DemandPoint(
            business_date=TODAY - dt.timedelta(days=200 + i),
            booked_count=10,
            capacity_slots=10,
        )
        for i in range(30)
    ]
    signal = compute_uplift(
        old, alpha_bp=2_500, max_uplift_bp=1_800, window_days=56, today=TODAY
    )
    assert signal.observations_used == 0
    assert signal.uplift_bp == 0


def test_exponential_smoothing_is_reproducible_and_integer_only() -> None:
    """ผลลัพธ์ต้องเท่ากันทุกครั้งและเป็นจำนวนเต็มเสมอ — ราคาที่คิดซ้ำต้องได้เท่าเดิม"""

    series = [1_000, 2_000, 3_000, 4_000]
    first = exponential_smooth(series, 2_500)
    second = exponential_smooth(list(series), 2_500)
    assert first == second
    assert isinstance(first, int)
    assert 1_000 <= first <= 4_000


def test_weekday_indices_cover_every_day() -> None:
    """ทุกวันในสัปดาห์ต้องมีดัชนี วันที่ไม่มีข้อมูลได้ 10000 (ไม่ปรับ)"""

    indices = weekday_indices(_series([5] * 21, capacity=10))
    assert sorted(indices) == list(range(7))
    assert all(value > 0 for value in indices.values())
