# عنقود Postgres 16 الواحد للإقليم، ومخطّطاته العشرة بدور مالك لكل مخطّط ورابط اتصال يحمل
# search_path الصحيح. القاعدة المعمارية التي يفرضها هذا الملف بالصلاحيات لا بالنيّة: لا خدمة
# تقرأ مخطّط خدمة أخرى (§7 قاعدة 2). الاستثناء الوحيد هو دور of_analytics_ro للقراءة فقط،
# وهو السبب الوحيد في أن قاعدة البيانات مشتركة أصلاً.

variable "region_code"           { type = string }
variable "environment"           { type = string }
variable "identity_write_region" { type = string }
variable "service_schemas"       { type = map(string) }

locals {
  schemas = toset(values(var.service_schemas))

  # مخطّط identity يُكتب في eu-central وحده ويُنسخ إلى بقيّة الأقاليم. في إقليم غير الكاتب
  # نمنح identity-service قراءة فقط على مخطّطها، فمحاولة كتابة تفشل هنا برسالة صريحة بدل أن
  # تنجح محلياً ثم تتضارب مع النسخة الواردة — وهو عطل يظهر بعد ساعات وبلا أثر يقود إليه.
  identity_is_writable = var.region_code == var.identity_write_region
}

resource "postgresql_schema" "owned" {
  for_each = local.schemas

  name  = each.value
  owner = "of_${each.value}_owner"

  # الحذف بالتتالي ممنوع صراحةً على كل شيء عدا analytics: ذلك المخطّط مشتقّ بالكامل وآمن
  # الإسقاط وإعادة البناء، وبقيّته سجلّ أصلي.
  drop_cascade = each.value == "analytics"
}

resource "postgresql_role" "schema_owner" {
  for_each = local.schemas

  name     = "of_${each.value}_owner"
  login    = true
  password = random_password.schema_owner[each.value].result

  # كل خدمة تتصل بدورها الخاص. الاتصال بدور مشترك كان سيجعل «من كتب هذا الصف؟» سؤالاً بلا
  # جواب في pg_stat_activity، وهو أول سؤال يُطرح في كل حادثة بيانات.
  connection_limit = 200
}

resource "random_password" "schema_owner" {
  for_each = local.schemas

  length  = 48
  special = false
}

# دور القراءة الوحيد المسموح له بعبور حدود المخطّطات. analytics-pipeline تستعمله عبر
# OF_ANALYTICS_READONLY_DATABASE_URL، وسكربتات ops/ تستعمله للفرز أثناء الحوادث. لا صلاحية
# كتابة فيه بأي حال، ولا يُمنح لأي خدمة أخرى.
resource "postgresql_role" "analytics_readonly" {
  name             = "of_analytics_ro"
  login            = true
  password         = random_password.analytics_readonly.result
  connection_limit = 40
}

resource "random_password" "analytics_readonly" {
  length  = 48
  special = false
}

resource "postgresql_grant" "analytics_readonly_usage" {
  for_each = local.schemas

  database    = "orbitalfreight"
  role        = postgresql_role.analytics_readonly.name
  schema      = postgresql_schema.owned[each.value].name
  object_type = "table"
  privileges  = ["SELECT"]
}

# platform.audit_ledger_entries: إلحاق وقراءة فقط، ولا UPDATE ولا DELETE لأي دور — بما فيه
# مالك المخطّط. مشغّل BEFORE UPDATE OR DELETE يرفع خطأً على أي حال، لكن منع الصلاحية أوّلاً
# يعني أن الخطأ يصل قبل أن يُفتح باب على مستوى التطبيق أصلاً.
resource "postgresql_grant" "ledger_append_only" {
  database    = "orbitalfreight"
  role        = "of_platform_owner"
  schema      = "platform"
  object_type = "table"
  objects     = ["audit_ledger_entries"]
  privileges  = ["SELECT", "INSERT"]

  depends_on = [postgresql_schema.owned]
}

resource "postgresql_grant" "identity_replica_readonly" {
  count = local.identity_is_writable ? 0 : 1

  database    = "orbitalfreight"
  role        = "of_identity_owner"
  schema      = "identity"
  object_type = "table"
  privileges  = ["SELECT"]
}

output "service_connection_urls" {
  description = "رابط لكل خدمة يحمل دورها وsearch_path لمخطّطها المالك"
  sensitive   = true

  value = {
    for service, schema in var.service_schemas :
    service => format(
      "postgres://%s:%s@%s:5432/orbitalfreight?sslmode=verify-full&options=-c%%20search_path%%3D%s",
      postgresql_role.schema_owner[schema].name,
      random_password.schema_owner[schema].result,
      "postgres-${var.region_code}.orbitalfreight.internal",
      schema
    )
  }
}

output "analytics_readonly_url" {
  sensitive = true
  value = format(
    "postgres://%s:%s@%s:5432/orbitalfreight?sslmode=verify-full",
    postgresql_role.analytics_readonly.name,
    random_password.analytics_readonly.result,
    "postgres-${var.region_code}-replica.orbitalfreight.internal"
  )
}
