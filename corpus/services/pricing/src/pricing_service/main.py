"""ประกอบร่าง FastAPI application ของ pricing-service: ต่อ router ทุกตัวเข้าด้วยกัน,
ติดตั้ง exception handler ที่แปลงทุกความผิดพลาดให้เป็น envelope ตาม SPEC §0.4 และเปิด
endpoint สี่ตัวที่ทุกเซอร์วิสในแพลตฟอร์มต้องมี (``/healthz`` ``/readyz`` ``/metrics`` ``/version``)

ไฟล์นี้ตั้งใจให้บาง — ตรรกะราคาอยู่ใน ``engine/`` ทั้งหมด ที่นี่มีแค่การเดินสาย
"""

from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from sqlalchemy import text

from pricing_service import EXPECTED_SCHEMA_MIGRATION, SERVICE_NAME, VERSION
from pricing_service.api import errors
from pricing_service.api.routes_fx import router as fx_router
from pricing_service.api.routes_quotes import router as quotes_router
from pricing_service.api.routes_rate_cards import router as rate_cards_router
from pricing_service.api.routes_surcharges import router as surcharges_router
from pricing_service.clients.identity import IdentityClient
from pricing_service.config import get_settings
from pricing_service.db.session import dispose_engine, engine_for_settings, session_scope
from pricing_service.metrics import REGISTRY, observe_http_request

log = logging.getLogger(__name__)

BUILD_SHA = "0000000000000000000000000000000000000000"
"""ถูกเขียนทับตอน build โดย ``infra/`` — ค่าคงที่ตรงนี้คือค่าที่เห็นเวลารันในเครื่อง"""


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """เปิด/ปิดทรัพยากรที่มีอายุเท่ากับ process

    การอุ่น connection pool ตั้งแต่ตอนนี้ทำให้ ``/readyz`` ตอบความจริงตั้งแต่ probe แรก
    แทนที่จะผ่านเพราะยังไม่มีใครแตะฐานข้อมูลเลย
    """

    settings = get_settings()
    engine_for_settings(settings)
    app.state.identity = IdentityClient(settings)
    log.info(
        "pricing-service starting",
        extra={"region_code": settings.platform.region_code, "port": settings.platform.http_port},
    )
    try:
        yield
    finally:
        await app.state.identity.aclose()
        dispose_engine()


def create_app() -> FastAPI:
    """สร้าง app หนึ่งตัว — แยกเป็นฟังก์ชันเพื่อให้เทสต์สร้างใหม่ได้ทีละกรณี"""

    settings = get_settings()
    app = FastAPI(
        title="pricing-service",
        version=VERSION,
        lifespan=lifespan,
        docs_url=None if settings.platform.environment == "production" else "/docs",
    )

    app.include_router(quotes_router)
    app.include_router(rate_cards_router)
    app.include_router(surcharges_router)
    app.include_router(fx_router)

    errors.install_handlers(app)

    @app.middleware("http")
    async def _record_latency(request: Request, call_next) -> Response:  # type: ignore[no-untyped-def]
        started = time.perf_counter()
        response = await call_next(request)
        # ใช้ route template ไม่ใช่ path จริง มิฉะนั้น quote_id ทุกใบจะกลายเป็น label ใหม่
        # และทำให้ cardinality ของ Prometheus ระเบิด
        route = request.scope.get("route")
        template = getattr(route, "path", "unmatched")
        observe_http_request(
            request.method, template, response.status_code, time.perf_counter() - started
        )
        return response

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> JSONResponse:
        """liveness — ห้ามแตะฐานข้อมูลตามข้อกำหนด §3.15"""

        return JSONResponse({"status": "ok", "service": SERVICE_NAME})

    @app.get("/readyz", include_in_schema=False)
    async def readyz() -> JSONResponse:
        """readiness — ฐานข้อมูล, Kafka และ identity-service ต้องถึงได้ทั้งสามอย่าง"""

        checks: dict[str, str] = {}
        try:
            with session_scope() as session:
                session.execute(text("SELECT 1"))
            checks["database"] = "ok"
        except Exception as exc:  # noqa: BLE001 - readiness ต้องรายงาน ไม่ใช่ล้ม
            checks["database"] = f"unavailable: {exc.__class__.__name__}"

        checks["identity"] = "ok" if await app.state.identity.ping() else "unavailable"
        checks["kafka"] = "ok" if settings.platform.kafka_brokers else "unconfigured"

        ready = all(value == "ok" for value in checks.values())
        return JSONResponse({"ready": ready, "checks": checks}, status_code=200 if ready else 503)

    @app.get("/metrics", include_in_schema=False)
    async def metrics() -> Response:
        registry: CollectorRegistry = REGISTRY
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/version", include_in_schema=False)
    async def version() -> JSONResponse:
        return JSONResponse(
            {
                "service": SERVICE_NAME,
                "version": VERSION,
                "build_sha": BUILD_SHA,
                "schema_migration": EXPECTED_SCHEMA_MIGRATION,
                "region_code": settings.platform.region_code,
            }
        )

    @app.get("/", include_in_schema=False)
    async def root() -> PlainTextResponse:
        return PlainTextResponse("pricing-service\n")

    return app


app = create_app()
