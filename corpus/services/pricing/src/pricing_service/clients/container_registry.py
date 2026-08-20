"""อ่าน shipment กับตู้จาก container-registry ซึ่งเป็น system of record ของทั้งสองอย่าง

เราไม่แตะสคีมา ``freight`` เองแม้แต่คิวรีเดียว ตาม SPEC §7.2 — ทุกอย่างผ่าน
``GET /v1/shipments/{shipment_id}`` (ซึ่งส่งรายการตู้มาในตัวอยู่แล้ว) และ
``GET /v1/containers/{container_id}`` เมื่อจำเป็นต้องรู้ ``iso_size_type`` หรือธง reefer
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any

import httpx

from pricing_service.config import Settings
from pricing_service.context import current_context
from pricing_service.metrics import UPSTREAM_CALL_SECONDS

log = logging.getLogger(__name__)

# สถานะที่คิดราคาไม่ได้ ค่าทั้งหมดมาจาก CHECK บน freight.shipments.status
UNRATABLE_STATUSES = frozenset({"cancelled"})


@dataclass(frozen=True, slots=True)
class ContainerView:
    container_id: str
    iso_code: str
    iso_size_type: str
    is_reefer: bool
    tare_weight_kg: int
    max_gross_kg: int
    gross_kg: int
    seal_number: str | None
    hazard_class_codes: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ShipmentView:
    """ภาพของ shipment เท่าที่การคิดราคาต้องใช้

    ``declared_value_minor`` ใช้เป็นฐานประมาณอากรเมื่อยังไม่มี declaration จริง และหายไปได้
    ในกรณีที่ผู้เรียกเป็น partner — partner-portal-api ตัดฟิลด์นี้ออกจาก payload ของมัน
    (``GET /partner/v1/shipments/{shipment_id}`` "redacted view")
    """

    shipment_id: str
    tenant_id: str
    reference: str
    status: str
    incoterm: str
    origin_facility_id: str
    destination_facility_id: str
    origin_unlocode: str | None
    destination_unlocode: str | None
    region_code: str
    currency: str
    declared_value_minor: int
    containers: tuple[ContainerView, ...]

    @property
    def is_ratable(self) -> bool:
        return self.status not in UNRATABLE_STATUSES

    @property
    def total_gross_kg(self) -> int:
        return sum(c.gross_kg for c in self.containers)

    @property
    def has_reefer(self) -> bool:
        return any(c.is_reefer for c in self.containers)

    @property
    def hazard_class_codes(self) -> tuple[str, ...]:
        """รหัสวัตถุอันตรายทั้งหมดของทุกตู้ในใบนี้ ไม่ซ้ำ เรียงแล้ว

        มาจาก ``freight.container_hazard_classes`` ซึ่งเป็น many-to-many จริง ๆ ตู้แทงก์
        หนึ่งใบมีทั้ง class หลักและ residue class พร้อมกันได้
        """

        codes: set[str] = set()
        for container in self.containers:
            codes.update(container.hazard_class_codes)
        return tuple(sorted(codes))


class ContainerRegistryClient:
    """HTTP client ไปยัง container-registry (Kotlin, พอร์ต 8083)

    เซอร์วิสนั้นมี gRPC surface ด้วย (``freight.v1.ContainerLookup/ResolveShipmentForContainer``)
    แต่ปลายทางนั้นเป็นเส้นทางร้อนของ telemetry-ingest โดยเฉพาะ การคิดราคาไม่ได้อยู่ในระดับ
    ความถี่นั้น เราจึงใช้ REST ธรรมดาเพื่อไม่ไปเบียดโควตาของมัน
    """

    def __init__(self, settings: Settings) -> None:
        base = settings.upstreams.container_registry_grpc_addr.rsplit(":", 1)[0]
        self._client = httpx.AsyncClient(
            base_url=f"http://{base}:8083",
            timeout=httpx.Timeout(settings.upstreams.request_timeout_ms / 1000),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def get_shipment(self, shipment_id: str) -> ShipmentView:
        """อ่าน shipment หนึ่งใบพร้อมตู้ที่ผูกอยู่

        Raises:
            httpx.HTTPStatusError: เมื่อ container-registry ตอบ 4xx/5xx — ชั้นบนแปลงเป็น
                ``upstream_unavailable`` หรือ 404 ตามสถานะที่ได้
        """

        started = time.perf_counter()
        response = await self._client.get(
            f"/v1/shipments/{shipment_id}", headers=current_context().outbound_headers()
        )
        outcome = "ok" if response.is_success else "error"
        UPSTREAM_CALL_SECONDS.labels("container-registry", "get_shipment", outcome).observe(
            time.perf_counter() - started
        )
        response.raise_for_status()
        return _parse_shipment(response.json())

    async def get_scan_trail(self, shipment_id: str, *, limit: int = 200) -> list[dict[str, Any]]:
        """ดึงรายการสแกน (``GET /v1/shipments/{shipment_id}/scans``) เรียงใหม่ไปเก่า

        การคิดราคาใช้แค่สองชนิด: ``gate_in`` เป็นจุดเริ่มนับ demurrage และ
        ``proof_of_delivery`` เป็นจุดปิดค่าเสียเวลา ที่เหลือถูกกรองทิ้งที่ผู้เรียก
        """

        response = await self._client.get(
            f"/v1/shipments/{shipment_id}/scans",
            params={"limit": limit},
            headers=current_context().outbound_headers(),
        )
        response.raise_for_status()
        return list(response.json().get("items", []))


def _parse_shipment(body: dict[str, Any]) -> ShipmentView:
    """แปลง JSON ของ container-registry เป็น ``ShipmentView``

    ฟิลด์ที่ไม่รู้จักถูกข้ามเงียบ ๆ ตามกติกา §4.19 ข้อ 3 — container-registry เพิ่มฟิลด์
    ภายใน schema version เดิมได้ตลอดและเราไม่ควรพังเพราะเรื่องนั้น
    """

    containers = tuple(
        ContainerView(
            container_id=item["container_id"],
            iso_code=item.get("iso_code", ""),
            iso_size_type=item.get("iso_size_type", ""),
            is_reefer=bool(item.get("is_reefer", False)),
            tare_weight_kg=int(item.get("tare_weight_kg", 0)),
            max_gross_kg=int(item.get("max_gross_kg", 0)),
            gross_kg=int(item.get("gross_kg", 0)),
            seal_number=item.get("seal_number"),
            hazard_class_codes=tuple(item.get("hazard_class_codes", ())),
        )
        for item in body.get("containers", [])
    )
    return ShipmentView(
        shipment_id=body["shipment_id"],
        tenant_id=body["tenant_id"],
        reference=body.get("reference", ""),
        status=body.get("status", "draft"),
        incoterm=body.get("incoterm", ""),
        origin_facility_id=body.get("origin_facility_id", ""),
        destination_facility_id=body.get("destination_facility_id", ""),
        origin_unlocode=(body.get("origin_facility") or {}).get("unlocode"),
        destination_unlocode=(body.get("destination_facility") or {}).get("unlocode"),
        region_code=body.get("region_code", ""),
        currency=body.get("currency", "EUR"),
        declared_value_minor=int(body.get("declared_value_minor", 0)),
        containers=containers,
    )
