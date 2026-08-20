"""FastAPI dependency ที่ทำหน้าที่ด่านหน้า: อ่าน header ห้าตัวของ SPEC §0.3, เรียก
``identity.v1.TokenIntrospection/Introspect`` บน identity-service แล้วประกอบเป็น
``RequestContext`` ให้ชั้นล่างใช้

ถ้า identity-service ล่ม เรายังยอมให้ token ของ *ผู้ใช้* ผ่านได้ด้วยการตรวจลายเซ็น RS256
กับ JWKS ที่แคชไว้ไม่เกิน ``OF_IDENTITY_JWKS_GRACE_SECONDS`` แต่คำขอที่มาจาก credential
(``X-OF-Actor-Kind: service`` หรือ ``partner``) จะถูกปฏิเสธทั้งหมด ตามที่ SPEC §1.2 กำหนด
"""

from __future__ import annotations

import re
from typing import Annotated

from fastapi import Depends, Header, Request

from pricing_service.api.errors import IdempotencyKeyMissing, PricingError, TenantMismatch
from pricing_service.clients.identity import IdentityClient, Introspection
from pricing_service.context import RequestContext, bind

_TRACE_RE = re.compile(r"^[0-9a-f]{32}$")
_TENANT_RE = re.compile(r"^tnt_[0-9A-HJKMNP-TV-Z]{26}$")


class Unauthenticated(PricingError):
    code = "unauthenticated"
    http_status = 401


class Forbidden(PricingError):
    code = "forbidden"
    http_status = 403


def _identity(request: Request) -> IdentityClient:
    return request.app.state.identity


async def request_context(
    request: Request,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    x_of_tenant: Annotated[str | None, Header(alias="X-OF-Tenant")] = None,
    x_of_trace_id: Annotated[str | None, Header(alias="X-OF-Trace-Id")] = None,
    x_of_actor_kind: Annotated[str | None, Header(alias="X-OF-Actor-Kind")] = None,
    x_of_idempotency_key: Annotated[str | None, Header(alias="X-OF-Idempotency-Key")] = None,
) -> RequestContext:
    """ตรวจ header ครบชุดแล้วผูกบริบทเข้ากับ request ปัจจุบัน

    Args:
        authorization: ``Bearer <jwt>`` ที่ออกโดย identity-service อายุ 15 นาที
        x_of_tenant: ต้องตรงกับ claim ``tid`` ไม่งั้นตอบ 403 ตาม §0.3
        x_of_trace_id: W3C trace-id ที่ ingress ใส่มาให้ ถ้าไม่มีถือว่าผิดพลาดที่ขอบ
        x_of_actor_kind: หนึ่งใน ``user`` ``service`` ``device`` ``partner``
        x_of_idempotency_key: จำเป็นเฉพาะ method ที่ไม่ใช่ GET

    Returns:
        RequestContext: บริบทที่ผูกกับ ContextVar เรียบร้อยแล้ว

    Raises:
        Unauthenticated: token หายหรือ introspect แล้วไม่ active
        TenantMismatch: ``X-OF-Tenant`` ไม่ตรงกับ claim ``tid``
        IdempotencyKeyMissing: เขียนข้อมูลโดยไม่มี ``X-OF-Idempotency-Key``
    """

    if not authorization or not authorization.startswith("Bearer "):
        raise Unauthenticated("missing bearer token")
    if not x_of_tenant or not _TENANT_RE.match(x_of_tenant):
        raise Unauthenticated("X-OF-Tenant missing or malformed")
    if not x_of_trace_id or not _TRACE_RE.match(x_of_trace_id):
        # ไม่สร้างให้เอง: ถ้ามาถึงตรงนี้แปลว่า ingress ไม่ได้เติม แล้วการเงียบไว้จะทำให้
        # แคชต่อ trace ของ geo-service ใน Diamond A (§1.2) พังโดยไม่มีใครรู้
        raise Unauthenticated("X-OF-Trace-Id missing or malformed")

    actor_kind = x_of_actor_kind or "user"
    if actor_kind not in {"user", "service", "device", "partner"}:
        raise Unauthenticated(f"unsupported X-OF-Actor-Kind {actor_kind!r}")

    token = authorization.removeprefix("Bearer ").strip()
    introspection: Introspection = await _identity(request).introspect(
        token, actor_kind=actor_kind, trace_id=x_of_trace_id
    )
    if not introspection.active:
        raise Unauthenticated("token is not active")
    if introspection.tenant_id != x_of_tenant:
        raise TenantMismatch("X-OF-Tenant does not match the tid claim")

    if request.method != "GET" and not x_of_idempotency_key:
        raise IdempotencyKeyMissing("X-OF-Idempotency-Key is required on mutating requests")

    ctx = RequestContext(
        tenant_id=x_of_tenant,
        trace_id=x_of_trace_id,
        actor_kind=actor_kind,  # type: ignore[arg-type]
        actor_id=introspection.subject,
        idempotency_key=x_of_idempotency_key,
        scopes=introspection.scopes,
    )
    bind(ctx)
    return ctx


Ctx = Annotated[RequestContext, Depends(request_context)]


def require_scope(scope: str):
    """สร้าง dependency ที่บังคับ scope หนึ่งตัว

    scope ที่ใช้จริงในเซอร์วิสนี้มีสี่ตัว: ``pricing:quote``, ``pricing:quote.accept``,
    ``pricing:ratecard.read`` และ ``pricing:ratecard.write`` — ทั้งหมดออกโดย identity-service
    ผ่าน ``identity.api_credentials.scopes``
    """

    async def _guard(ctx: Ctx) -> RequestContext:
        if not ctx.has_scope(scope):
            raise Forbidden(f"scope {scope} is required")
        return ctx

    return _guard
