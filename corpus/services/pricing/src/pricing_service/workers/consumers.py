"""process ที่กิน Kafka ห้าหัวข้อของ §4 แล้วส่งต่อให้ ``handlers.dispatch`` ทีละใบ

รันแยกจาก FastAPI และแยกจาก Celery worker: ``python -m pricing_service.workers.consumers``
เหตุผลที่แยกคือรอบการ deploy — การรีสตาร์ต API ไม่ควรทำให้ consumer group rebalance และ
การ rebalance ไม่ควรทำให้คำขอราคาที่ค้างอยู่หลุด

ไฟล์นี้ดูแล "การขนส่ง" อย่างเดียว: offset, การลองใหม่, DLQ และถิ่นที่อยู่ของข้อมูล
ส่วนความหมายทางธุรกิจอยู่ใน ``handlers.py`` ทั้งหมด
"""

from __future__ import annotations

import logging
import signal
import time
from types import FrameType
from typing import Final

from confluent_kafka import Consumer, KafkaError, KafkaException, Message, Producer

from pricing_service import SERVICE_NAME
from pricing_service.config import Settings, get_settings
from pricing_service.context import scoped
from pricing_service.db.session import dispose_engine, session_scope
from pricing_service.metrics import EVENTS_CONSUMED
from pricing_service.workers import envelope as envelope_module
from pricing_service.workers.envelope import MalformedEnvelope
from pricing_service.workers.handlers import dispatch

log = logging.getLogger(__name__)

MAX_ATTEMPTS: Final[int] = 8
"""ตาม §4.19 ข้อ 4 — ค่าเดียวกับ ``OF_NOTIFY_MAX_ATTEMPTS`` ของ notification-service"""

BASE_BACKOFF_SECONDS: Final[float] = 0.5
"""หน่วงตั้งต้นก่อนคูณสอง: 0.5, 1, 2, 4, … รวมทั้งหมดประมาณสองนาทีก่อนตกราง DLQ"""

POLL_TIMEOUT_SECONDS: Final[float] = 1.0


