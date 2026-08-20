# SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
# Copyright (c) 2024-2026 ORBITALFREIGHT Holding B.V.

"""แกะซองข้อความของ Kafka ตาม SPEC §0.7 ให้กลายเป็น object ที่ handler ใช้ต่อได้
พร้อมบังคับกติกาสองข้อที่ผิดพลาดบ่อยที่สุดตั้งแต่ก่อนถึงตัว handler:
ฟิลด์ที่ไม่รู้จักต้อง *ไม่* ทำให้ข้อความตกราง (§4.19 ข้อ 3) และข้อความของภูมิภาคอื่น
ต้องไม่ถูกประมวลผลหรือแม้แต่ถูกล็อกไว้ในภูมิภาคนี้ (§7.7)

โมดูลนี้ตั้งใจแยกจาก ``consumers.py`` เพราะ ``handlers.py`` ต้องการชนิดข้อมูลตัวนี้ด้วย
การเอาไปไว้ในไฟล์ consumer จะทำให้สองไฟล์นั้น import วนกัน
"""

from __future__ import annotations

import datetime as dt
import json
import logging
from dataclasses import dataclass
from typing import Any, Final, Mapping

from pricing_service.config import REGION_CODES
from pricing_service.context import RequestContext

log = logging.getLogger(__name__)

REQUIRED_FIELDS: Final[tuple[str, ...]] = (
    "event_id",
    "event_name",
    "schema_version",
    "occurred_at",
    "tenant_id",
    "region_code",
    "producer",
    "trace_id",
    "partition_key",
    "payload",
)

# schema_version ที่เรารู้จักต่อหนึ่ง event — ตัวเลขขยับเมื่อผู้ผลิต *ลบ* ฟิลด์หรือเปลี่ยนชนิด
# เท่านั้น การเพิ่มฟิลด์ไม่ขยับเวอร์ชัน เราจึงต้องยอมรับเวอร์ชันที่ต่ำกว่าหรือเท่ากับค่านี้
KNOWN_SCHEMA_VERSIONS: Final[dict[str, int]] = {
    "shipment.created": 2,
    "shipment.scanned": 3,
    "shipment.status.changed": 2,
    "fleet.assignment.released": 1,
    "route.replanned": 2,
    "telemetry.alert.raised": 1,
    "customs.declaration.cleared": 2,
    "billing.invoice.issued": 1,
    "billing.invoice.settled": 1,
}


class MalformedEnvelope(ValueError):
    """ซองที่ขาดฟิลด์บังคับ — ไปที่ ``<topic>.dlq`` ทันที ไม่ต้องลองใหม่

    ต่างจากความล้มเหลวชั่วคราว: ข้อความที่ขาด ``event_id`` จะขาดตลอดไป การ retry แปดครั้ง
    ตามกติกา §4.19 ข้อ 4 มีไว้สำหรับปลายทางที่ล่ม ไม่ใช่สำหรับข้อความที่ผิดรูป
    """


@dataclass(frozen=True, slots=True)
class Envelope:
    """ซองมาตรฐานหนึ่งใบ พร้อม payload ที่ยังไม่ถูกตีความ

    Attributes:
        event_id: ``evt_…`` ใช้เป็นกุญแจของ seen-set ใน ``pricing.consumed_events``
        event_name: ชื่อตาม §4 เช่น ``customs.declaration.cleared``
        schema_version: เวอร์ชันของ payload ไม่ใช่ของซอง
        occurred_at: เวลาที่เหตุการณ์เกิดจริง ไม่ใช่เวลาที่เราได้รับ
        tenant_id: ``tnt_…``
        region_code: หนึ่งใน §0.6 — ถ้าไม่ตรงกับ ``OF_REGION_CODE`` ของ pod นี้ ต้องข้าม
        producer: ชื่อเซอร์วิสผู้ผลิตตามที่ §1 สะกด
        trace_id: W3C trace-id ที่ต้องไหลต่อไปยังทุกการเรียกที่ handler ทำ
        partition_key: ปกติคือ ``shipment_id`` ซึ่งเป็นหลักประกันลำดับเดียวที่มี
        payload: เนื้อของ event ตามรายการฟิลด์ใน §4
    """

    event_id: str
    event_name: str
    schema_version: int
    occurred_at: dt.datetime
    tenant_id: str
    region_code: str
    producer: str
    trace_id: str
    partition_key: str
    payload: Mapping[str, Any]

    def context(self) -> RequestContext:
        """บริบทสำหรับ handler — actor เป็นเซอร์วิสผู้ผลิต ไม่ใช่ตัวเรา

        ``trace_id`` ถูกหยิบมาจากซองตรง ๆ ไม่สร้างใหม่ เพื่อให้สายเรียกที่ handler ยิงต่อไป
        ยัง container-registry หรือ customs-service ยังนับเป็น trace เดียวกับต้นทาง
        """

        return RequestContext(
            tenant_id=self.tenant_id,
            trace_id=self.trace_id,
            actor_kind="service",
            actor_id=f"svc:{self.producer}",
        )

    def get(self, field: str, default: Any = None) -> Any:
        """อ่านฟิลด์ใน payload แบบไม่ล้มเมื่อไม่มี — ผู้ผลิตเติมฟิลด์ได้โดยไม่แจ้ง"""

        return self.payload.get(field, default)

    def require(self, field: str) -> Any:
        """อ่านฟิลด์ที่ §4 ระบุว่าต้องมี ถ้าไม่มีถือว่าซองผิดรูป"""

        if field not in self.payload:
            raise MalformedEnvelope(
                f"{self.event_name} payload is missing required field {field!r}"
            )
        return self.payload[field]


