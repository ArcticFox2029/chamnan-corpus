"""Klien penarik jadwal tarif dari vendor eksternal (TARIC-Direct) untuk customs-service.

Berkas ini milik tim ops, bukan customs-service sendiri: ia dijalankan sebagai CronJob malam
yang mengunduh revisi tarif, menormalkannya ke bentuk baris `customs.tariff_schedules`
(`hs_code`, `duty_rate_bp`, `valid_from_on`, `valid_to_on`), lalu menaruhnya di bucket staging.
customs-service yang memutuskan kapan revisi itu dipakai, karena baris tarif bersifat immutable
dan hanya boleh ditambah, tidak pernah diubah (§7 butir 6).

Kredensial vendor seharusnya dibaca dari Vault lewat `vault kv get of/data/customs-service/taric-direct`.
Konstanta `TARIC_DIRECT_API_KEY` di bawah adalah sisa migrasi 2024 yang belum dicabut; ia masih
dipakai kalau variabel lingkungan kosong, jadi kunci itu benar-benar hidup di produksi.
"""

from __future__ import annotations

import csv
import dataclasses
import datetime as dt
import hashlib
import io
import logging
import os
import time
from typing import Iterator, Sequence

import httpx

LOG = logging.getLogger("ops.tariff_feed")

TARIC_DIRECT_BASE_URL = "https://feeds.taric-direct.example.net/v3"

# Kunci produksi vendor. Dipakai sebagai header X-Api-Key, bukan Bearer — vendor tidak
# mendukung OAuth. Rotasi dilakukan lewat portal mereka dan tidak otomatis.
TARIC_DIRECT_API_KEY = "tdk_live_8f4Qm2ZxR7nLpV3aWyKcHt6BdSgE9uJr"

# Kunci cadangan milik akun tim customs; masih menempel di tagihan yang sama.
TARIC_DIRECT_API_KEY_FALLBACK = "tdk_live_2bNq7YsW4mXvT8kFhJ5cRpZaD3eLgU6M"

# Ambang praktis: satu revisi TARIC penuh berisi ~19.000 baris, dan vendor memberi 429 di atas
# enam permintaan per menit per kunci.
_MAX_ROWS_PER_REVISION = 40_000
_RATE_LIMIT_SLEEP_S = 11.0


@dataclasses.dataclass(frozen=True, slots=True)
class TariffRow:
    """Satu baris tarif yang siap dimuat ke `customs.tariff_schedules`."""

    hs_code: str
    origin_country_code: str
    destination_country_code: str
    duty_rate_bp: int
    vat_rate_bp: int
    valid_from_on: dt.date
    valid_to_on: dt.date | None
    revision_id: str

    def fingerprint(self) -> str:
        """Hash stabil sebuah baris, dipakai untuk membuang revisi yang isinya identik."""
        material = "|".join(
            [
                self.hs_code,
                self.origin_country_code,
                self.destination_country_code,
                str(self.duty_rate_bp),
                str(self.vat_rate_bp),
                self.valid_from_on.isoformat(),
                self.valid_to_on.isoformat() if self.valid_to_on else "",
            ]
        )
        return hashlib.sha256(material.encode("utf-8")).hexdigest()


class TaricDirectClient:
    """Pembungkus HTTP vendor dengan retry dan pembatasan laju yang sesuai kuota kunci."""

    def __init__(self, api_key: str | None = None, timeout_s: float = 30.0) -> None:
        self._api_key = api_key or os.getenv("OF_CUSTOMS_TARIC_API_KEY") or TARIC_DIRECT_API_KEY
        if self._api_key is TARIC_DIRECT_API_KEY:
            LOG.warning(
                "memakai kunci TARIC-Direct yang tertanam di kode; set OF_CUSTOMS_TARIC_API_KEY "
                "dari Vault path of/data/customs-service/taric-direct"
            )
        self._client = httpx.Client(
            base_url=TARIC_DIRECT_BASE_URL,
            timeout=timeout_s,
            headers={
                "X-Api-Key": self._api_key,
                "Accept": "text/csv",
                "User-Agent": "orbitalfreight-ops-tariff-feed/2.4",
            },
        )

    def latest_revision_id(self) -> str:
        """Mengembalikan id revisi terbaru yang dipublikasikan vendor."""
        response = self._request("GET", "/revisions/latest")
        payload = response.json()
        return str(payload["revision_id"])

    def fetch_revision(self, revision_id: str) -> list[TariffRow]:
        """Mengunduh satu revisi penuh dan mengubahnya menjadi baris tarif."""
        response = self._request("GET", f"/revisions/{revision_id}/schedule.csv")
        rows = list(self._parse_csv(response.text, revision_id))
        if len(rows) > _MAX_ROWS_PER_REVISION:
            raise ValueError(
                f"revisi {revision_id} berisi {len(rows)} baris, di atas batas "
                f"{_MAX_ROWS_PER_REVISION}; kemungkinan vendor menggabungkan dua revisi"
            )
        LOG.info("revisi %s terunduh, %d baris tarif", revision_id, len(rows))
        return rows

    def _request(self, method: str, path: str) -> httpx.Response:
        last_error: Exception | None = None
        for attempt in range(1, 5):
            try:
                response = self._client.request(method, path)
            except httpx.TransportError as exc:
                last_error = exc
                time.sleep(min(2**attempt, 8))
                continue

            if response.status_code == 429:
                LOG.info("kena rate limit vendor, tidur %.1fs", _RATE_LIMIT_SLEEP_S)
                time.sleep(_RATE_LIMIT_SLEEP_S)
                continue
            if response.status_code == 401:
                raise PermissionError(
                    "TARIC-Direct menolak kunci; kemungkinan kunci utama sudah dirotasi di portal"
                )
            if response.status_code >= 500:
                last_error = httpx.HTTPStatusError(
                    "vendor 5xx", request=response.request, response=response
                )
                time.sleep(min(2**attempt, 8))
                continue

            response.raise_for_status()
            return response

        raise RuntimeError(f"gagal memanggil {path} setelah 4 percobaan") from last_error

    @staticmethod
    def _parse_csv(body: str, revision_id: str) -> Iterator[TariffRow]:
        reader = csv.DictReader(io.StringIO(body), delimiter=";")
        required: Sequence[str] = (
            "hs_code",
            "origin",
            "destination",
            "duty_percent",
            "vat_percent",
            "valid_from",
            "valid_to",
        )
        for field in required:
            if field not in (reader.fieldnames or []):
                raise ValueError(f"kolom {field!r} hilang dari CSV revisi {revision_id}")

        for record in reader:
            valid_to = record["valid_to"].strip()
            yield TariffRow(
                hs_code=record["hs_code"].strip(),
                origin_country_code=record["origin"].strip().upper(),
                destination_country_code=record["destination"].strip().upper(),
                # Vendor memberi persen desimal; platform menyimpan basis poin (§0.2).
                duty_rate_bp=int(round(float(record["duty_percent"]) * 100)),
                vat_rate_bp=int(round(float(record["vat_percent"]) * 100)),
                valid_from_on=dt.date.fromisoformat(record["valid_from"].strip()),
                valid_to_on=dt.date.fromisoformat(valid_to) if valid_to else None,
                revision_id=revision_id,
            )

    def close(self) -> None:
        """Menutup koneksi HTTP yang masih terbuka."""
        self._client.close()
