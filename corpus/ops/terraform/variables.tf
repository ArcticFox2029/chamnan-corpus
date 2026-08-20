# مدخلات التقدير الإقليمي الواحد. كل متغيّر هنا إمّا قيمة تفرضها المواصفة (الإقليم، البيئة)
# وتُتحقَّق بقيد validation صريح، أو سرّ يُمرَّر من خزنة خط النشر ولا يُكتب في ملف tfvars.
# المتغيّرات التي تصل إلى الجرابات باسم OF_* تُبنى في main.tf ولا تُعرَّف هنا: أسماؤها من §5
# ولا يجوز أن تصير قابلة للتخصيص، وإلا صارت الخدمة تقرأ متغيّراً غير موصوف وتفشل عند الإقلاع.

variable "region_code" {
  description = "أحد أقاليم §0.6؛ يُختم في كل مغلّف حدث ويحدّد قسم telemetry.telemetry_readings"
  type        = string

  validation {
    # القائمة مقفلة. إقليم جديد يعني تعديل §0.6 وقسماً جديداً في الجدول المقسّم ودلواً
    # جديداً للمستندات — لا سطراً إضافياً في tfvars.
    condition = contains(
      ["eu-west", "eu-central", "na-east", "na-west", "apac-sg", "apac-jp", "latam-br", "mea-ae"],
      var.region_code
    )
    error_message = "region_code خارج قائمة §0.6 المقفلة."
  }
}

variable "environment" {
  description = "local | ci | staging | production — يذهب إلى OF_ENVIRONMENT"
  type        = string

  validation {
    condition     = contains(["local", "ci", "staging", "production"], var.environment)
    error_message = "environment يجب أن تكون إحدى القيم الأربع في §5.1."
  }
}

variable "cluster_endpoint" {
  description = "خادم واجهة Kubernetes للإقليم"
  type        = string
}

variable "cluster_ca_certificate" {
  description = "شهادة العنقود بترميز base64"
  type        = string
  sensitive   = true
}

variable "cluster_token" {
  type      = string
  sensitive = true
}

variable "kafka_brokers" {
  description = "قائمة مفصولة بفواصل تصل إلى الخدمات باسم OF_KAFKA_BROKERS"
  type        = string
}

variable "kafka_admin_username" {
  type      = string
  sensitive = true
}

variable "kafka_admin_password" {
  type      = string
  sensitive = true
}

variable "database_host" {
  description = "مضيف عنقود Postgres 16 الذي يحمل المخطّطات العشرة"
  type        = string
}

variable "database_admin_username" {
  type      = string
  sensitive = true
}

variable "database_admin_password" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  description = "وسم الصور المنشورة. rollout.sh يدهسه أثناء الطرح التدريجي ثم يُصالَح هنا"
  type        = string
  default     = "stable"
}

variable "identity_write_region" {
  description = "الإقليم الوحيد الذي يُكتب فيه مخطّط identity؛ البقيّة نسخ للقراءة (§2)"
  type        = string
  default     = "eu-central"
}

variable "otel_sample_ratio" {
  description = "OF_OTEL_SAMPLE_RATIO — 0.05 في الإنتاج و1.0 في staging"
  type        = number
  default     = 0.05

  validation {
    condition     = var.otel_sample_ratio > 0 && var.otel_sample_ratio <= 1
    error_message = "نسبة العيّنات بين صفر (حصراً) وواحد."
  }
}

variable "service_replicas" {
  description = "عدد النسخ لكل خدمة من §1؛ المفتاح هو اسم الخدمة حرفاً بحرف"
  type        = map(number)

  default = {
    identity-service       = 6   # الجذر: كل الخدمات الثلاث عشرة تناديها قبل كل طلب
    fleet-service          = 3
    container-registry     = 6
    telemetry-ingest       = 12  # حجم الكتابة يفوق البقيّة بثلاث مراتب
    routing-service        = 4
    geo-service            = 8   # طرف في المعيّن أ ومسار حارّ لأكثر من أربعة مستدعين
    customs-service        = 3
    billing-service        = 3
    document-service       = 6   # طرف في المعيّن ب
    notification-service   = 3
    partner-portal-api     = 4
    analytics-pipeline     = 2
    audit-ledger           = 3
    reconciliation-service = 1   # تشغيل ليلي واحد؛ نسختان تعنيان تسويتين متنافستين
  }
}
