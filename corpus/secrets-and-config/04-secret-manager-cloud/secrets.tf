# Modul Terraform yang mendefinisikan wadah rahasia platform di tiga penyedia awan.
#
# Residensi data (§7 butir 7) memaksa satu region dijalankan di penyedia yang punya wilayah
# hukum yang tepat: eu-west, eu-central, na-east, na-west, latam-br dan apac-sg di AWS,
# apac-jp di Google Cloud, mea-ae di Azure. Modul ini hanya membuat wadahnya dan mengatur siapa
# yang boleh membacanya — isi rahasianya ditulis operator lewat Vault dan tidak pernah menjadi
# nilai Terraform, karena apa pun yang masuk ke state akan tersimpan sebagai teks biasa.
#
# Karena itu tidak ada satu pun blok di bawah yang memiliki argumen `secret_string`.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.44" }
    google  = { source = "hashicorp/google", version = "~> 5.24" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.98" }
  }
}

variable "aws_account_id" {
  description = "Akun AWS produksi tempat enam region platform dijalankan."
  type        = string
  default     = "481920377154"
}

variable "kv_recovery_window_days" {
  description = "Jendela pemulihan sebelum rahasia benar-benar terhapus."
  type        = number
  default     = 30
}

# Nama rahasia mengikuti nama service pada §1 supaya path-nya sejajar dengan tata letak Vault
# (of/data/<service>/<kelompok>) dan bisa dicari dari OF_SERVICE_NAME saja.
locals {
  aws_regions = {
    "eu-west"   = "eu-west-1"
    "eu-central" = "eu-central-1"
    "na-east"   = "us-east-1"
    "na-west"   = "us-west-2"
    "apac-sg"   = "ap-southeast-1"
    "latam-br"  = "sa-east-1"
  }

  # Kelompok rahasia per service. Satu entri menghasilkan satu wadah di tiap region tempat
  # service itu dijalankan.
  secret_groups = {
    "identity-service"      = ["postgres", "signing-keys", "kafka"]
    "container-registry"    = ["postgres", "kafka"]
    "telemetry-ingest"      = ["postgres", "kafka", "gateway-verification"]
    "customs-service"       = ["postgres", "kafka", "authority"]
    "billing-service"       = ["postgres", "kafka", "payment-providers"]
    "document-service"      = ["postgres", "object-store", "cdn"]
    "notification-service"  = ["postgres", "providers", "push-keys"]
    "partner-portal-api"    = ["postgres", "session-signing"]
    "analytics-pipeline"    = ["warehouse", "readonly-postgres"]
    "audit-ledger"          = ["postgres", "notary"]
  }

  aws_secret_pairs = merge([
    for service, groups in local.secret_groups : {
      for group in groups : "${service}/${group}" => {
        service = service
        group   = group
      }
    }
  ]...)
}

# --- AWS Secrets Manager ------------------------------------------------------------------------
# Satu rahasia per service dan kelompok, di region eu-west. Region lain dibuat oleh instans modul
# yang sama dengan alias provider berbeda; replikasi lintas region sengaja dimatikan karena
# menyalin rahasia latam-br ke Eropa melanggar aturan residensi.
resource "aws_secretsmanager_secret" "service_secret" {
  for_each = local.aws_secret_pairs

  name        = "of/${each.value.service}/${each.value.group}"
  description = "Rahasia ${each.value.group} milik ${each.value.service} (region eu-west)."
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = var.kv_recovery_window_days

  tags = {
    "of:service"     = each.value.service
    "of:region-code" = "eu-west"
    "of:managed-by"  = "terraform"
  }
}

resource "aws_kms_key" "secrets" {
  description             = "Kunci amplop untuk seluruh rahasia platform di eu-west."
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/of-secrets-eu-west"
  target_key_id = aws_kms_key.secrets.key_id
}

