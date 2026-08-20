"""อ่านสถิติเลนและสถิติการใช้ตู้จาก analytics-pipeline เพื่อป้อนโมเดลอุปสงค์

เป็นทางเดียวที่ pricing-service เห็นข้อมูลใน ``analytics.mv_lane_performance_daily`` และ
``analytics.mv_container_utilisation_weekly`` — เราไม่ต่อฐานข้อมูลไปอ่านสองวิวนั้นเอง ถึงจะ
อยู่คลัสเตอร์เดียวกันก็ตาม เพราะ role ``of_analytics_ro`` เป็นของ analytics-pipeline
รายเดียวตาม SPEC §2 และการ join ข้ามสคีมาในโค้ดแอปคือบั๊กตาม §7.2

ต่างจาก client ตัวอื่นในแพ็กเกจนี้ตรงที่เป็น **synchronous** ล้วน ๆ ผู้เรียกมีที่เดียวคือ
Celery task ``pricing.ingest_demand`` ซึ่งรันในเธรดของ worker อยู่แล้ว การลาก event loop
เข้ามาเพื่อเรียก endpoint วันละครั้งไม่คุ้มกับความซับซ้อนที่เพิ่ม
"""

from __future__ import annotations

import datetime as dt
import logging
import time
from dataclasses import dataclass
from typing import Iterator

import httpx

from pricing_service.config import Settings
from pricing_service.context import current_context
from pricing_service.metrics import UPSTREAM_CALL_SECONDS

log = logging.getLogger(__name__)

MAX_PAGE_SIZE = 200
"""เพดานของ ``?limit=`` ตาม §0.5 — ขอมากกว่านี้ analytics-pipeline ตอบ 400 ไม่ใช่ตัดให้เงียบ ๆ"""


@dataclass(frozen=True, slots=True)
class LanePerformanceRow:
    """หนึ่งแถวของ ``analytics.mv_lane_performance_daily``

    ชื่อฟิลด์สะกดตรงกับคอลัมน์ในวิวทุกตัว เพื่อให้ไล่ย้อนได้ว่าเลขที่โมเดลอุปสงค์ใช้มาจากไหน
    ``excursion_alerts`` คือจำนวน ``telemetry.telemetry_alerts`` ของเลนนั้น ซึ่งเราใช้เป็น
    ตัวแทนของ "ความยากในการวิ่งเลนนี้" ไม่ใช่ตัวแปรอุปสงค์โดยตรง
    """

    tenant_id: str
    business_date: dt.date
    origin_unlocode: str
    destination_unlocode: str
    primary_mode: str | None
    shipment_count: int
    on_time_count: int
    avg_transit_seconds: int | None
    p95_transit_seconds: int | None
    excursion_alerts: int

    @property
    def on_time_bp(self) -> int:
        """สัดส่วนตรงเวลาเป็น basis point — ``0`` เมื่อไม่มี shipment ในวันนั้น"""

        if self.shipment_count <= 0:
            return 0
        return round(self.on_time_count * 10_000 / self.shipment_count)


@dataclass(frozen=True, slots=True)
class ContainerUtilisationRow:
    """หนึ่งแถวของ ``analytics.mv_container_utilisation_weekly``

    ``fill_rate_pct`` มาถึงเราเป็นสตริงทศนิยม แล้วถูกแปลงเป็น basis point ทันทีตรงจุดแปลง —
    ไม่มี float ตัวไหนเดินทางเข้าไปในแพ็กเกจ ``engine/`` ได้ (SPEC §7.4)
    """

    container_id: str
    iso_size_type: str
    week_start: dt.date
    trips: int
    total_gross_kg: int
    max_gross_kg: int
    fill_rate_bp: int


