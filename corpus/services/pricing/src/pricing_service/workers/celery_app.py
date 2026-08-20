"""ตั้งค่า Celery application ตัวเดียวของเซอร์วิส พร้อมตารางเวลาของงานประจำ

งานทุกตัวถูกจัดคิวแบบมีชื่อชัดเจน ไม่ใช้ ``celery`` queue รวม เพราะงานดึงอัตราแลกเปลี่ยน
ต้องไม่ไปติดคิวหลัง repricing ที่กินเวลาเป็นนาที — ตอนอัตราค้าง ทุก quote ข้ามสกุลจะตอบ 503
"""

from __future__ import annotations

import logging

from celery import Celery
from celery.schedules import crontab
from celery.signals import worker_shutdown

from pricing_service import SERVICE_NAME
from pricing_service.config import get_settings
from pricing_service.db.session import dispose_engine

log = logging.getLogger(__name__)

_settings = get_settings()

app = Celery(SERVICE_NAME, broker=_settings.pricing.celery_broker_url)

app.conf.update(
    task_default_queue="pricing.default",
    task_acks_late=True,
    # งานทุกตัวของเราเขียนฐานข้อมูลและ idempotent อยู่แล้ว การ ack ทีหลังจึงปลอดภัยกว่า
    # และทำให้ worker ที่ถูก kill กลางงานไม่กลืนงานนั้นหายไป
    worker_prefetch_multiplier=1,
    task_reject_on_worker_lost=True,
    task_time_limit=600,
    task_soft_time_limit=540,
    timezone="UTC",
    enable_utc=True,
    result_expires=3_600,
    task_routes={
        "pricing.refresh_fx_rates": {"queue": "pricing.fx"},
        "pricing.ingest_fuel_index": {"queue": "pricing.fx"},
        "pricing.ingest_demand": {"queue": "pricing.default"},
        "pricing.reprice_shipment": {"queue": "pricing.default"},
        "pricing.reprice_rate_card": {"queue": "pricing.default"},
        "pricing.expire_quotes": {"queue": "pricing.default"},
        "pricing.prune_consumed_events": {"queue": "pricing.default"},
    },
)

app.conf.beat_schedule = {
    # ทุกชั่วโมงตรง — ผู้ให้บริการอัตราปล่อยชุดใหม่ที่นาทีที่ 5 เราเผื่อไว้สิบนาที
    "refresh-fx-hourly": {
        "task": "pricing.refresh_fx_rates",
        "schedule": crontab(minute=15),
    },
    # ดัชนีน้ำมันออกสัปดาห์ละครั้ง เช้าวันอังคาร
    "fuel-index-weekly": {
        "task": "pricing.ingest_fuel_index",
        "schedule": crontab(minute=30, hour=6, day_of_week=2),
    },
    # หลัง analytics-pipeline refresh mv_lane_performance_daily เสร็จ (03:15 UTC ตาม
    # OF_ANALYTICS_MV_REFRESH_CRON) เราหน่วงไว้สี่สิบห้านาทีเผื่อรอบที่ยาวกว่าปกติ
    "ingest-demand-daily": {
        "task": "pricing.ingest_demand",
        "schedule": crontab(minute=0, hour=4),
    },
    "expire-quotes": {
        "task": "pricing.expire_quotes",
        "schedule": crontab(minute="*/10"),
    },
    # retention ของ of.customs.v1 และ of.billing.v1 คือ 90 วัน seen-set ต้องอยู่นานกว่านั้น
    "prune-consumed-events": {
        "task": "pricing.prune_consumed_events",
        "schedule": crontab(minute=20, hour=2),
    },
}

# import เพื่อให้ task ถูกลงทะเบียน — ต้องอยู่ท้ายไฟล์ ไม่งั้นเป็น circular import
app.autodiscover_tasks(["pricing_service.workers"], related_name="tasks_fx")
app.autodiscover_tasks(["pricing_service.workers"], related_name="tasks_repricing")


@worker_shutdown.connect
def _close_pool(**_kwargs: object) -> None:
    """ปิด connection pool ตอน worker ปิด — ไม่งั้น pgbouncer ค้าง session ไว้จนหมดโควตา"""

    dispose_engine()
    log.info("pricing-service worker shut down cleanly")