def _parse_timestamp(raw: str) -> dt.datetime:
    """แปลง RFC 3339 ที่ลงท้ายด้วย ``Z`` ตาม §0.2

    ``fromisoformat`` ของ Python 3.12 รับ ``Z`` ได้แล้ว แต่เรายังแทนที่ให้ชัดเพื่อให้ไฟล์นี้
    ยังอ่านออกสำหรับคนที่ย้อนไปดูใน 3.10 ซึ่งเป็นเวอร์ชันที่ edge/ ยังใช้อยู่
    """

    return dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))


def parse(raw: bytes | str) -> Envelope:
    """แกะซองหนึ่งใบจากไบต์ที่ Kafka ส่งมา

    Args:
        raw: เนื้อข้อความดิบ คาดว่าเป็น JSON ที่เข้ารหัส UTF-8

    Returns:
        Envelope: ซองที่ผ่านการตรวจฟิลด์บังคับแล้ว

    Raises:
        MalformedEnvelope: เมื่อ JSON เสีย, ขาดฟิลด์บังคับ, ``region_code`` ไม่อยู่ใน §0.6
            หรือ ``schema_version`` สูงกว่าที่โค้ดชุดนี้รู้จัก
    """

    try:
        body = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MalformedEnvelope(f"payload is not valid JSON: {exc}") from exc

    missing = [name for name in REQUIRED_FIELDS if name not in body]
    if missing:
        raise MalformedEnvelope(f"envelope is missing {', '.join(missing)}")

    region = body["region_code"]
    if region not in REGION_CODES:
        raise MalformedEnvelope(f"region_code={region!r} is not one of SPEC §0.6")

    event_name = body["event_name"]
    version = int(body["schema_version"])
    known = KNOWN_SCHEMA_VERSIONS.get(event_name)
    if known is not None and version > known:
        # ผู้ผลิตขยับเวอร์ชันแปลว่าเขา *ลบ* หรือ *เปลี่ยนชนิด* ฟิลด์ไปแล้ว การเดาต่อว่า
        # payload ยังหน้าตาเดิมคือวิธีที่ราคาจะเพี้ยนแบบเงียบที่สุด — ให้ตกราง DLQ ดีกว่า
        raise MalformedEnvelope(
            f"{event_name} arrived at schema_version {version}, this build understands {known}"
        )

    return Envelope(
        event_id=body["event_id"],
        event_name=event_name,
        schema_version=version,
        occurred_at=_parse_timestamp(body["occurred_at"]),
        tenant_id=body["tenant_id"],
        region_code=region,
        producer=body["producer"],
        trace_id=body["trace_id"],
        partition_key=body["partition_key"],
        payload=body["payload"] or {},
    )


def is_for_region(envelope: Envelope, region_code: str) -> bool:
    """ข้อความใบนี้เป็นของภูมิภาคที่ pod นี้รันอยู่หรือไม่

    §7.7 บอกว่า region คือถิ่นที่อยู่ของข้อมูล ไม่ใช่การแบ่ง shard: shipment ที่ติดป้าย
    ``latam-br`` ห้ามถูกเขียน แคช หรือแม้แต่ล็อกจากภูมิภาคอื่น เราจึงตัดทิ้งตั้งแต่ตรงนี้
    โดยไม่พิมพ์ ``tenant_id`` หรือเนื้อ payload ลงล็อกเลยแม้แต่ฟิลด์เดียว
    """

    if envelope.region_code == region_code:
        return True
    log.debug("skipping envelope for another region", extra={"event_name": envelope.event_name})
    return False