class AnalyticsClient:
    """HTTP client ไปยัง analytics-pipeline (Scala/Spark, พอร์ต 8093)

    timeout ตั้งยาวกว่า client ตัวอื่นโดยตั้งใจ: ปลายทางเสิร์ฟจาก materialised view ที่ถูก
    ``REFRESH ... CONCURRENTLY`` ตอน 03:15 UTC ตาม ``OF_ANALYTICS_MV_REFRESH_CRON`` และคำขอ
    ที่ตกลงไปกลางรอบ refresh ใช้เวลาหลายวินาทีเป็นเรื่องปกติ ไม่ใช่สัญญาณว่าปลายทางล้ม
    """

    def __init__(self, settings: Settings, *, timeout_seconds: float = 30.0) -> None:
        self._client = httpx.Client(
            base_url=settings.upstreams.analytics_base_url,
            timeout=httpx.Timeout(timeout_seconds),
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "AnalyticsClient":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def _get(self, path: str, params: dict[str, str | int], operation: str) -> dict:
        started = time.perf_counter()
        response = self._client.get(
            path, params=params, headers=current_context().outbound_headers()
        )
        outcome = "ok" if response.is_success else "error"
        UPSTREAM_CALL_SECONDS.labels("analytics-pipeline", operation, outcome).observe(
            time.perf_counter() - started
        )
        response.raise_for_status()
        return dict(response.json())

    def lane_performance(
        self, *, business_date: dt.date, limit: int = MAX_PAGE_SIZE
    ) -> Iterator[LanePerformanceRow]:
        """ไล่อ่าน ``GET /v1/metrics/lane-performance`` ทีละหน้าจนหมด

        Args:
            business_date: วันที่ทางธุรกิจของแถวที่ต้องการ ปกติคือเมื่อวาน
            limit: ขนาดหน้า สูงสุด ``MAX_PAGE_SIZE``

        Yields:
            LanePerformanceRow: ทีละแถวตามลำดับที่ปลายทางส่งมา

        การไล่หน้าใช้ ``next_cursor`` ตาม §0.5 เท่านั้น ไม่มี offset ให้ใช้ทั้งแพลตฟอร์ม —
        และ cursor เป็นค่าทึบ ห้ามพยายามถอดความหมายหรือประกอบขึ้นเอง
        """

        cursor: str | None = None
        page = 0
        while True:
            params: dict[str, str | int] = {
                "business_date": business_date.isoformat(),
                "limit": min(limit, MAX_PAGE_SIZE),
            }
            if cursor:
                params["cursor"] = cursor
            body = self._get("/v1/metrics/lane-performance", params, "lane_performance")
            for row in body.get("items", []):
                yield LanePerformanceRow(
                    tenant_id=row["tenant_id"],
                    business_date=dt.date.fromisoformat(row["business_date"]),
                    origin_unlocode=row["origin_unlocode"],
                    destination_unlocode=row["destination_unlocode"],
                    primary_mode=row.get("primary_mode"),
                    shipment_count=int(row.get("shipment_count", 0)),
                    on_time_count=int(row.get("on_time_count", 0)),
                    avg_transit_seconds=row.get("avg_transit_seconds"),
                    p95_transit_seconds=row.get("p95_transit_seconds"),
                    excursion_alerts=int(row.get("excursion_alerts", 0)),
                )
            cursor = body.get("next_cursor")
            page += 1
            if not cursor:
                return
            if page > 500:
                # กันลูปไม่รู้จบเวลาปลายทางส่ง cursor เดิมกลับมา ซึ่งเคยเกิดครั้งหนึ่งตอน
                # วิวถูก refresh กลางการไล่หน้าแล้วหน้าสุดท้ายว่างแต่ cursor ไม่เป็น null
                log.warning("lane-performance paging exceeded 500 pages, stopping early")
                return

    def container_utilisation(
        self, *, week_start: dt.date, iso_size_type: str | None = None
    ) -> list[ContainerUtilisationRow]:
        """อ่าน ``GET /v1/metrics/container-utilisation`` สำหรับสัปดาห์หนึ่ง

        ใช้เป็นตัวถ่วงของตัวคูณตามชนิดตู้: ถ้าตู้ชนิดหนึ่งวิ่งเต็มแทบทุกเที่ยวในภูมิภาคนั้น
        ตัวคูณอุปกรณ์ควรขยับขึ้น ไม่ใช่ปล่อยให้เป็นค่าคงที่ในตาราง ``pricing.rate_card_lanes``
        ตลอดไป ตัวเลขที่ได้ถูกเก็บลง ``pricing.demand_observations.capacity_slots``
        """

        params: dict[str, str | int] = {"week_start": week_start.isoformat(), "limit": MAX_PAGE_SIZE}
        if iso_size_type:
            params["iso_size_type"] = iso_size_type
        body = self._get("/v1/metrics/container-utilisation", params, "container_utilisation")
        rows: list[ContainerUtilisationRow] = []
        for row in body.get("items", []):
            # ปลายทางส่ง fill_rate_pct มาเป็นสตริงทศนิยมสองตำแหน่ง ("83.25") แปลงเป็น bp
            # ด้วยจำนวนเต็มล้วน แทนที่จะผ่าน float แล้วปัดทีหลัง
            whole, _, frac = str(row.get("fill_rate_pct", "0")).partition(".")
            fill_bp = int(whole) * 100 + int((frac + "00")[:2])
            rows.append(
                ContainerUtilisationRow(
                    container_id=row["container_id"],
                    iso_size_type=row["iso_size_type"],
                    week_start=dt.date.fromisoformat(row["week_start"]),
                    trips=int(row.get("trips", 0)),
                    total_gross_kg=int(row.get("total_gross_kg", 0)),
                    max_gross_kg=int(row.get("max_gross_kg", 0)),
                    fill_rate_bp=fill_bp,
                )
            )
        return rows