class ConsumerLoop:
    """ห่อ consumer หนึ่งตัวพร้อม producer สำหรับ DLQ

    ปิด ``enable.auto.commit`` โดยตั้งใจ: offset ต้องถูก commit หลังจากทรานแซกชันของฐานข้อมูล
    สำเร็จเท่านั้น มิฉะนั้น pod ที่ถูก kill ระหว่างประมวลผลจะทิ้ง event นั้นไปตลอดกาล
    ส่วนการส่งซ้ำเป็นเรื่องที่ ``pricing.consumed_events`` รับมืออยู่แล้ว
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._running = True
        brokers = ",".join(settings.platform.kafka_brokers)
        self._consumer = Consumer(
            {
                "bootstrap.servers": brokers,
                "group.id": settings.platform.kafka_consumer_group,
                "enable.auto.commit": False,
                "auto.offset.reset": "earliest",
                "max.poll.interval.ms": 300_000,
                "session.timeout.ms": 45_000,
                "client.id": f"{SERVICE_NAME}-{settings.platform.region_code}",
            }
        )
        self._dlq = Producer(
            {"bootstrap.servers": brokers, "enable.idempotence": True, "acks": "all"}
        )

    def stop(self, signum: int, _frame: FrameType | None) -> None:
        """หยุดวนลูปอย่างสุภาพ — เรียกจาก SIGTERM ที่ Kubernetes ส่งตอนไล่ pod

        เรามีเวลาเท่ากับ ``OF_SHUTDOWN_GRACE_SECONDS`` ก่อนโดน SIGKILL การรีบ commit offset
        ที่ทำเสร็จแล้วภายในช่วงนั้นคือสิ่งเดียวที่ต้องทำให้ทัน
        """

        log.info("received signal %d, draining", signum)
        self._running = False

    def run(self) -> None:
        """วนรับข้อความจนกว่าจะถูกสั่งหยุด"""

        topics = list(self._settings.consumed_topics)
        self._consumer.subscribe(topics)
        log.info("subscribed to %s as %s", topics, self._settings.platform.kafka_consumer_group)

        try:
            while self._running:
                message = self._consumer.poll(POLL_TIMEOUT_SECONDS)
                if message is None:
                    continue
                if message.error():
                    self._on_kafka_error(message)
                    continue
                self._handle_with_retries(message)
                self._consumer.commit(message=message, asynchronous=False)
        finally:
            self._consumer.close()
            self._dlq.flush(5)
            dispose_engine()
            log.info("consumer stopped cleanly")

    def _on_kafka_error(self, message: Message) -> None:
        error = message.error()
        if error is not None and error.code() == KafkaError._PARTITION_EOF:
            return  # ไม่ใช่ความผิดพลาด แค่ตามอ่านทันปลายพาร์ทิชันแล้ว
        raise KafkaException(error)

    def _handle_with_retries(self, message: Message) -> None:
        """ประมวลผลหนึ่งข้อความ พร้อมลองใหม่แบบถอยหลังทวีคูณ

        ซองที่ผิดรูปไม่ถูก retry เลย เพราะการลองอีกแปดครั้งไม่ทำให้ JSON ที่พังกลับมาดี —
        ส่งเข้า DLQ ทันทีแล้วไปข้อความถัดไป
        """

        raw = message.value()
        try:
            parsed = envelope_module.parse(raw)
        except MalformedEnvelope as exc:
            log.error("malformed envelope on %s: %s", message.topic(), exc)
            self._to_dlq(message, reason=str(exc), attempts=0)
            return

        if not envelope_module.is_for_region(parsed, self._settings.platform.region_code):
            EVENTS_CONSUMED.labels(event_name=parsed.event_name, disposition="other_region").inc()
            return

        for attempt in range(1, MAX_ATTEMPTS + 1):
            try:
                with scoped(parsed.context()), session_scope() as session:
                    dispatch(session, parsed)
                return
            except Exception as exc:  # noqa: BLE001 - ชั้นนี้มีหน้าที่ตัดสินว่าจะลองใหม่ไหม
                if attempt == MAX_ATTEMPTS:
                    log.exception("giving up on %s after %d attempts", parsed.event_id, attempt)
                    self._to_dlq(message, reason=repr(exc), attempts=attempt)
                    return
                delay = BASE_BACKOFF_SECONDS * (2 ** (attempt - 1))
                log.warning(
                    "attempt %d/%d for %s failed (%s), retrying in %.1fs",
                    attempt,
                    MAX_ATTEMPTS,
                    parsed.event_name,
                    exc.__class__.__name__,
                    delay,
                )
                time.sleep(delay)

    def _to_dlq(self, message: Message, *, reason: str, attempts: int) -> None:
        """ส่งข้อความที่กู้ไม่ได้ไป ``<topic>.dlq`` พร้อมเหตุผลใน header

        เก็บ payload เดิมไว้ทั้งดุ้นโดยไม่แตะ เพื่อให้ replay กลับเข้าหัวข้อจริงได้หลังแก้บั๊ก
        เหตุผลกับจำนวนครั้งอยู่ใน header ไม่ใช่ในเนื้อข้อความ ด้วยเหตุผลเดียวกัน
        """

        topic = f"{message.topic()}.dlq"
        self._dlq.produce(
            topic,
            key=message.key(),
            value=message.value(),
            headers=[
                ("x-of-dlq-reason", reason[:400].encode()),
                ("x-of-dlq-attempts", str(attempts).encode()),
                ("x-of-dlq-consumer", SERVICE_NAME.encode()),
            ],
        )
        self._dlq.poll(0)
        EVENTS_CONSUMED.labels(event_name=message.topic(), disposition="dead_lettered").inc()
        log.error("dead-lettered a message from %s to %s: %s", message.topic(), topic, reason)


def main() -> None:
    """entrypoint ของ container ``pricing-consumer`` ที่ประกาศไว้ใน ``infra/``"""

    settings = get_settings()
    logging.basicConfig(
        level=settings.platform.log_level.upper(),
        format="%(message)s" if settings.platform.log_format == "json" else None,
    )
    loop = ConsumerLoop(settings)
    signal.signal(signal.SIGTERM, loop.stop)
    signal.signal(signal.SIGINT, loop.stop)
    loop.run()


if __name__ == "__main__":
    main()
