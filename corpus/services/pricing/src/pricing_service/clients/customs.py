"""ถามอัตราอากรจาก customs-service เพื่อ *ประมาณ* ภาระภาษีลงในใบเสนอราคา

ใช้ ``GET /v1/tariffs/lookup?hs_code=&destination_country=&origin_country=&on_date=``
ซึ่งเป็นปลายทางเดียวกับที่ billing-service เรียกก่อนออกใบแจ้งหนี้ — เจตนาให้ทั้งสองฝั่งเห็น
แถว ``customs.tariff_schedules`` แถวเดียวกัน

ผลลัพธ์ที่ได้ที่นี่ไม่ผูกพัน ตัวเลขที่ผูกพันมาทีหลังใน event ``customs.declaration.cleared``
ห้ามเอาค่าจากที่นี่ไปเขียนลง ``billing.invoices.duty_minor`` ตรง ๆ
"""

from __future__ import annotations

import datetime as dt
import time
from dataclasses import dataclass

import httpx

from pricing_service.config import Settings
from pricing_service.context import current_context
from pricing_service.metrics import UPSTREAM_CALL_SECONDS


@dataclass(frozen=True, slots=True)
class TariffView:
    """หนึ่งแถวของ ``customs.tariff_schedules`` ที่ถูก resolve ตามวันที่แล้ว

    ``tariff_id`` ถูกเก็บต่อไปใน ``pricing.quotes.rating_inputs`` เพื่อให้พิสูจน์ได้ว่าราคา
    ที่เสนอไปอ้างอิงอัตราแถวไหน — ตารางนั้นเป็น temporal table ที่ไม่มีการแก้ทับ
    """

    tariff_id: str
    hs_code: str
    destination_country: str
    origin_country: str | None
    duty_rate_bp: int
    vat_rate_bp: int
    preferential_scheme: str | None


class CustomsClient:
    """HTTP client ไปยัง customs-service (.NET, พอร์ต 8087)

    แคชผลไว้ในหน่วยความจำได้นาน เพราะแถวใน ``customs.tariff_schedules`` เป็น immutable
    — เหตุผลเดียวกับที่ ``OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS`` ตั้งค่าไว้ยาวได้อย่างปลอดภัย
    """

    def __init__(self, settings: Settings, *, cache_ttl_seconds: int = 3_600) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.upstreams.customs_base_url,
            timeout=httpx.Timeout(settings.upstreams.request_timeout_ms / 1000),
        )
        self._cache: dict[tuple[str, str, str | None, str], tuple[float, TariffView | None]] = {}
        self._ttl = cache_ttl_seconds

    async def aclose(self) -> None:
        await self._client.aclose()

    async def lookup_tariff(
        self,
        *,
        hs_code: str,
        destination_country: str,
        origin_country: str | None,
        on_date: dt.date,
    ) -> TariffView | None:
        """resolve อัตราหนึ่งแถวสำหรับพิกัดศุลกากรหนึ่งรหัส ณ วันที่หนึ่ง

        Args:
            hs_code: พิกัดสิบหลักตาม ``customs.declaration_line_items.hs_code``
            destination_country: ISO 3166-1 alpha-2 ตัวใหญ่
            origin_country: ``None`` แปลว่า "ทุกแหล่งกำเนิด" ซึ่งตรงกับแถวที่คอลัมน์นั้นเป็น NULL
            on_date: วันที่ที่ต้องการให้อัตรามีผล ปกติคือวันที่ยื่น ไม่ใช่วันนี้

        Returns:
            TariffView | None: ``None`` เมื่อไม่มีอัตราที่ครอบคลุม ซึ่งเกิดได้จริงกับสินค้า
            ที่เพิ่งถูกจัดพิกัดใหม่ ผู้เรียกควรคิดราคาต่อโดยตั้งอากรเป็นศูนย์ พร้อมทำเครื่องหมาย
            ไว้ใน ``rating_inputs`` ว่าอากรยังไม่ถูกประเมิน
        """

        key = (hs_code, destination_country, origin_country, on_date.isoformat())
        cached = self._cache.get(key)
        now = time.monotonic()
        if cached and now - cached[0] < self._ttl:
            return cached[1]

        params = {
            "hs_code": hs_code,
            "destination_country": destination_country,
            "on_date": on_date.isoformat(),
        }
        if origin_country:
            params["origin_country"] = origin_country

        started = time.perf_counter()
        response = await self._client.get(
            "/v1/tariffs/lookup", params=params, headers=current_context().outbound_headers()
        )
        outcome = "ok" if response.is_success else "error"
        UPSTREAM_CALL_SECONDS.labels("customs-service", "lookup_tariff", outcome).observe(
            time.perf_counter() - started
        )

        if response.status_code == 404:
            self._cache[key] = (now, None)
            return None
        response.raise_for_status()
        body = response.json()
        view = TariffView(
            tariff_id=body["tariff_id"],
            hs_code=body["hs_code"],
            destination_country=body["destination_country"],
            origin_country=body.get("origin_country"),
            duty_rate_bp=int(body["duty_rate_bp"]),
            vat_rate_bp=int(body["vat_rate_bp"]),
            preferential_scheme=body.get("preferential_scheme"),
        )
        self._cache[key] = (now, view)
        return view

    async def declarations_for_shipment(self, shipment_id: str) -> list[dict]:
        """``GET /v1/shipments/{shipment_id}/declarations`` — ใช้ตัดสินค่าเดินพิธีการ

        จำนวน declaration คูณกับกฎ ``customs_clearance`` ที่ basis เป็น ``flat`` ทำให้
        shipment ที่ข้ามสองพรมแดนถูกคิดค่าเดินพิธีการสองครั้ง ซึ่งตรงกับที่เกิดขึ้นจริง
        """

        response = await self._client.get(
            f"/v1/shipments/{shipment_id}/declarations",
            headers=current_context().outbound_headers(),
        )
        response.raise_for_status()
        return list(response.json().get("items", []))
