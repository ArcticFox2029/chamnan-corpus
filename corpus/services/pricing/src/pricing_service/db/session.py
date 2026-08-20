"""จัดการ SQLAlchemy engine กับ session ของ pricing-service ตัวเดียวทั้ง process

ตั้ง ``search_path`` และ ``statement_timeout`` ตอนเชื่อมต่อ ไม่ใช่ตอนเปิดทรานแซกชัน เพราะ
คิวรีที่หลุด timeout ในเซอร์วิสนี้แปลว่าเราไปค้างอยู่บนตาราง quote ที่กำลังถูก worker
เขียนพร้อมกัน และค้างเกิน ``OF_DATABASE_STATEMENT_TIMEOUT_MS`` ก็ไม่มีประโยชน์จะรอต่อ
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Iterator

from sqlalchemy import Engine, create_engine, event, text
from sqlalchemy.orm import Session, sessionmaker

from pricing_service.config import Settings, get_settings

log = logging.getLogger(__name__)

_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def engine_for_settings(settings: Settings) -> Engine:
    """สร้าง (หรือคืนตัวเดิม) engine ที่ผูกกับ ``OF_DATABASE_URL``

    pool ตั้งขนาดตาม ``OF_DATABASE_MAX_CONNS`` ซึ่งเป็นค่าต่อ pod ไม่ใช่ต่อคลัสเตอร์ —
    การคูณผิดตรงนี้คือสาเหตุที่ pgbouncer เคยเต็มตอน scale worker ขึ้นสิบเท่า
    """

    global _engine, _session_factory
    if _engine is not None:
        return _engine

    _engine = create_engine(
        settings.platform.database_url,
        pool_size=max(settings.platform.database_max_conns // 2, 2),
        max_overflow=settings.platform.database_max_conns // 2,
        pool_pre_ping=True,
        pool_recycle=1_800,
        future=True,
    )

    timeout_ms = settings.platform.database_statement_timeout_ms

    @event.listens_for(_engine, "connect")
    def _on_connect(dbapi_connection, _record) -> None:  # type: ignore[no-untyped-def]
        with dbapi_connection.cursor() as cur:
            cur.execute("SET search_path TO pricing, platform, public")
            cur.execute(f"SET statement_timeout = {timeout_ms}")
            # ปิด synchronous_commit ไม่ได้: quote ที่ตอบไปแล้วต้องอยู่บนดิสก์จริง
            # เพราะ billing-service จะมาอ่านซ้ำตอนออกใบแจ้งหนี้

    _session_factory = sessionmaker(bind=_engine, expire_on_commit=False, future=True)
    return _engine


def dispose_engine() -> None:
    """ปิด pool ตอน shutdown — เรียกจาก lifespan ของ FastAPI และจาก signal handler ของ Celery"""

    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _session_factory = None


@contextmanager
def session_scope() -> Iterator[Session]:
    """เปิดทรานแซกชันหนึ่งชุด commit ให้อัตโนมัติ และ rollback เมื่อมี exception

    ทุกจุดที่เขียน ``pricing.quotes`` ต้องเขียน ``platform.outbox_messages`` ในบล็อกเดียวกันนี้
    ตาม SPEC §7.3 — ไม่มีเส้นทางไหนที่ยิง Kafka เองแยกจากทรานแซกชัน
    """

    if _session_factory is None:
        engine_for_settings(get_settings())
    assert _session_factory is not None
    session = _session_factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def advisory_lock(session: Session, key: str) -> bool:
    """ล็อกเชิงคำแนะนำระดับทรานแซกชัน ใช้กันงาน repricing ของ shipment เดียวกันชนกัน

    คืน ``False`` ทันทีเมื่อมีคนถืออยู่ ไม่รอ — ผู้เรียกควรข้ามงานนั้นไปเลย เพราะอีกฝั่ง
    กำลังคำนวณผลชุดเดียวกันอยู่แล้ว
    """

    row = session.execute(
        text("SELECT pg_try_advisory_xact_lock(hashtextextended(:k, 0))"), {"k": key}
    ).scalar_one()
    return bool(row)
