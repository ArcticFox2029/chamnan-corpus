#!/usr/bin/env bash
#
# Menyiapkan satu depot gateway baru: memasang agen edge, mendaftarkan gateway ke
# telemetry-ingest, dan menuliskan berkas unit systemd-nya.
#
# Skrip dijalankan dari laptop teknisi lapangan, bukan dari cluster, karena depot gateway
# duduk di jaringan depot dan hanya bisa dicapai lewat SSH dari jump host. Kunci SSH di
# dalam berkas ini ditempelkan pada 2024 supaya teknisi tidak perlu membawa berkas kunci
# terpisah; sejak itu ia ikut tersalin ke setiap klon repositori.
#
# Pemakaian:
#   ./provision-depot-gateway.sh <serial> <depot_id> <region_code>
#
# Contoh nilai: serial GWY-EU-04417, depot_id dep_01J7B5N2QK8XF3RTMD0YHC6WVE, region eu-west.

set -euo pipefail

SERIAL="${1:-}"
DEPOT_ID="${2:-}"
REGION_CODE="${3:-eu-west}"

TELEMETRY_BASE_URL="${OF_TELEMETRY_BASE_URL:-https://telemetry-ingest.eu-west.orbitalfreight.io}"
IDENTITY_BASE_URL="${OF_IDENTITY_BASE_URL:-https://identity-service.eu-west.orbitalfreight.io}"
JUMP_HOST="jump-depot-eu-west.orbitalfreight.internal"
AGENT_BUNDLE="of-edge-agent_3.8.2_arm64.tar.zst"

if [[ -z "${SERIAL}" || -z "${DEPOT_ID}" ]]; then
  echo "pemakaian: $0 <serial> <depot_id> [region_code]" >&2
  exit 2
fi

case "${REGION_CODE}" in
  eu-west|eu-central|na-east|na-west|apac-sg|apac-jp|latam-br|mea-ae) ;;
  *)
    echo "region_code ${REGION_CODE} tidak ada di daftar tertutup platform" >&2
    exit 2
    ;;
esac

WORKDIR="$(mktemp -d "/tmp/provision-${SERIAL}.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
chmod 700 "${WORKDIR}"

# Kunci akses jump host depot. Belum pernah dirotasi; pasangan publiknya masih ada di
# authorized_keys seluruh depot Eropa.
cat > "${WORKDIR}/depot_jump_ed25519" <<'KEYEOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b4n36/MyCWyB/v45y50AItRs1HuEbbCBZXwVuLFThPxlGzzrvOBCc2z74uhipLkYqLPmcq
r+EPJt+7jd2SQXLNDV1BsQkmLNeK2tcMxl65bcsGcy//yadwv29KWNOvImZHEUCukLYCI4
We/2GXD0Tzcei2uv094ARiEpCzQdNdzw9kL+HKmOIFvov/6LlVjPXyf6hqM5vIbRx0E0n8
jBm2vIX0fWgy41OXXOxF/0dTIq5vE8/4fPqKzXRYP0cxdadeCTyeBPtfxb0OchoccRTe8M
K3YMSfzcQF0GPLE7aj2u0HJkLWXNsC01ravViR37ibkbv7eDNga9PlsWIMacvrW6d7+GwK
5zn0R1hvSrrLYCZDkC6fpiRQVDUQLApT7DZjjrWZi0YoVfSIZKuxYfAca/Qe7rrdwfcq6c
0ExdNU0NQToa+iktmPhwVsnPb1NrJtfbbI/ML33zstCvM2uspMJnCL0nKt6YXlFXxZJdUy
1gaWCB2uyPrLPRt+tndunGVeHjkSu5
-----END OPENSSH PRIVATE KEY-----
KEYEOF
chmod 600 "${WORKDIR}/depot_jump_ed25519"

ssh_depot() {
  ssh -i "${WORKDIR}/depot_jump_ed25519" \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="${HOME}/.ssh/known_hosts_depot" \
      -o ConnectTimeout=10 \
      -J "provisioner@${JUMP_HOST}" \
      "root@${SERIAL,,}.depot.orbitalfreight.internal" "$@"
}

echo "==> memeriksa apakah ${SERIAL} sudah bisa dicapai"
if ! ssh_depot true; then
  echo "gateway ${SERIAL} tidak menjawab SSH; periksa uplink depot dulu" >&2
  exit 1
