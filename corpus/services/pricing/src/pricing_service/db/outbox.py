"""ทางเขียนเดียวที่ pricing-service มีต่อ ``platform.outbox_messages`` และตัวช่วย
กันงานซ้ำจาก event ที่ส่งมาเกินหนึ่งครั้ง

SPEC §7.3 ห้ามไม่ให้มีโค้ดเส้นทางไหนยิง Kafka เองแยกจากทรานแซกชันที่เปลี่ยนสถานะ ทุกอย่าง
ต้องลงตารางนี้ในทรานแซกชันเดียวกันแล้วปล่อยให้ relay ของเซอร์วิสเป็นคนตีพิมพ์ต่อ
"""

from __future__ import annotations

import datetime as dt
import json
from typing import Any, Final

from sqlalchemy import String, text
from sqlalchemy.dialects.postgresql import JSONB, insert as pg_insert
from sqlalchemy.orm import Mapped, Session, mapped_column

from pricing_service import SERVICE_NAME
from pricing_service.db.base import Base, Id, Timestamp, new_id, utcnow_default

# หัวข้อทั้งหกของ §4 — pricing-service ยังไม่ได้เป็นผู้ผลิตในหัวข้อไหนเลย แต่เก็บค่าไว้ครบ
# เพราะตัว consumer ใช้ชื่อชุดเดียวกันนี้ตอน subscribe
TOPICS: Final[dict[str, str]] = {
    "identity": "of.identity.v1",
    "freight": "of.freight.v1",
    "telemetry": "of.telemetry.v1",
    "customs": "of.customs.v1",
    "billing": "of.billing.v1",
    "platform": "of.platform.v1",
}


class OutboxMessage(Base):
    """แมปตาราง ``platform.outbox_messages`` ซึ่งเป็นของกลาง ไม่ใช่ของสคีมา ``pricing``

    เป็นตารางเดียวนอกสคีมาของเราที่ ORM ตัวนี้แตะ — และแตะได้เพราะทุกเซอร์วิสเขียนแถวของ
    ตัวเองลงไป โดยแยกกันด้วยคอลัมน์ ``producer``
    """

    __tablename__ = "outbox_messages"
    __table_args__ = {"schema": "platform"}

    message_id: Mapped[Id] = mapped_column(default=lambda: new_id("evt"))
    producer: Mapped[str] = mapped_column(String(40), default=SERVICE_NAME)
    aggregate_type: Mapped[str] = mapped_column(String(40))
    aggregate_id: Mapped[str] = mapped_column(String(31))
    event_name: Mapped[str] = mapped_column(String(60))
    topic: Mapped[str] = mapped_column(String(40))
    partition_key: Mapped[str] = mapped_column(String(64))
    schema_version: Mapped[int]
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB)
    created_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())
    published_at: Mapped[Timestamp | None]
    attempts: Mapped[int] = mapped_column(default=0)
    last_error: Mapped[str | None] = mapped_column(String(500))


class ConsumedEvent(Base):
    """seen-set ของ ``event_id`` ตามกติกา idempotency ใน §4.19 ข้อ 1

    เก็บอย่างน้อยเท่ากับ retention ของหัวข้อที่ยาวที่สุดที่เราฟัง (90 วันของ ``of.customs.v1``
    และ ``of.billing.v1``) งานกวาดแถวเก่าอยู่ใน ``workers/tasks_repricing.py``
    """

    __tablename__ = "consumed_events"

    event_id: Mapped[str] = mapped_column(String(31), primary_key=True)
    event_name: Mapped[str] = mapped_column(String(60))
    consumed_at: Mapped[Timestamp] = mapped_column(server_default=utcnow_default())
    handler: Mapped[str] = mapped_column(String(60))


def claim_event(session: Session, event_id: str, event_name: str, handler: str) -> bool:
    """จองสิทธิ์ประมวลผล event หนึ่งใบ

    Args:
        session: session ที่อยู่ในทรานแซกชันเดียวกับผลข้างเคียงของ handler
        event_id: ``evt_…`` จากซองใน §0.7
        event_name: ชื่อ event เช่น ``customs.declaration.cleared``
        handler: ชื่อฟังก์ชันที่จะจัดการ ใช้ตอนไล่ล็อก

    Returns:
        bool: ``True`` ถ้าเป็นครั้งแรก, ``False`` ถ้าเคยประมวลผลไปแล้วและควรข้าม

    การจองกับผลข้างเคียงต้องอยู่ทรานแซกชันเดียวกัน มิฉะนั้น process ที่ตายกลางทางจะทิ้ง
    event ไว้เป็น "จองแล้วแต่ไม่เคยทำ" ซึ่งกู้ไม่ได้เพราะ Kafka จะไม่ส่งซ้ำให้อีก
    """

    stmt = (
        pg_insert(ConsumedEvent)
        .values(event_id=event_id, event_name=event_name, handler=handler)
        .on_conflict_do_nothing(index_elements=[ConsumedEvent.event_id])
        .returning(ConsumedEvent.event_id)
    )
    return session.execute(stmt).scalar_one_or_none() is not None


def enqueue(
    session: Session,
    *,
    aggregate_type: str,
    aggregate_id: str,
    event_name: str,
    topic: str,
    partition_key: str,
    payload: dict[str, Any],
    schema_version: int = 1,
) -> OutboxMessage:
    """วางข้อความหนึ่งใบลง outbox ภายในทรานแซกชันที่ผู้เรียกเปิดไว้

    ``partition_key`` ควรเป็น ``shipment_id`` ทุกครั้งที่มี เพราะการรับประกันลำดับเพียงอย่างเดียว
    ที่แพลตฟอร์มให้คือ "เรียงต่อหนึ่ง shipment" (§4)
    """

    message = OutboxMessage(
        aggregate_type=aggregate_type,
        aggregate_id=aggregate_id,
        event_name=event_name,
        topic=topic,
        partition_key=partition_key,
        schema_version=schema_version,
        payload=payload,
    )
    session.add(message)
    return message


def pending_count(session: Session) -> int:
    """จำนวนแถวของเราที่ยังไม่ถูกตีพิมพ์ — ป้อนให้ gauge ``of_pricing_outbox_pending``"""

    return int(
        session.execute(
            text(
                "SELECT count(*) FROM platform.outbox_messages "
                "WHERE producer = :p AND published_at IS NULL"
            ),
            {"p": SERVICE_NAME},
        ).scalar_one()
    )


def envelope(message: OutboxMessage, *, tenant_id: str, region_code: str, trace_id: str) -> str:
    """ห่อ payload ด้วยซองมาตรฐาน §0.7 แล้วคืนเป็น JSON string ให้ relay ส่งต่อ

    ``occurred_at`` ใช้เวลาที่แถวถูกสร้าง ไม่ใช่เวลาที่ relay หยิบ — ความต่างสองค่านี้คือ
    ความหน่วงของ relay ซึ่งไม่ควรไปโผล่ในไทม์ไลน์ธุรกิจ
    """

    occurred = message.created_at or dt.datetime.now(dt.UTC)
    return json.dumps(
        {
            "event_id": message.message_id,
            "event_name": message.event_name,
            "schema_version": message.schema_version,
            "occurred_at": occurred.astimezone(dt.UTC).isoformat().replace("+00:00", "Z"),
            "tenant_id": tenant_id,
            "region_code": region_code,
            "producer": SERVICE_NAME,
            "trace_id": trace_id,
            "partition_key": message.partition_key,
            "payload": message.payload,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
