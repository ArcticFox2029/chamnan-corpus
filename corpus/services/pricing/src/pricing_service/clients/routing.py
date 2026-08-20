"""ดึงเส้นทางปัจจุบันของ shipment จาก routing-service เพื่อเอาระยะทางมาคิดค่าระวาง

ปลายทางที่ใช้คือ ``GET /v1/shipments/{shipment_id}/route`` ซึ่งคืนเฉพาะ route ที่
``is_current`` — ตรงกับ unique index ``routes_one_current_per_shipment`` บน
``routing.routes`` เราไม่เคยขอ route เวอร์ชันเก่า เพราะราคาที่อ้างอิงเวอร์ชันที่ถูกแทนที่ไปแล้ว
คือราคาที่ผิด และ event ``route.replanned`` จะสั่งให้เราคิดใหม่อยู่ดี
"""

from __future__ import annotations

import time
from dataclasses import dataclass

import httpx

from pricing_service.config import Settings
from pricing_service.context import current_context
from pricing_service.metrics import UPSTREAM_CALL_SECONDS


@dataclass(frozen=True, slots=True)
class LegView:
    """หนึ่งแถวของ ``routing.route_legs`` เท่าที่การคิดราคาสนใจ"""

    leg_id: str
    seq_no: int
    mode: str
    from_facility_id: str
    to_facility_id: str
    distance_m: int
    crossing_id: str | None
    carrier_id: str | None


@dataclass(frozen=True, slots=True)
class RouteView:
    route_id: str
    shipment_id: str
    version: int
    strategy: str
    total_distance_m: int
    total_duration_s: int
    legs: tuple[LegView, ...]

    @property
    def primary_mode(self) -> str:
        """โหมดของ leg ที่ระยะทางไกลที่สุด

        นิยามเดียวกับที่ ``analytics.mv_lane_performance_daily`` ใช้ในคอลัมน์ ``primary_mode``
        (LATERAL join ที่ ``ORDER BY rl.distance_m DESC LIMIT 1``) จงใจให้ตรงกัน เพื่อให้
        ราคาที่เราคิดกับสถิติที่ analytics-pipeline รายงานพูดถึงเลนเดียวกันจริง ๆ
        """

        if not self.legs:
            return "road"
        return max(self.legs, key=lambda leg: leg.distance_m).mode

    @property
    def is_multimodal(self) -> bool:
        return len({leg.mode for leg in self.legs}) > 1

    @property
    def has_border_crossing(self) -> bool:
        return any(leg.crossing_id for leg in self.legs)

    @property
    def leg_distances_m(self) -> tuple[int, ...]:
        return tuple(leg.distance_m for leg in sorted(self.legs, key=lambda l: l.seq_no))


class RoutingClient:
    """HTTP client ไปยัง routing-service (Python/FastAPI, พอร์ต 8085)"""

    def __init__(self, settings: Settings) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.upstreams.routing_base_url,
            timeout=httpx.Timeout(settings.upstreams.request_timeout_ms / 1000),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def current_route(self, shipment_id: str) -> RouteView | None:
        """คืนเส้นทางปัจจุบัน หรือ ``None`` ถ้ายังไม่มีการวางแผน

        ``None`` ไม่ใช่ข้อผิดพลาด: quote ล่วงหน้าเกิดก่อนที่ routing-service จะวางแผนเสมอ
        ผู้เรียกจะถอยไปใช้ระยะทางประมาณจากคู่ท่าใน rate card แทน
        """

        started = time.perf_counter()
        response = await self._client.get(
            f"/v1/shipments/{shipment_id}/route", headers=current_context().outbound_headers()
        )
        if response.status_code == 404:
            UPSTREAM_CALL_SECONDS.labels("routing-service", "current_route", "missing").observe(
                time.perf_counter() - started
            )
            return None
        outcome = "ok" if response.is_success else "error"
        UPSTREAM_CALL_SECONDS.labels("routing-service", "current_route", outcome).observe(
            time.perf_counter() - started
        )
        response.raise_for_status()
        body = response.json()
        legs = tuple(
            LegView(
                leg_id=leg["leg_id"],
                seq_no=int(leg["seq_no"]),
                mode=leg["mode"],
                from_facility_id=leg["from_facility_id"],
                to_facility_id=leg["to_facility_id"],
                distance_m=int(leg.get("distance_m", 0)),
                crossing_id=leg.get("crossing_id"),
                carrier_id=leg.get("carrier_id"),
            )
            for leg in body.get("legs", [])
        )
        return RouteView(
            route_id=body["route_id"],
            shipment_id=body["shipment_id"],
            version=int(body.get("version", 1)),
            strategy=body.get("strategy", "cheapest"),
            total_distance_m=int(body.get("total_distance_m", 0)),
            total_duration_s=int(body.get("total_duration_s", 0)),
            legs=legs,
        )