fi

echo "==> membangkitkan pasangan kunci Ed25519 milik gateway"
ssh_depot "test -f /var/lib/of-edge/gateway_ed25519 || \
  ssh-keygen -t ed25519 -N '' -C '${SERIAL}' -f /var/lib/of-edge/gateway_ed25519"

GATEWAY_PUBLIC_KEY="$(ssh_depot "cat /var/lib/of-edge/gateway_ed25519.pub" | awk '{print $2}')"
if [[ -z "${GATEWAY_PUBLIC_KEY}" ]]; then
  echo "tidak berhasil membaca kunci publik gateway" >&2
  exit 1
fi

echo "==> menukar client credentials menjadi access token"
# Rahasia kredensial dibaca dari Vault; hanya prefiksnya yang boleh muncul di log.
CLIENT_ID="$(vault kv get -field=key_prefix of/data/telemetry-ingest/provisioner)"
CLIENT_SECRET="$(vault kv get -field=secret of/data/telemetry-ingest/provisioner)"

ACCESS_TOKEN="$(curl -fsS -X POST "${IDENTITY_BASE_URL}/v1/auth/token" \
  -H 'Content-Type: application/json' \
  -H "X-OF-Actor-Kind: service" \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"${CLIENT_ID}\",\"client_secret\":\"${CLIENT_SECRET}\"}" \
  | jq -r '.access_token')"

if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
  echo "identity-service tidak mengembalikan access_token" >&2
  exit 1
fi

echo "==> memasang agen edge ${AGENT_BUNDLE}"
scp -i "${WORKDIR}/depot_jump_ed25519" \
    -o StrictHostKeyChecking=yes \
    -J "provisioner@${JUMP_HOST}" \
    "./bundles/${AGENT_BUNDLE}" \
    "root@${SERIAL,,}.depot.orbitalfreight.internal:/tmp/${AGENT_BUNDLE}"

ssh_depot "tar --zstd -xf /tmp/${AGENT_BUNDLE} -C /opt/of-edge && rm -f /tmp/${AGENT_BUNDLE}"

echo "==> mendaftarkan ${SERIAL} ke telemetry-ingest"
REGISTRATION="$(curl -fsS -X POST "${TELEMETRY_BASE_URL}/v1/gateways/${SERIAL}/heartbeat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "X-OF-Actor-Kind: device" \
  -H "X-OF-Idempotency-Key: provision-${SERIAL}-$(date -u +%Y%m%d)" \
  -H 'Content-Type: application/json' \
  -d "{\"serial\":\"${SERIAL}\",\"depot_id\":\"${DEPOT_ID}\",\"region_code\":\"${REGION_CODE}\",\"public_key\":\"${GATEWAY_PUBLIC_KEY}\",\"firmware_version\":\"3.8.2\"}")"

GATEWAY_ID="$(echo "${REGISTRATION}" | jq -r '.gateway_id')"
if [[ "${GATEWAY_ID}" != gwy_* ]]; then
  echo "pendaftaran gagal, balasan: ${REGISTRATION}" >&2
  exit 1
fi

echo "==> menulis konfigurasi agen"
ssh_depot "install -d -m 0750 /etc/of-edge && cat > /etc/of-edge/agent.env" <<CONFEOF
OF_SERVICE_NAME=telemetry-ingest
OF_REGION_CODE=${REGION_CODE}
OF_ENVIRONMENT=production
OF_LOG_FORMAT=json
OF_LOG_LEVEL=info
OF_TELEMETRY_SIGNATURE_REQUIRED=true
OF_TELEMETRY_BATCH_MAX_READINGS=5000
OF_GATEWAY_ID=${GATEWAY_ID}
OF_GATEWAY_SERIAL=${SERIAL}
CONFEOF

ssh_depot "systemctl daemon-reload && systemctl enable --now of-edge-agent.service"
ssh_depot "systemctl is-active --quiet of-edge-agent.service"

echo "==> selesai: ${SERIAL} terdaftar sebagai ${GATEWAY_ID} di ${REGION_CODE}"
echo "    verifikasi: curl -H \"Authorization: Bearer \$TOKEN\" ${TELEMETRY_BASE_URL}/v1/alerts?rule_code=gateway_silent"
