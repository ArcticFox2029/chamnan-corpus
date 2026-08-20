"""ตั้งตัวแปรแวดล้อมขั้นต่ำที่ ``config.get_settings()`` ต้องการ ก่อนที่เทสต์ตัวไหนจะ import
โมดูลที่อ่านค่าเหล่านั้นตอน import

ค่าที่ใส่ไว้เป็นค่าของสภาพแวดล้อม ``local`` ทั้งหมด — ไม่มีปลายทางจริงตัวไหนถูกเรียกในเทสต์
ชุดนี้ เพราะทุกอย่างที่แตะเครือข่ายอยู่ใน ``clients/`` และเทสต์ที่นี่ทดสอบแต่ ``engine/``
ซึ่งเป็นฟังก์ชันล้วน
"""

from __future__ import annotations

import os

import pytest

_ENV = {
    "OF_ENVIRONMENT": "ci",
    "OF_REGION_CODE": "eu-west",
    "OF_SERVICE_NAME": "pricing-service",
    "OF_HTTP_PORT": "8095",
    "OF_DATABASE_URL": "postgresql+psycopg://of:of@localhost:5432/of?options=-csearch_path%3Dpricing",
    "OF_KAFKA_BROKERS": "localhost:9092",
    "OF_KAFKA_CONSUMER_GROUP": "pricing-service-test",
    "OF_IDENTITY_GRPC_ADDR": "identity-service:9081",
    "OF_IDENTITY_JWKS_URL": "http://identity-service:8081/.well-known/jwks.json",
    "OF_CONTAINER_REGISTRY_GRPC_ADDR": "container-registry:9083",
    "OF_ROUTING_BASE_URL": "http://routing-service:8085",
    "OF_CUSTOMS_BASE_URL": "http://customs-service:8087",
    "OF_ANALYTICS_BASE_URL": "http://analytics-pipeline:8093",
    "OF_PRICING_FX_RATE_SOURCE": "ecb-daily",
    "OF_PRICING_CELERY_BROKER_URL": "redis://localhost:6379/3",
}


@pytest.fixture(scope="session", autouse=True)
def _environment() -> None:
    """ยัดค่าลง ``os.environ`` ครั้งเดียวต่อการรันทั้งชุด

    ไม่ใช้ ``monkeypatch`` เพราะ scope ของมันคือรายเทสต์ ส่วน ``get_settings`` ถูก
    ``lru_cache`` ไว้ตัวเดียวทั้ง process — การเปลี่ยนค่ากลางทางจะไม่มีผลอยู่ดี และจะทำให้
    เทสต์ที่รันทีหลังเห็นค่าที่ไม่ตรงกับที่มันตั้ง
    """

    for key, value in _ENV.items():
        os.environ.setdefault(key, value)
