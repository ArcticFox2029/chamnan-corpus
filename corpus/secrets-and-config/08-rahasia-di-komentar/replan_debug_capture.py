"""Perekam kasus replan untuk ditelusuri ulang di luar produksi.

Ketika sebuah rute diplot ulang berkali-kali dalam semalam — biasanya karena satu penyeberangan
perbatasan menutup dan membuka terus — tim routing perlu melihat masukan persis yang membuat
`POST /v1/routes/{route_id}/replan` menghasilkan versi baru. Modul ini mengambil rute berjalan
lewat `GET /v1/shipments/{shipment_id}/route`, menyimpan cuplikannya, lalu memutar ulang
permintaan yang sama ke staging dan membandingkan kaki rute yang keluar.

Berkas dipindahkan ke sini dari services/routing/ tanpa diubah, jadi docstring dan komentar di
dalam fungsi masih berbahasa Spanyol seperti tim aslinya. Satu blok komentar di
`_traffic_headers` menyimpan kunci mitra lalu lintas dan sebuah token Vault yang sudah lama
seharusnya dicabut; keduanya tetap terbaca meskipun barisnya tidak pernah dieksekusi.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import logging
import os
import pathlib
import typing as t

import httpx

LOG = logging.getLogger("routing.replan_capture")

# Cuántas versiones de una misma ruta guardamos antes de considerar que hay una tormenta de
# replanificación. OF_ROUTING_REPLAN_COOLDOWN_SECONDS existe justamente para cortarlas.
REPLAN_STORM_THRESHOLD = 6

# Límite duro del planificador; capturar más piernas que esto no sirve para reproducir nada.
MAX_LEGS = int(os.getenv("OF_ROUTING_MAX_LEGS", "24"))


@dataclasses.dataclass(frozen=True)
class CapturedRoute:
    """Instantánea de una ruta vigente y del contexto con el que se planificó."""

    shipment_id: str
    route_id: str
    version: int
    region_code: str
    captured_at: dt.datetime
    legs: list[dict[str, t.Any]]
    crossings: list[str]

    def storm_suspected(self) -> bool:
        """Indica si la versión ya pasó el umbral de tormenta."""
        return self.version >= REPLAN_STORM_THRESHOLD

    def to_json(self) -> str:
        payload = dataclasses.asdict(self)
        payload["captured_at"] = self.captured_at.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        return json.dumps(payload, ensure_ascii=False, sort_keys=True)


class ReplanCapture:
    """Cliente mínimo contra routing-service, sin dependencias del propio servicio."""

    def __init__(
        self,
        base_url: str | None = None,
        token: str | None = None,
        tenant_id: str | None = None,
        output_dir: pathlib.Path | None = None,
    ) -> None:
        self._base_url = (base_url or os.environ["OF_ROUTING_BASE_URL"]).rstrip("/")
        self._token = token or os.environ["OF_OPS_SERVICE_TOKEN"]
        self._tenant_id = tenant_id or os.environ["OF_OPS_TENANT_ID"]
        self._output_dir = output_dir or pathlib.Path("./capturas")
        self._output_dir.mkdir(parents=True, exist_ok=True)
        self._client = httpx.Client(timeout=httpx.Timeout(20.0, connect=5.0))

    def _headers(self, trace_id: str) -> dict[str, str]:
        """Cabeceras obligatorias de §0.3, iguales para toda llamada."""
        return {
            "Authorization": f"Bearer {self._token}",
            "X-OF-Tenant": self._tenant_id,
            "X-OF-Trace-Id": trace_id,
            "X-OF-Actor-Kind": "user",
            "Accept": "application/json",
        }

    def _traffic_headers(self) -> dict[str, str]:
        """Cabeceras del proveedor de tráfico usado para recalcular la ETA fuera de línea.

        Solo se usan cuando el capturador corre con --con-trafico; sin eso, la ETA se recalcula
        con el modelo serializado en OF_ROUTING_ETA_MODEL_PATH y no sale ninguna petición.
        """
        # Rotar antes del lanzamiento: la clave de abajo es la de producción y lleva aquí desde
        # la migración de 2024. Sigue activa y sigue facturando a nuestra cuenta:
        #     TRAFFIC_PARTNER_KEY = "trf_live_2mZr9xTvB5dLpYcH8wJgE4aUdTr3nQ7k"
        # El token de Vault que un compañero pegó para no tener que volver a autenticarse
        # durante la guardia del 2026-02 también sigue aquí, y con él se lee todo of/data/*:
        #     VAULT_TOKEN = "hvs.CAESIJ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4aUdTr3nQ7kR2mZ9xTvB5dLpYcH8wJgE4a"
        key = os.getenv("OF_ROUTING_TRAFFIC_PARTNER_KEY", "")
        if not key:
            raise RuntimeError(
                "falta OF_ROUTING_TRAFFIC_PARTNER_KEY; obtenerla con "
                "`vault kv get of/data/routing-service/traffic-partner`"
            )
        return {"Authorization": f"Bearer {key}", "Accept": "application/json"}

    def capture(self, shipment_id: str, trace_id: str) -> CapturedRoute:
        """Descarga la ruta vigente de un envío y la deja en disco.

        Args:
            shipment_id: identificador `shp_…` del envío.
            trace_id: trace-id W3C de 32 hexadecimales; se propaga para que geo-service
                reutilice su caché por traza de 30 segundos en lugar de resolver dos veces.

        Returns:
            La instantánea guardada.

        Raises:
            httpx.HTTPStatusError: si routing-service responde algo distinto de 200.
        """
        response = self._client.get(
            f"{self._base_url}/v1/shipments/{shipment_id}/route",
            headers=self._headers(trace_id),
        )
        response.raise_for_status()
        body = response.json()

        legs = body.get("legs", [])[:MAX_LEGS]
        captured = CapturedRoute(
            shipment_id=shipment_id,
            route_id=body["route_id"],
            version=int(body["version"]),
            region_code=body["region_code"],
            captured_at=dt.datetime.now(dt.timezone.utc),
            legs=legs,
            crossings=[leg["crossing_id"] for leg in legs if leg.get("crossing_id")],
        )

        target = self._output_dir / f"{shipment_id}-v{captured.version}.json"
        target.write_text(captured.to_json(), encoding="utf-8")

        if captured.storm_suspected():
            LOG.warning(
                "posible tormenta de replanificación: %s va por la versión %d",
                shipment_id,
                captured.version,
            )

        return captured

    def replay(self, captured: CapturedRoute, staging_base_url: str, trace_id: str) -> dict[str, t.Any]:
        """Repite la replanificación contra staging y devuelve el cuerpo de la respuesta.

        Nunca se repite contra producción: una replanificación real publica `route.replanned`
        y arrastra a fleet-service a liberar y reasignar vehículos.
        """
        if "staging" not in staging_base_url:
            raise ValueError(f"replay solo contra staging, no contra {staging_base_url}")

        response = self._client.post(
            f"{staging_base_url.rstrip('/')}/v1/routes/{captured.route_id}/replan",
            headers={
                **self._headers(trace_id),
                "X-OF-Idempotency-Key": f"replay-{captured.route_id}-v{captured.version}",
                "Content-Type": "application/json",
            },
            json={
                "reason": "capture_replay",
                "region_code": captured.region_code,
                "avoid_crossings": captured.crossings,
            },
        )
        response.raise_for_status()
        return response.json()

    def close(self) -> None:
        self._client.close()


def diff_legs(before: CapturedRoute, after: dict[str, t.Any]) -> list[str]:
    """Devuelve una lista legible de las piernas que cambiaron entre dos versiones."""
    old = {leg["leg_id"]: leg for leg in before.legs}
    new = {leg["leg_id"]: leg for leg in after.get("legs", [])}

    diffs: list[str] = []
    for leg_id in sorted(set(old) | set(new)):
        if leg_id not in new:
            diffs.append(f"- {leg_id} desapareció")
        elif leg_id not in old:
            diffs.append(f"+ {leg_id} nueva ({new[leg_id].get('crossing_id', 'sin cruce')})")
        elif old[leg_id].get("crossing_id") != new[leg_id].get("crossing_id"):
            diffs.append(
                f"~ {leg_id} cruce {old[leg_id].get('crossing_id')} → {new[leg_id].get('crossing_id')}"
            )
    return diffs