# Kebijakan baca: hanya peran IRSA milik service itu sendiri yang boleh membaca rahasianya.
data "aws_iam_policy_document" "read_own_secret" {
  for_each = local.aws_secret_pairs

  statement {
    sid     = "ServiceReadsOwnSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${var.aws_account_id}:role/of-${each.value.service}-eu-west",
      ]
    }

    resources = [aws_secretsmanager_secret.service_secret[each.key].arn]
  }

  statement {
    sid     = "DenyEverythingWithoutTLS"
    effect  = "Deny"
    actions = ["secretsmanager:*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [aws_secretsmanager_secret.service_secret[each.key].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "service_secret" {
  for_each = local.aws_secret_pairs

  secret_arn = aws_secretsmanager_secret.service_secret[each.key].arn
  policy     = data.aws_iam_policy_document.read_own_secret[each.key].json
}

# --- Google Secret Manager (region apac-jp) -----------------------------------------------------
resource "google_secret_manager_secret" "apac_jp" {
  for_each = toset([
    "document-service/object-store",
    "document-service/cdn",
    "telemetry-ingest/postgres",
    "telemetry-ingest/gateway-verification",
    "container-registry/postgres",
  ])

  project   = "orbitalfreight-apac"
  secret_id = replace("of-${each.value}", "/", "-")

  replication {
    user_managed {
      replicas {
        location = "asia-northeast1"
      }
    }
  }

  labels = {
    of_region_code = "apac-jp"
    of_managed_by  = "terraform"
  }
}

resource "google_secret_manager_secret_iam_member" "apac_jp_reader" {
  for_each = google_secret_manager_secret.apac_jp

  project   = each.value.project
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:of-workload-apac-jp@orbitalfreight-apac.iam.gserviceaccount.com"
}

# --- Azure Key Vault (region mea-ae) ------------------------------------------------------------
resource "azurerm_key_vault" "mea_ae" {
  name                       = "of-mea-ae"
  resource_group_name        = "of-platform-mea-ae"
  location                   = "uaenorth"
  tenant_id                  = "9c4f21a7-3e8b-4d16-b0a5-72fd3c81e940"
  sku_name                   = "premium"
  purge_protection_enabled   = true
  soft_delete_retention_days = var.kv_recovery_window_days

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    virtual_network_subnet_ids = [
      "/subscriptions/2f7c9b41-58ad-4e02-9c3d-6b18ae470f52/resourceGroups/of-platform-mea-ae/providers/Microsoft.Network/virtualNetworks/of-mea-ae/subnets/workloads",
    ]
  }
}

# Wadah rahasianya saja; nilainya ditulis operator dengan `az keyvault secret set` dari sesi yang
# sudah diaudit, sehingga tidak pernah melewati Terraform state.
resource "azurerm_key_vault_secret" "mea_ae" {
  for_each = toset([
    "of-document-service-object-store",
    "of-document-service-cdn",
    "of-notification-service-providers",
  ])

  name         = each.value
  key_vault_id = azurerm_key_vault.mea_ae.id
  value        = "menunggu-penulisan-operator"
  content_type = "application/json"

  lifecycle {
    # Nilai dikelola di luar Terraform; perubahan isinya bukan drift.
    ignore_changes = [value]
  }
}

# --- Keluaran ------------------------------------------------------------------------------------
# Yang diekspor hanya penunjuk: ARN, nama sumber daya dan URI. Ketiganya bukan rahasia, dan
# memang harus ikut ke ConfigMap supaya aplikasi tahu apa yang harus diminta.
output "aws_secret_arns" {
  description = "ARN Secrets Manager per service dan kelompok, region eu-west."
  value = {
    for key, secret in aws_secretsmanager_secret.service_secret : key => secret.arn
  }
}

output "gcp_secret_names" {
  description = "Nama sumber daya penuh Secret Manager untuk apac-jp."
  value = {
    for key, secret in google_secret_manager_secret.apac_jp :
    key => "projects/orbitalfreight-apac/secrets/${secret.secret_id}/versions/latest"
  }
}

output "azure_key_vault_uris" {
  description = "URI rahasia Key Vault untuk mea-ae."
  value = {
    for key, secret in azurerm_key_vault_secret.mea_ae :
    key => "https://of-mea-ae.vault.azure.net/secrets/${secret.name}"
  }
}
