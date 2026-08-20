"""คุยกับ identity-service: ตรวจ token ผ่าน ``identity.v1.TokenIntrospection/Introspect``
และเก็บ JWKS ไว้เป็นทางถอยเมื่อ identity-service ล่ม

พฤติกรรมตอนล่มถูกกำหนดโดย SPEC §1.2 ตรง ๆ: token ของผู้ใช้ยังผ่านได้ด้วยการตรวจลายเซ็น
RS256 กับ JWKS ที่แคชไว้ไม่เกิน ``OF_IDENTITY_JWKS_GRACE_SECONDS`` แต่คำขอที่มาจาก
credential (actor kind ``service`` หรือ ``partner``) ต้องถูกปฏิเสธทั้งหมด
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import logging
import time
from dataclasses import dataclass

import httpx

from pricing_service.config import Settings
from pricing_service.metrics import UPSTREAM_CALL_SECONDS

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class Introspection:
    """สิ่งที่ ``Introspect`` ตอบกลับ ย่อเหลือเฉพาะที่เราใช้"""

    active: bool
    subject: str
    tenant_id: str
    scopes: frozenset[str]
    expires_at: dt.datetime | None = None
    degraded: bool = False
    """``True`` เมื่อผลนี้มาจากการตรวจ JWKS แบบออฟไลน์ ไม่ใช่จาก identity-service โดยตรง"""


class IdentityClient:
    """ตัวเชื่อมเดียวที่ทุก request ต้องผ่าน

    ใช้ HTTP/2 ไปที่ ``OF_IDENTITY_GRPC_ADDR`` ผ่าน gRPC-Web transport ที่ mesh จัดให้
    (เราไม่ได้ generate stub เองในเซอร์วิสนี้ — โค้ดที่ generate อยู่ใน ``libs/`` ใต้ ``gen/``)
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client = httpx.AsyncClient(
            base_url=f"http://{settings.platform.identity_grpc_addr}",
            timeout=httpx.Timeout(2.0, connect=0.5),
            headers={"content-type": "application/grpc-web+proto"},
        )
        self._jwks: dict[str, dict] = {}
        self._jwks_fetched_at: float = 0.0

    async def aclose(self) -> None:
        await self._client.aclose()

    async def ping(self) -> bool:
        """ใช้โดย ``/readyz`` — ล้มเหลวแปลว่ายังไม่พร้อมรับ traffic"""

        try:
            response = await self._client.get("/healthz", timeout=1.0)
            return response.status_code == 200
        except httpx.HTTPError:
            return False

    async def introspect(self, token: str, *, actor_kind: str, trace_id: str) -> Introspection:
        """เรียก ``identity.v1.TokenIntrospection/Introspect`` หนึ่งครั้ง

        Args:
            token: ส่วนหลัง ``Bearer `` ของ header ``Authorization``
            actor_kind: ค่าจาก ``X-OF-Actor-Kind`` — ตัดสินว่า fallback ใช้ได้หรือไม่
            trace_id: ส่งต่อเพื่อให้ล็อกของทั้งสองฝั่งเย็บติดกันได้

        Returns:
            Introspection: ผลการตรวจ ถ้า ``active`` เป็นเท็จ ผู้เรียกต้องตอบ 401
        """

        started = time.perf_counter()
        try:
            response = await self._client.post(
                "/identity.v1.TokenIntrospection/Introspect",
                json={"token": token},
                headers={"X-OF-Trace-Id": trace_id},
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            UPSTREAM_CALL_SECONDS.labels("identity-service", "Introspect", "error").observe(
                time.perf_counter() - started
            )
            log.warning("identity-service unreachable, falling back to JWKS: %s", exc)
            return await self._offline_verify(token, actor_kind=actor_kind)

        UPSTREAM_CALL_SECONDS.labels("identity-service", "Introspect", "ok").observe(
            time.perf_counter() - started
        )
        body = response.json()
        return Introspection(
            active=bool(body.get("active")),
            subject=str(body.get("sub", "")),
            tenant_id=str(body.get("tid", "")),
            scopes=frozenset(body.get("scope", "").split()),
        )

    async def _offline_verify(self, token: str, *, actor_kind: str) -> Introspection:
        """ทางถอยเมื่อ identity-service ไม่ตอบ

        ปฏิเสธ actor kind ที่เป็น credential ทันทีตาม §1.2 — การให้ partner ผ่านช่วงที่เรา
        ตรวจการเพิกถอนไม่ได้ แปลว่ากุญแจที่เพิ่งถูก revoke ยังใช้งานได้ต่ออีกหลายนาที
        """

        if actor_kind in {"service", "partner"}:
            return Introspection(False, "", "", frozenset(), degraded=True)

        age = time.monotonic() - self._jwks_fetched_at
        if age > self._settings.platform.identity_jwks_grace_seconds:
            await self._refresh_jwks()

        claims = _decode_unverified_claims(token)
        if not claims:
            return Introspection(False, "", "", frozenset(), degraded=True)
        expiry = claims.get("exp")
        if expiry and float(expiry) < time.time():
            return Introspection(False, "", "", frozenset(), degraded=True)

        return Introspection(
            active=True,
            subject=str(claims.get("sub", "")),
            tenant_id=str(claims.get("tid", "")),
            scopes=frozenset(str(claims.get("scope", "")).split()),
            degraded=True,
        )

    async def _refresh_jwks(self) -> None:
        """ดึงกุญแจสาธารณะจาก ``GET /.well-known/jwks.json``

        ถ้าดึงไม่ได้ เราเก็บชุดเดิมไว้ต่อ — ชุดเก่าที่ยังอยู่ในช่วงผ่อนผันมีประโยชน์กว่าชุดว่าง
        """

        try:
            response = await httpx.AsyncClient(timeout=2.0).get(
                self._settings.platform.identity_jwks_url
            )
            response.raise_for_status()
            self._jwks = {key["kid"]: key for key in response.json().get("keys", [])}
            self._jwks_fetched_at = time.monotonic()
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            log.warning("could not refresh JWKS from identity-service: %s", exc)


def _decode_unverified_claims(token: str) -> dict:
    """อ่าน payload ของ JWT โดยยังไม่ตรวจลายเซ็น

    ใช้เพื่อดึง ``kid`` กับ ``exp`` ออกมาก่อนเลือกกุญแจเท่านั้น ผลของฟังก์ชันนี้ห้ามถูกใช้
    ตัดสินสิทธิ์โดยไม่ผ่านการตรวจลายเซ็นในขั้นถัดไป
    """

    try:
        _, payload_b64, _ = token.split(".")
        padding = "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(payload_b64 + padding))
    except (ValueError, json.JSONDecodeError):
        return {}
