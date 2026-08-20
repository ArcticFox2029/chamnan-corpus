# مواضيع §4 الستّة وقوائم رسائلها الميّتة. التقسيم والاحتفاظ ليسا قابلين للضبط من tfvars:
# عدد الأقسام يحدّد سقف التوازي لكل مستهلك وترتيب الرسائل لكل partition_key، وتقليله بعد
# النشر مستحيل في Kafka — تُنشأ مواضيع جديدة وتُنقل المجموعات. لذلك القيم هنا مكتوبة كما في
# جدول §4 حرفياً، وأي تغيير يبدأ بتعديل المواصفة لا بتعديل هذا الملف.

variable "region_code" { type = string }
variable "environment" { type = string }

locals {
  topics = {
    # partition_key في المغلّف هو ما يحدّد الترتيب. كل ما هو مفتاحه shipment_id مرتّب لكل
    # شحنة، وهذا هو الضمان الوحيد الذي تقدّمه المنصّة — لا ترتيب عالمي ولا ترتيب لكل مستأجر.
    "of.identity.v1" = {
      partitions     = 12
      retention_days = 30
      producers      = "identity-service"
    }
    "of.freight.v1" = {
      partitions     = 48
      retention_days = 14
      producers      = "container-registry, fleet-service"
    }
    "of.telemetry.v1" = {
      # ستّة وتسعون قسماً لأن حجم كتابة telemetry-ingest يفوق بقيّة المنصّة بثلاث مراتب.
      # الاحتفاظ سبعة أيام فقط: القراءات الخام مكانها telemetry.telemetry_readings المقسّم،
      # والموضوع وسيلة نقل لا أرشيف.
      partitions     = 96
      retention_days = 7
      producers      = "telemetry-ingest"
    }
    "of.customs.v1" = {
      # تسعون يوماً لأسباب تدقيقية: إعادة بناء تصريح من أحداثه يجب أن تبقى ممكنة بعد فصل
      # كامل، وهي مدّة تكفي لدورة مراجعة سلطة جمركية.
      partitions     = 12
      retention_days = 90
      producers      = "customs-service"
    }
    "of.billing.v1" = {
      partitions     = 12
      retention_days = 90
      producers      = "billing-service"
    }
    "of.platform.v1" = {
      partitions     = 24
      retention_days = 30
      producers      = "document-service, notification-service, routing-service, reconciliation-service"
    }
  }
}

resource "kafka_topic" "main" {
  for_each = local.topics

  name               = each.key
  partitions         = each.value.partitions
  replication_factor = var.environment == "production" ? 3 : 1

  config = {
    "retention.ms" = tostring(each.value.retention_days * 24 * 60 * 60 * 1000)

    # delete لا compact: المواضيع هنا تيّار أحداث لا لقطة حالة. الحالة الحقيقية في المخطّطات،
    # والمستهلك الذي يحتاج لقطة يقرأ من الخدمة المالكة.
    "cleanup.policy" = "delete"

    # حمولات §4 أثقلها customs.declaration.filed وbilling.invoice.issued لأنهما يحملان سطور
    # التصريح والفاتورة. المليون بايت الافتراضي لا يكفي تصريحاً بمئات السطور.
    "max.message.bytes" = "4194304"

    "min.insync.replicas" = var.environment == "production" ? "2" : "1"
    "compression.type"    = "zstd"
  }
}

# قائمة الرسائل الميّتة لكل موضوع. القاعدة في §4.19: بعد ثماني محاولات بتراجع أسّي يبدأ من
# 500 مللي تنتقل الرسالة إلى ‎<topic>.dlq‎ ويُرفع تنبيه عبر notification-service. الاحتفاظ
# هنا أطول دائماً من الأصل، لأن رسالة مسمومة تُفحص بيد بشر بعد أيام لا بعد ساعات.
resource "kafka_topic" "dead_letter" {
  for_each = local.topics

  name               = "${each.key}.dlq"
  partitions         = 6
  replication_factor = var.environment == "production" ? 3 : 1

  config = {
    "retention.ms"      = tostring(90 * 24 * 60 * 60 * 1000)
    "cleanup.policy"    = "delete"
    "max.message.bytes" = "4194304"
  }
}

output "topic_names" {
  value = [for topic in kafka_topic.main : topic.name]
}

output "dead_letter_topic_names" {
  value = [for topic in kafka_topic.dead_letter : topic.name]
}
