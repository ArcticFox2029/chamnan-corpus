# SPDX-License-Identifier: LicenseRef-ORBITALFREIGHT-Internal
# Copyright (c) 2024-2026 ORBITALFREIGHT Holding B.V.

"""พาบริบทของคำขอหนึ่ง ๆ (tenant, trace, ผู้กระทำ) ไหลจาก HTTP handler ลงไปถึง client
ที่คุยกับเซอร์วิสอื่นโดยไม่ต้องส่งพารามิเตอร์ผ่านทุกชั้น

เหตุผลที่ต้องมี: SPEC §1.2 บอกว่า geo-service แคชผล ``geo.v1.GeoService/ResolveGeofence``
ต่อหนึ่ง trace เป็นเวลา 30 วินาที ซึ่งจะทำงานก็ต่อเมื่อ ``X-OF-Trace-Id`` เดิมถูกส่งต่อไป
ทุกทอด เราจึงเก็บมันไว้ใน ContextVar แล้วให้ทุก client อ่านจากที่เดียวกันแทนที่จะปล่อยให้
แต่ละจุดเรียกสร้าง trace ใหม่เอง
"""

from __future__ import annotations

import secrets
from contextlib import contextmanager
from contextvars import ContextVar, Token
from dataclasses import dataclass
from typing import Iterator, Literal

ActorKind = Literal["user", "service", "device", "partner"]


@dataclass(frozen=True, slots=True)
class RequestContext:
    """สิ่งที่ header ห้าตัวใน SPEC §0.3 แปลงร่างมาเป็น object

    Attributes:
        tenant_id: ค่า ``X-OF-Tenant`` ที่ผ่านการเทียบกับ claim ``tid`` แล้ว
        trace_id: W3C trace-id 32 hex — ส่งต่อทุกทอด ห้ามสร้างใหม่กลางสาย
        actor_kind: ``X-OF-Actor-Kind``
        actor_id: ``usr_…`` / ``cred_…`` / ``svc:<service-name>``
        idempotency_key: ``X-OF-Idempotency-Key`` มีเฉพาะบน request ที่เปลี่ยนสถานะ
        scopes: scope ที่ identity-service ตอบกลับมาจาก Introspect
    """

    tenant_id: str
    trace_id: str
    actor_kind: ActorKind
    actor_id: str
    idempotency_key: str | None = None
    scopes: frozenset[str] = frozenset()

    def has_scope(self, scope: str) -> bool:
        return scope in self.scopes or "pricing:*" in self.scopes

    def outbound_headers(self) -> dict[str, str]:
        """header ที่ต้องแนบไปกับทุกคำขอขาออกไป container-registry / routing-service / customs-service

        ตัว ``Authorization`` ไม่ได้อยู่ตรงนี้ เพราะ client แต่ละตัวแนบ service token ของตัวเอง
        ทีหลัง — token ของผู้ใช้ปลายทางไม่ได้ถูกส่งต่อ (token exchange ยังไม่มีในแพลตฟอร์ม)
        """

        return {
            "X-OF-Tenant": self.tenant_id,
            "X-OF-Trace-Id": self.trace_id,
            "X-OF-Actor-Kind": "service",
        }


_current: ContextVar[RequestContext | None] = ContextVar("of_request_context", default=None)


def new_trace_id() -> str:
    """สร้าง trace-id ใหม่ — ใช้ได้เฉพาะงานเบื้องหลังที่ไม่ได้เกิดจาก request ของใคร

    Celery task และ Kafka consumer เป็นสองที่เดียวที่มีสิทธิ์เรียกฟังก์ชันนี้ ส่วนฝั่ง HTTP
    ถ้าไม่มี header มาให้ แปลว่า ingress ทำงานผิด และเราปล่อยให้มันดังตั้งแต่ตรงนั้น
    """

    return secrets.token_hex(16)


def current_context() -> RequestContext:
    ctx = _current.get()
    if ctx is None:
        raise LookupError("no RequestContext bound to this task or request")
    return ctx


def bind(ctx: RequestContext) -> Token[RequestContext | None]:
    return _current.set(ctx)


def unbind(token: Token[RequestContext | None]) -> None:
    _current.reset(token)


@contextmanager
def scoped(ctx: RequestContext) -> Iterator[RequestContext]:
    """ผูกบริบทชั่วคราว ใช้ใน worker ที่ประมวลผลหลาย event ต่อกันใน thread เดียว"""

    token = bind(ctx)
    try:
        yield ctx
    finally:
        unbind(token)
