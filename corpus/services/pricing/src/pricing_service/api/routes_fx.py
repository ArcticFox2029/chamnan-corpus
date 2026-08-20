"""เส้นทาง HTTP ของอัตราแลกเปลี่ยน ``/v1/fx``

มีสามอย่าง: รับอัตราชุดใหม่จากงานที่ดึงมาจากผู้ให้บริการ, ให้ดูอัตราที่จะถูกใช้ถ้าคิดราคา
ตอนนี้ และคืนอายุของอัตราแต่ละคู่เพื่อให้คอนโซลเตือนได้ก่อนที่ quote จะเริ่มตอบ
``currency_pair_unavailable``

ตัวเลขที่นี่ไม่ใช่ "ราคา" จึงไม่ผูกกับ tenant — อัตราตลาดเป็นของกลางทั้งแพลตฟอร์ม
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select

from pricing_service.api.deps import Ctx, require_scope
from pricing_service.api.errors import CurrencyPairUnavailable
from pricing_service.api.schemas import FxRateUpsert
from pricing_service.config import get_settings
from pricing_service.db.models_market import FxRate
from pricing_service.db.session import session_scope
from pricing_service.engine.fx import NoUsableRate, RateQuote, pick_rate
from pricing_service.metrics import FX_RATE_AGE_SECONDS

router = APIRouter(prefix="/v1/fx", tags=["fx"])


@router.post(
    "/rates",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_scope("pricing:ratecard.write"))],
)
async def upsert_rates(payload: list[FxRateUpsert], ctx: Ctx) -> dict:
    """รับอัตราเป็นชุด — ปกติถูกเรียกโดยงาน Celery ``pricing.refresh_fx_rates`` ของเราเอง

    เป็น insert ล้วน ไม่มี update: อัตราของเมื่อวานต้องอยู่ครบเพื่ออธิบาย quote ของเมื่อวาน
    แถวที่ซ้ำกันทั้ง (คู่เงิน, แหล่ง, เวลา) ถูกข้ามเงียบ ๆ ด้วย unique constraint บนตาราง
    """

    inserted = 0
    with session_scope() as session:
        for item in payload:
            duplicate = session.execute(
                select(FxRate.fx_rate_id).where(
                    FxRate.base_currency == item.base_currency,
                    FxRate.quote_currency == item.quote_currency,
                    FxRate.source == item.source,
                    FxRate.observed_at == item.observed_at,
                )
            ).scalar_one_or_none()
            if duplicate:
                continue
            session.add(
                FxRate(
                    base_currency=item.base_currency,
                    quote_currency=item.quote_currency,
                    rate_micros=item.rate_micros,
                    source=item.source,
                    observed_at=item.observed_at,
                )
            )
            inserted += 1
    return {"inserted": inserted, "received": len(payload)}


@router.get("/rates")
async def read_rate(
    ctx: Ctx,
    base: str = Query(min_length=3, max_length=3),
    quote: str = Query(min_length=3, max_length=3),
) -> dict:
    """คืนอัตราที่ ``pick_rate`` จะเลือกถ้าคิดราคาตอนนี้ พร้อมบอกว่าได้มาทางไหน

    ``derivation`` เป็น ``direct`` / ``inverted`` / ``triangulated`` ซึ่งมีประโยชน์ตอน
    ลูกค้าถามว่าทำไมอัตราบนใบเสนอราคาต่างจากที่เขาเห็นบนเว็บข่าวการเงิน

    Raises:
        CurrencyPairUnavailable: ไม่มีอัตราที่ยังสดพอสำหรับคู่นี้
    """

    settings = get_settings()
    now = dt.datetime.now(dt.UTC)
    with session_scope() as session:
        rows = session.execute(
            select(FxRate)
            .where(FxRate.source == settings.pricing.fx_rate_source)
            .order_by(FxRate.observed_at.desc())
            .limit(400)
        ).scalars()
        candidates = [
            RateQuote(
                base_currency=row.base_currency,
                quote_currency=row.quote_currency,
                rate_micros=row.rate_micros,
                source=row.source,
                observed_at=row.observed_at,
            )
            for row in rows
        ]

    try:
        chosen = pick_rate(
            candidates,
            base_currency=base.upper(),
            quote_currency=quote.upper(),
            now=now,
            staleness_limit_minutes=settings.pricing.fx_staleness_limit_minutes,
        )
    except NoUsableRate as exc:
        raise CurrencyPairUnavailable(str(exc)) from exc

    FX_RATE_AGE_SECONDS.labels(base_currency=base.upper(), quote_currency=quote.upper()).set(
        chosen.age_seconds(now)
    )
    derivation = "direct" if "+" not in chosen.source else "triangulated"
    return {
        "base_currency": chosen.base_currency,
        "quote_currency": chosen.quote_currency,
        "rate_micros": chosen.rate_micros,
        "source": chosen.source,
        "observed_at": chosen.observed_at,
        "age_seconds": chosen.age_seconds(now),
        "derivation": derivation,
    }


@router.get("/staleness")
async def staleness_report(ctx: Ctx) -> dict:
    """อายุของอัตราล่าสุดของทุกคู่ที่เรามี เรียงจากเก่าสุดขึ้นก่อน

    คอนโซลใช้หน้านี้เตือนทีมพาณิชย์ล่วงหน้า เพราะอาการที่ผู้ใช้เห็นเวลาอัตราค้างคือ
    "ขอราคาแล้วได้ 503" ซึ่งไม่ได้บอกอะไรเลยว่าต้นเหตุอยู่ที่ผู้ให้บริการอัตรา
    """

    settings = get_settings()
    now = dt.datetime.now(dt.UTC)
    limit_seconds = settings.pricing.fx_staleness_limit_minutes * 60
    with session_scope() as session:
        rows = session.execute(
            select(
                FxRate.base_currency,
                FxRate.quote_currency,
                FxRate.observed_at,
            )
            .where(FxRate.source == settings.pricing.fx_rate_source)
            .order_by(FxRate.observed_at.desc())
            .limit(1_000)
        ).all()

    newest: dict[tuple[str, str], dt.datetime] = {}
    for base, quote, observed_at in rows:
        newest.setdefault((base, quote), observed_at)

    items = [
        {
            "base_currency": pair[0],
            "quote_currency": pair[1],
            "observed_at": observed_at,
            "age_seconds": int((now - observed_at).total_seconds()),
            "stale": (now - observed_at).total_seconds() > limit_seconds,
        }
        for pair, observed_at in newest.items()
    ]
    items.sort(key=lambda row: row["age_seconds"], reverse=True)
    return {"items": items, "next_cursor": None, "staleness_limit_seconds": limit_seconds}
