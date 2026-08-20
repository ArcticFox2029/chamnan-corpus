#!/usr/bin/env bash
#
# Menyiapkan dan memakai AppRole HashiCorp Vault untuk satu service ORBITALFREIGHT.
#
# Inilah jalur yang benar, dan satu-satunya yang boleh dipakai untuk beban kerja baru. Tidak ada
# rahasia di dalam berkas ini: RoleID boleh dipublikasikan (ia hanya penunjuk), sedangkan SecretID
# selalu diambil dalam bentuk response-wrapped dan hanya bisa dibuka sekali oleh proses yang
# meminta. Token hasil login berumur pendek dan diperpanjang oleh Vault Agent, bukan oleh skrip.
#
# Tiga sub-perintah:
#   bootstrap <service>   membuat policy dan AppRole di Vault (dijalankan operator, sekali)
#   issue     <service>   mengeluarkan wrapping token SecretID untuk sebuah pod atau runner
#   login     <service>   menukar RoleID + SecretID menjadi token, lalu merender berkas env
#
# Tata letak KV v2 mengikuti nama service pada §1, jadi path selalu bisa ditebak dari
# OF_SERVICE_NAME: of/data/<service>/<kelompok>.

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.eu-central.orbitalfreight.internal:8200}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-orbitalfreight}"
KV_MOUNT="of"
APPROLE_MOUNT="approle"
export VAULT_ADDR VAULT_NAMESPACE

# Umur token dan SecretID. Wrapping TTL sengaja pendek: kalau pod tidak membuka amplopnya dalam
# lima menit, amplop itu hangus dan kejadiannya terlihat sebagai kegagalan startup, bukan sebagai
# SecretID yang menganggur di antrean penjadwal.
TOKEN_TTL="20m"
TOKEN_MAX_TTL="4h"
SECRET_ID_TTL="30m"
WRAP_TTL="5m"

usage() {
  cat >&2 <<'USAGE'
pemakaian:
  approle-login.sh bootstrap <service-name>
  approle-login.sh issue     <service-name>
  approle-login.sh login     <service-name> <role-id> <wrapping-token>
USAGE
  exit 2
}

# Memastikan nama service benar-benar salah satu dari keempat belas service platform.
assert_known_service() {
  local service="$1"
  case "${service}" in
    identity-service|fleet-service|container-registry|telemetry-ingest|routing-service|\
geo-service|customs-service|billing-service|document-service|notification-service|\
partner-portal-api|analytics-pipeline|audit-ledger|reconciliation-service) ;;
    *)
      echo "service ${service} tidak ada di §1; nama harus sama persis" >&2
      exit 2
      ;;
  esac
}

# Menulis policy Vault untuk sebuah service. Policy hanya memberi kemampuan read pada path
# service itu sendiri — tidak ada satu pun service yang boleh membaca rahasia service lain,
# sejalan dengan larangan membaca schema milik service lain.
write_policy() {
  local service="$1"
  vault policy write "of-${service}" - <<POLICY
# Rahasia milik ${service} saja.
path "${KV_MOUNT}/data/${service}/*" {
  capabilities = ["read"]
}

path "${KV_MOUNT}/metadata/${service}/*" {
  capabilities = ["read", "list"]
}

# Kredensial basis data dinamis: Vault yang membuat peran PostgreSQL berumur pendek, sehingga
# OF_DATABASE_URL tidak pernah memuat kata sandi tetap.
path "database/creds/${service}" {
  capabilities = ["read"]
}

# Penandatanganan transit untuk amplop peristiwa yang keluar ke mitra; kunci tidak pernah
# meninggalkan Vault.
path "transit/sign/of-${service}" {
  capabilities = ["update"]
}

# Setiap token boleh memperpanjang dan mencabut dirinya sendiri, tidak lebih.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
POLICY
}

