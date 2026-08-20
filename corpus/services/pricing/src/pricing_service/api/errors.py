"""แปลงข้อผิดพลาดทุกชนิดที่หลุดออกมาจาก handler ให้กลายเป็น error envelope เดียวกัน
กับที่ทั้งแพลตฟอร์มใช้ (SPEC §0.4) พร้อมกับตัดสินค่า ``retryable`` ให้ client รู้ว่าควร
ลองใหม่หรือไม่

``code`` ทุกตัวในไฟล์นี้เป็นส่วนหนึ่งของสัญญาสาธารณะ เปลี่ยนสะกดเมื่อไหร่คือ breaking change
ต่อ billing-service และ partner-portal-api ที่แมตช์สตริงนี้ตรง ๆ
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from pricing_service.context import current_context


@dataclass(frozen=True, slots=True)
class FieldError:
    path: str
    reason: str

    def as_dict(self) -> dict[str, str]:
        return {"path": self.path, "reason": self.reason}


class PricingError(Exception):
    """ฐานของทุก error ที่เรา *ตั้งใจ* ให้ผู้เรียกเห็น

    Attributes:
        code: snake_case คงที่ตลอดอายุของ API
        http_status: สถานะที่จะตอบกลับ
        retryable: ``True`` เฉพาะกรณีที่ลองใหม่แล้วมีโอกาสสำเร็จโดยไม่ต้องแก้ payload
    """

    code = "pricing_error"
    http_status = 500
    retryable = False

    def __init__(self, message: str, fields: Iterable[FieldError] = ()) -> None:
        super().__init__(message)
        self.message = message
        self.fields = tuple(fields)


class RateCardNotFound(PricingError):
    code = "rate_card_not_found"
    http_status = 404


class LaneNotCovered(PricingError):
    """ไม่มีเลนไหนใน rate card ที่ครอบคลุมคู่ origin/destination นี้

    เป็นคนละเรื่องกับ ``RateCardNotFound``: rate card มีอยู่จริงแต่ไม่มีแถวเลนที่ตรง
    ฝั่งเรียกใช้ควรตกไปที่ rate card สำรองของ tenant แทนการเดาราคาเอง
    """

    code = "lane_not_covered"
    http_status = 422


class QuoteExpired(PricingError):
    code = "quote_expired"
    http_status = 409


class QuoteAlreadyAccepted(PricingError):
    code = "quote_already_accepted"
    http_status = 409


class CurrencyPairUnavailable(PricingError):
    """ไม่มีอัตราแลกเปลี่ยนที่ยังสดพอสำหรับคู่สกุลเงินนี้

    retryable เพราะงาน ``pricing.refresh_fx_rates`` ที่วิ่งทุกชั่วโมงอาจเติมให้ในอีกไม่กี่นาที
    """

    code = "currency_pair_unavailable"
    http_status = 503
    retryable = True


class ShipmentNotRatable(PricingError):
    """shipment อยู่ในสถานะที่คิดราคาไม่ได้ เช่น ``cancelled`` หรือยังเป็น ``draft``
    ที่ยังไม่มีตู้ผูกอยู่เลย — สถานะมาจาก ``freight.shipments.status``
    """

    code = "shipment_not_ratable"
    http_status = 409


class UpstreamUnavailable(PricingError):
    """เซอร์วิสปลายทาง (container-registry, routing-service, customs-service) ไม่ตอบ"""

    code = "upstream_unavailable"
    http_status = 503
    retryable = True

    def __init__(self, service: str, message: str) -> None:
        super().__init__(message)
        self.service = service


class TenantMismatch(PricingError):
    code = "tenant_mismatch"
    http_status = 403


class IdempotencyKeyMissing(PricingError):
    code = "idempotency_key_missing"
    http_status = 400


@dataclass(slots=True)
class _Envelope:
    code: str
    http_status: int
    message: str
    retryable: bool
    fields: tuple[FieldError, ...] = field(default=())

    def render(self) -> dict[str, Any]:
        try:
            trace_id = current_context().trace_id
        except LookupError:
            # เกิดได้เฉพาะตอนที่ตายก่อน dependency จะผูกบริบท เช่น header หายทั้งชุด
            trace_id = "0" * 32
        return {
            "error": {
                "code": self.code,
                "http_status": self.http_status,
                "message": self.message,
                "trace_id": trace_id,
                "retryable": self.retryable,
                "fields": [f.as_dict() for f in self.fields],
            }
        }


def install_handlers(app: FastAPI) -> None:
    """ผูก handler เข้ากับ app — เรียกครั้งเดียวจาก ``create_app``"""

    @app.exception_handler(PricingError)
    async def _pricing_error(_: Request, exc: PricingError) -> JSONResponse:
        envelope = _Envelope(exc.code, exc.http_status, exc.message, exc.retryable, exc.fields)
        return JSONResponse(envelope.render(), status_code=exc.http_status)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = tuple(
            FieldError(path=".".join(str(p) for p in err["loc"][1:]), reason=err["msg"])
            for err in exc.errors()
        )
        envelope = _Envelope("invalid_request", 422, "request body failed validation", False, fields)
        return JSONResponse(envelope.render(), status_code=422)

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        # ข้อความจริงไปอยู่ในล็อกเท่านั้น ไม่ส่งออกไปข้างนอกเพราะอาจมี DSN หรือ SQL ติดไปด้วย
        envelope = _Envelope("internal_error", 500, "unexpected internal error", True)
        return JSONResponse(envelope.render(), status_code=500)
