"""ตารางที่เก็บ "สภาพตลาด" ซึ่งเป็น input ของราคาแต่ไม่ใช่ราคาตั้ง:
``pricing.fx_rates``, ``pricing.fuel_index_points``, ``pricing.demand_observations``
และ ``pricing.repricing_runs``

ทั้งสี่ตารางเป็น append-only ทั้งหมด อัตราของเมื่อวานยังต้องอยู่ครบเพื่ออธิบาย quote ของเมื่อวาน
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import CheckConstraint, Date, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from pricing_service.db.base import (
    Base,
    BasisPoints,
    Currency,
    Id,
    Ref,
    Timestamp,
    new_id,
    utcnow_default,
)


class FxRate(Base):
    """อัตราแลกเปลี่ยนหนึ่งจุดเวลา เก็บเป็น micro-unit จำนวนเต็ม

    ``rate_micros = 1_086_400`` หมายถึง 1 ``base_currency`` = 1.086400 ``quote_currency``
    เราไม่เก็บทิศกลับ (ให้ engine กลับด้านเอง) เพื่อไม่ให้มีสองแถวที่ปัดเศษไม่ตรงกัน
    แล้วกลายเป็นกำไร/ขาดทุนปลอมตอน round-trip

    ที่มาของอัตราคือผู้ให้บริการที่ระบุใน ``OF_PRICING_FX_RATE_SOURCE`` ซึ่งตั้งใจให้เป็น
    ตัวเดียวกับ ``OF_BILLING_FX_RATE_SOURCE`` ของ billing-service — ถ้าสองค่านี้ต่างกัน
    ใบแจ้งหนี้จะไม่ตรงกับใบเสนอราคาและ reconciliation-service จะเปิด ``duty_mismatch`` รัว ๆ
    """

    __tablename__ = "fx_rates"
    __table_args__ = (
        UniqueConstraint("base_currency", "quote_currency", "source", "observed_at"),
        CheckConstraint("rate_micros > 0", name="fx_rate_is_positive"),
        CheckConstraint("base_currency <> quote_currency", name="fx_pair_is_distinct"),
        Index("fx_rates_lookup_idx", "base_currency", "quote_currency", "observed_at"),
    )

    fx_rate_id: Mapped[Id] = mapped_column(default=lambda: new_id("fxr"))
    base_currency: Mapped[Currency]
    quote_currency: Mapped[Currency]
    rate_micros: Mapped[int]
    source: Mapped[str] = mapped_column(String(48))
    observed_at: Mapped[Timestamp]
    recorded_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())


class FuelIndexPoint(Base):
    """ค่าดัชนีน้ำมันรายสัปดาห์ต่อหนึ่งภูมิภาคของ §0.6

    ค่าธรรมเนียมน้ำมัน (``fuel_surcharge``) คำนวณจากส่วนต่างระหว่างจุดล่าสุดกับ
    ``OF_PRICING_FUEL_BASELINE_INDEX_MICROS`` ไม่ใช่จากค่าดิบ ดังนั้นดัชนีที่ *เท่ากับ* baseline
    แปลว่าไม่มีค่าธรรมเนียม ไม่ใช่ค่าธรรมเนียมเต็ม
    """

    __tablename__ = "fuel_index_points"
    __table_args__ = (
        UniqueConstraint("region_code", "source", "effective_on"),
        CheckConstraint("index_micros > 0", name="fuel_index_is_positive"),
    )

    point_id: Mapped[Id] = mapped_column(default=lambda: new_id("fip"))
    region_code: Mapped[str] = mapped_column(String(12))
    source: Mapped[str] = mapped_column(String(48))
    effective_on: Mapped[dt.date] = mapped_column(Date)
    index_micros: Mapped[int]
    recorded_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())


class DemandObservation(Base):
    """สถิติอุปสงค์รายวันต่อหนึ่งเลน — วัตถุดิบของโมเดลใน ``engine/demand.py``

    ตัวเลขในตารางนี้ถูกเติมโดยงาน Celery ``pricing.ingest_demand`` ที่อ่าน
    ``analytics.mv_lane_performance_daily`` ผ่าน ``GET /v1/metrics/lane-performance``
    ของ analytics-pipeline — เราไม่ query สคีมา ``analytics`` ตรง ๆ ตาม SPEC §7.2
    """

    __tablename__ = "demand_observations"
    __table_args__ = (
        UniqueConstraint("tenant_id", "origin_unlocode", "destination_unlocode", "business_date"),
        CheckConstraint("booked_count >= 0", name="demand_counts_non_negative"),
        CheckConstraint(
            "capacity_slots IS NULL OR capacity_slots > 0", name="demand_capacity_is_positive"
        ),
        Index(
            "demand_recent_idx",
            "origin_unlocode",
            "destination_unlocode",
            "business_date",
        ),
    )

    observation_id: Mapped[Id] = mapped_column(default=lambda: new_id("dmo"))
    tenant_id: Mapped[Ref]
    origin_unlocode: Mapped[str] = mapped_column(String(5))
    destination_unlocode: Mapped[str] = mapped_column(String(5))
    business_date: Mapped[dt.date] = mapped_column(Date)
    booked_count: Mapped[int] = mapped_column(Integer)
    capacity_slots: Mapped[int | None] = mapped_column(Integer)
    quoted_count: Mapped[int] = mapped_column(Integer, default=0)
    accepted_count: Mapped[int] = mapped_column(Integer, default=0)
    avg_transit_seconds: Mapped[int | None]
    recorded_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())


class RepricingRun(Base):
    """หนึ่งรอบของงานคิดราคาใหม่แบบเป็นชุด

    ใช้ตอน rate card ใหม่มีผล หรือตอน ``route.replanned`` มาเป็นพรวนหลัง disruption ใหญ่ ๆ
    ``engine_version`` ถูกเขียนลงแถวเพื่อให้เทียบได้ว่าราคาที่ต่างกันเกิดจากข้อมูลหรือจากโค้ด
    """

    __tablename__ = "repricing_runs"
    __table_args__ = (
        UniqueConstraint("tenant_id", "trigger", "started_at"),
        CheckConstraint(
            "state IN ('running','succeeded','failed','partial')", name="repricing_state_is_known"
        ),
    )

    run_id: Mapped[Id] = mapped_column(default=lambda: new_id("rpr"))
    tenant_id: Mapped[Ref]
    trigger: Mapped[str] = mapped_column(String(32))
    rate_card_id: Mapped[Ref | None]
    state: Mapped[str] = mapped_column(String(12), default="running")
    quotes_examined: Mapped[int] = mapped_column(Integer, default=0)
    quotes_superseded: Mapped[int] = mapped_column(Integer, default=0)
    total_delta_minor: Mapped[int] = mapped_column(Integer, default=0)
    delta_currency: Mapped[Currency | None]
    max_uplift_bp_seen: Mapped[BasisPoints] = mapped_column(default=0)
    engine_version: Mapped[str] = mapped_column(String(16))
    started_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())
    finished_at: Mapped[Timestamp | None]
    last_error: Mapped[str | None] = mapped_column(String(500))