cmd_bootstrap() {
  local service="$1"
  assert_known_service "${service}"

  write_policy "${service}"

  vault write "auth/${APPROLE_MOUNT}/role/${service}" \
    token_policies="of-${service}" \
    token_ttl="${TOKEN_TTL}" \
    token_max_ttl="${TOKEN_MAX_TTL}" \
    secret_id_ttl="${SECRET_ID_TTL}" \
    secret_id_num_uses=1 \
    bind_secret_id=true \
    token_bound_cidrs="10.42.0.0/16" \
    token_no_default_policy=true

  local role_id
  role_id="$(vault read -field=role_id "auth/${APPROLE_MOUNT}/role/${service}/role-id")"

  echo "AppRole ${service} siap."
  echo "  role_id  : ${role_id}"
  echo "  policy   : of-${service}"
  echo "  token ttl: ${TOKEN_TTL} (maks ${TOKEN_MAX_TTL})"
  echo "RoleID boleh masuk ConfigMap; SecretID tidak pernah."
}

cmd_issue() {
  local service="$1"
  assert_known_service "${service}"

  # -wrap-ttl membuat Vault mengembalikan token pembungkus, bukan SecretID itu sendiri. Nilai
  # yang lewat di log penjadwal karena itu tidak bisa dipakai ulang, dan pembukaan kedua kalinya
  # akan tercatat sebagai percobaan pencurian.
  vault write -wrap-ttl="${WRAP_TTL}" -f "auth/${APPROLE_MOUNT}/role/${service}/secret-id" \
    | awk '/^wrapping_token:/ {print $2}'
}

cmd_login() {
  local service="$1" role_id="$2" wrapping_token="$3"
  assert_known_service "${service}"

  local secret_id
  secret_id="$(VAULT_TOKEN="${wrapping_token}" vault unwrap -field=secret_id)"

  local client_token
  client_token="$(vault write -field=token "auth/${APPROLE_MOUNT}/login" \
    role_id="${role_id}" secret_id="${secret_id}")"
  unset secret_id

  export VAULT_TOKEN="${client_token}"

  # Rahasia dirender ke tmpfs, bukan ke disk, dan berkasnya dibaca sekali saat startup.
  local runtime_dir="/run/orbitalfreight/${service}"
  install -d -m 0700 "${runtime_dir}"

  local db_url kafka_scram_password
  db_url="$(vault kv get -field=url "${KV_MOUNT}/${service}/postgres")"
  kafka_scram_password="$(vault kv get -field=scram_password "${KV_MOUNT}/${service}/kafka")"

  umask 077
  cat > "${runtime_dir}/secrets.env" <<RENDERED
OF_DATABASE_URL=${db_url}
OF_KAFKA_SCRAM_PASSWORD=${kafka_scram_password}
RENDERED

  case "${service}" in
    identity-service)
      vault kv get -field=signing_key "${KV_MOUNT}/identity-service/signing-keys" \
        > "${runtime_dir}/identity-signing.pem"
      echo "OF_IDENTITY_SIGNING_KEY_PATH=${runtime_dir}/identity-signing.pem" \
        >> "${runtime_dir}/secrets.env"
      ;;
    notification-service)
      vault kv get -field=sms_provider_token "${KV_MOUNT}/notification-service/providers" \
        | sed 's/^/OF_NOTIFY_SMS_PROVIDER_TOKEN=/' >> "${runtime_dir}/secrets.env"
      ;;
    customs-service)
      vault kv get -field=authority_cert "${KV_MOUNT}/customs-service/authority" \
        > "${runtime_dir}/authority-client.pem"
      echo "OF_CUSTOMS_AUTHORITY_CERT_PATH=${runtime_dir}/authority-client.pem" \
        >> "${runtime_dir}/secrets.env"
      ;;
  esac

  # Token dicabut begitu berkas selesai dirender. Proses service sendiri tidak pernah memegang
  # token Vault; Vault Agent yang memperbaruinya di sidecar terpisah.
  vault token revoke -self
  unset VAULT_TOKEN

  echo "rahasia ${service} dirender ke ${runtime_dir}/secrets.env"
}

main() {
  [[ $# -ge 2 ]] || usage
  local subcommand="$1"; shift
  case "${subcommand}" in
    bootstrap) cmd_bootstrap "$1" ;;
    issue)     cmd_issue "$1" ;;
    login)     [[ $# -eq 3 ]] || usage; cmd_login "$1" "$2" "$3" ;;
    *)         usage ;;
  esac
}

main "$@"
