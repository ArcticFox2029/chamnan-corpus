# SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
# Copyright (c) 2024-2026 ORBITALFREIGHT Holding B.V.

"""relay ที่หยิบแถวของ pricing-service ออกจาก ``platform.outbox_messages`` ไปตีพิมพ์บน Kafka

เป็น process เดียวในเซอร์วิสที่มีสิทธิ์เรียก ``Producer.produce`` — ทุก handler และทุก task
เขียนแถวลง outbox ในทรานแซกชันเดียวกับการเปลี่ยนสถานะ แล้วจบหน้าที่ตรงนั้น (§7.3)

การเลือกแถวใช้ ``FOR UPDATE SKIP LOCKED`` เพื่อให้รันหลาย replica พร้อมกันได้โดยไม่ตีพิมพ์ซ้ำ
ส่วนลำดับต่อหนึ่ง shipment ยังคงถูกรักษาไว้ด้วย ``partition_key`` ไม่ใช่ด้วยลำดับที่เราหยิบ
"""

from __future__ import annotations

import logging
import signal
import time
from types import FrameType
from typing import Final

from confluent_kafka import KafkaException, Producer
from sqlalchemy import text

from pricing_service import SERVICE_NAME
from pricing_service.config import Settings, get_settings
from pricing_service.db.outbox import OutboxMessage, envelope, pending_count
from pricing_service.db.session import dispose_engine, session_scope
from pricing_service.metrics import OUTBOX_PENDING

log = logging.getLogger(__name__)

BATCH_SIZE: Final[int] = 200
"""หยิบทีละกี่แถวต่อรอบ — ใหญ่กว่านี้ทำให้ทรานแซกชันเปิดค้างนานจนงานคิดราคาไปสะดุด lock"""

MAX_ATTEMPTS: Final[int] = 8

CLAIM_SQL: Final[str] = """
    SELECT message_id
    FROM platform.outbox_messages
    WHERE producer = :producer
      AND published_at IS NULL
      AND attempts < :max_attempts
    ORDER BY created_at
    LIMIT :batch
    FOR UPDATE SKIP LOCKED
"""


class OutboxRelay:
    """วนอ่าน outbox แล้วตีพิมพ์ ตามจังหวะ ``OF_OUTBOX_RELAY_INTERVAL_MS``"""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._running = True
        self._producer = Producer(
            {
                "bootstrap.servers": ",".join(settings.platform.kafka_brokers),
                # idempotence เปิดไว้เพื่อกันการซ้ำที่เกิดจาก retry ในตัว librdkafka เอง
                # ส่วนการซ้ำที่เกิดจาก relay ตายหลัง produce แต่ก่อน commit ยังเป็นไปได้ —
                # ผู้บริโภคทุกรายจึงต้อง idempotent บน event_id อยู่ดี (§4.19 ข้อ 1)
                "enable.idempotence": True,
                "acks": "all",
                "linger.ms": 20,
                "compression.type": "zstd",
                "client.id": f"{SERVICE_NAME}-relay",
            }
        )

    def stop(self, signum: int, _frame: FrameType | None) -> None:
        log.info("relay received signal %d, finishing the current batch", signum)
        self._running = False

    def run(self) -> None:
        interval = self._settings.platform.outbox_relay_interval_ms / 1000
        try:
            while self._running:
                published = self.drain_once()
                if published == 0:
                    time.sleep(interval)
        finally:
            self._producer.flush(self._settings.platform.shutdown_grace_seconds)
            dispose_engine()
            log.info("relay stopped, %d message(s) still queued locally", len(self._producer))

    def drain_once(self) -> int:
        """หยิบหนึ่งชุดแล้วตีพิมพ์ คืนจำนวนแถวที่ตีพิมพ์สำเร็จ

        ``published_at`` ถูกประทับในทรานแซกชันเดียวกับที่จองแถวไว้ ดังนั้นแถวที่ตีพิมพ์แล้ว
        แต่ commit ไม่ทันจะถูกหยิบซ้ำในรอบถัดไป — ซึ่งเป็นเหตุผลที่ผู้บริโภคต้อง idempotent
        """

        published = 0
        with session_scope() as session:
            ids = [
                row[0]
                for row in session.execute(
                    text(CLAIM_SQL),
                    {
                        "producer": SERVICE_NAME,
                        "batch": BATCH_SIZE,
                        "max_attempts": MAX_ATTEMPTS,
                    },
                ).all()
            ]
            if not ids:
                OUTBOX_PENDING.set(0)
                return 0

            for message_id in ids:
                message = session.get(OutboxMessage, message_id)
                if message is None:  # pragma: no cover - แถวหายระหว่างจอง เป็นไปไม่ได้ในทางปฏิบัติ
                    continue
                try:
                    body = envelope(
                        message,
                        tenant_id=str(message.payload.get("tenant_id", "")),
                        region_code=self._settings.platform.region_code,
                        trace_id=str(message.payload.get("trace_id", "0" * 32)),
                    )
                    self._producer.produce(
                        message.topic,
                        key=message.partition_key.encode(),
                        value=body.encode(),
                        headers=[("x-of-event-name", message.event_name.encode())],
                    )
                    message.published_at = _now(session)
                    published += 1
                except (KafkaException, BufferError) as exc:
                    message.attempts += 1
                    message.last_error = repr(exc)[:500]
                    log.warning(
                        "could not publish %s (attempt %d): %s",
                        message.message_id,
                        message.attempts,
                        exc,
                    )

            self._producer.poll(0)
            OUTBOX_PENDING.set(pending_count(session))

        return published


def _now(session) -> object:  # type: ignore[no-untyped-def]
    """เวลาปัจจุบันจากนาฬิกาของฐานข้อมูล ไม่ใช่ของ pod

    pod ของ relay กระจายอยู่หลายโซนและนาฬิกาต่างกันได้หลายร้อยมิลลิวินาที การใช้เวลาฝั่ง
    ฐานข้อมูลทำให้ ``published_at - created_at`` ยังหมายถึงความหน่วงของ relay จริง ๆ
    """

    return session.execute(text("SELECT now()")).scalar_one()


def main() -> None:
    """entrypoint ของ sidecar ``pricing-outbox-relay``"""

    settings = get_settings()
    logging.basicConfig(level=settings.platform.log_level.upper())
    relay = OutboxRelay(settings)
    signal.signal(signal.SIGTERM, relay.stop)
    signal.signal(signal.SIGINT, relay.stop)
    relay.run()


if __name__ == "__main__":
    main()
