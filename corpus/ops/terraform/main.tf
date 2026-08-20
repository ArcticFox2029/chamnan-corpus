# الجذر: يركّب تقدير إقليم واحد كاملاً — قاعدة البيانات ومخطّطاتها العشرة، مواضيع Kafka
# الستّة وقوائم رسائلها الميّتة، ثم الأربع عشرة خدمة من §1 بمتغيّراتها من §5. كل ما يخصّ
# إقليماً بعينه يُمرَّر من tfvars؛ لا يوجد في هذا الملف اسم إقليم مكتوب يدوياً.
#
# ترتيب depends_on هنا ليس تجميلاً: خدمة تُقلع قبل وجود موضوعها تفشل عند أول محاولة نشر من
# مُرحّل صندوق الصادر، وتبقى /readyz حمراء حتى تُعاد دورة الجرابات.

locals {
  cluster_domain = "orbitalfreight.svc.cluster.local"

  # سجل §1 كاملاً: المنفذ صفر يعني أن الخدمة لا تعرض واجهة gRPC أصلاً.
  services = {
    identity-service       = { http = 8081, grpc = 9081, schema = "identity" }
    fleet-service          = { http = 8082, grpc = 9082, schema = "fleet" }
    container-registry     = { http = 8083, grpc = 9083, schema = "freight" }
    telemetry-ingest       = { http = 8084, grpc = 9084, schema = "telemetry" }
    routing-service        = { http = 8085, grpc = 0,    schema = "routing" }
    geo-service            = { http = 8086, grpc = 9086, schema = "geo" }
    customs-service        = { http = 8087, grpc = 0,    schema = "customs" }
    billing-service        = { http = 8088, grpc = 0,    schema = "billing" }
    document-service       = { http = 8089, grpc = 0,    schema = "platform" }
    notification-service   = { http = 8090, grpc = 0,    schema = "platform" }
    partner-portal-api     = { http = 8091, grpc = 0,    schema = "platform" }
    audit-ledger           = { http = 8092, grpc = 9092, schema = "platform" }
    analytics-pipeline     = { http = 8093, grpc = 0,    schema = "analytics" }
    reconciliation-service = { http = 8094, grpc = 0,    schema = "analytics" }
  }

  # عناوين الخدمات. الأسماء من §5 ولا تتغيّر بتغيّر المستدعي: fleet-service تقرأ
  # OF_GEO_GRPC_ADDR نفسه الذي تقرأه container-registry، وهذا ما يجعل ضبطها هنا مرّة واحدة
  # كافياً لكل من يظهر مستدعياً في §1.1.
  addresses = {
    OF_IDENTITY_GRPC_ADDR            = "identity-service.${local.cluster_domain}:9081"
    OF_IDENTITY_JWKS_URL             = "http://identity-service.${local.cluster_domain}:8081/.well-known/jwks.json"
    OF_CONTAINER_REGISTRY_GRPC_ADDR  = "container-registry.${local.cluster_domain}:9083"
    OF_GEO_GRPC_ADDR                 = "geo-service.${local.cluster_domain}:9086"
    OF_AUDIT_LEDGER_GRPC_ADDR        = "audit-ledger.${local.cluster_domain}:9092"
    OF_ROUTING_BASE_URL              = "http://routing-service.${local.cluster_domain}:8085"
    OF_CUSTOMS_BASE_URL              = "http://customs-service.${local.cluster_domain}:8087"
    OF_BILLING_BASE_URL              = "http://billing-service.${local.cluster_domain}:8088"
    OF_FLEET_BASE_URL                = "http://fleet-service.${local.cluster_domain}:8082"
    OF_DOCUMENT_BASE_URL             = "http://document-service.${local.cluster_domain}:8089"
    OF_ANALYTICS_BASE_URL            = "http://analytics-pipeline.${local.cluster_domain}:8093"
  }

  # ما تحتاجه كل خدمة من عناوين، مشتقّاً من عمود «يستدعي بالتزامن» في §1.1. لا نمرّر
  # العناوين كلها إلى الجميع: متغيّر لا تحتاجه الخدمة يجعل رسم الاعتماديات كذبة، ويسمح
  # لنداء متزامن جديد بأن يُضاف بلا مراجعة — وهو ما يغلق دورة في §1.1 دون أن ينتبه أحد.
  outbound = {
    identity-service       = []
    fleet-service          = ["OF_CONTAINER_REGISTRY_GRPC_ADDR", "OF_ROUTING_BASE_URL", "OF_GEO_GRPC_ADDR", "OF_DOCUMENT_BASE_URL"]
    container-registry     = ["OF_GEO_GRPC_ADDR", "OF_DOCUMENT_BASE_URL"]
    telemetry-ingest       = ["OF_CONTAINER_REGISTRY_GRPC_ADDR", "OF_GEO_GRPC_ADDR"]
    routing-service        = ["OF_GEO_GRPC_ADDR", "OF_CUSTOMS_BASE_URL"]
    geo-service            = []
    customs-service        = ["OF_DOCUMENT_BASE_URL", "OF_AUDIT_LEDGER_GRPC_ADDR"]
    billing-service        = ["OF_CUSTOMS_BASE_URL", "OF_FLEET_BASE_URL", "OF_DOCUMENT_BASE_URL"]
    document-service       = []
    notification-service   = ["OF_DOCUMENT_BASE_URL"]
    partner-portal-api     = ["OF_BILLING_BASE_URL", "OF_CUSTOMS_BASE_URL", "OF_CONTAINER_REGISTRY_GRPC_ADDR"]
    analytics-pipeline     = ["OF_CONTAINER_REGISTRY_GRPC_ADDR", "OF_GEO_GRPC_ADDR"]
    audit-ledger           = []
    reconciliation-service = ["OF_BILLING_BASE_URL", "OF_AUDIT_LEDGER_GRPC_ADDR", "OF_ANALYTICS_BASE_URL"]
  }
}

module "database" {
  source = "./modules/regional-database"

  region_code           = var.region_code
  environment           = var.environment
  identity_write_region = var.identity_write_region
  service_schemas       = { for name, cfg in local.services : name => cfg.schema }
}

module "topics" {
  source = "./modules/kafka-topics"

  region_code = var.region_code
  environment = var.environment
}

# مستودع خاص بكل خدمة لأسرارها. الخدمة تقرأ OF_DATABASE_URL من هنا لا من ConfigMap، لأن
# الرابط يحمل كلمة المرور ويحمل search_path للمخطّط المالك — والثاني مهمّ بقدر الأوّل:
# رابط بلا search_path يجعل الخدمة تكتب في public بصمت.
resource "kubernetes_secret" "service_database" {
  for_each = local.services

  metadata {
    name      = "${each.key}-database"
    namespace = "orbitalfreight"
  }

  data = {
    OF_DATABASE_URL = module.database.service_connection_urls[each.key]
  }

  type = "Opaque"
}

module "workload" {
  source   = "./modules/service-workload"
  for_each = local.services

  service_name = each.key
  http_port    = each.value.http
  grpc_port    = each.value.grpc
  replicas     = var.service_replicas[each.key]
  image        = "ghcr.io/orbitalfreight/${each.key}:${var.image_tag}"

  region_code = var.region_code
  environment = var.environment

  database_secret_name = kubernetes_secret.service_database[each.key].metadata[0].name

  # OF_KAFKA_CONSUMER_GROUP: لاحقة الإصدار جزء من الاسم عمداً. رفعها يجبر المجموعة على
  # قراءة الموضوع من أوّله، وهي الطريقة الوحيدة لإعادة تشغيل مستهلك بعد إصلاح خلل في منطقه.
  common_env = merge(
    {
      OF_ENVIRONMENT                  = var.environment
      OF_REGION_CODE                  = var.region_code
      OF_SERVICE_NAME                 = each.key
      OF_LOG_LEVEL                    = var.environment == "production" ? "info" : "debug"
      OF_LOG_FORMAT                   = var.environment == "local" ? "text" : "json"
      OF_HTTP_PORT                    = tostring(each.value.http)
      OF_DATABASE_MAX_CONNS           = "40"
      OF_DATABASE_STATEMENT_TIMEOUT_MS = "8000"
      OF_KAFKA_BROKERS                = var.kafka_brokers
      OF_KAFKA_CONSUMER_GROUP         = "${each.key}-v3"
      OF_OTEL_EXPORTER_ENDPOINT       = "http://otel-collector.${local.cluster_domain}:4317"
      OF_OTEL_SAMPLE_RATIO            = tostring(var.environment == "staging" ? 1.0 : var.otel_sample_ratio)
      OF_IDENTITY_JWKS_GRACE_SECONDS  = "300"
      OF_OUTBOX_RELAY_INTERVAL_MS     = "250"
      OF_SHUTDOWN_GRACE_SECONDS       = "25"
    },
    # OF_GRPC_PORT غير مضبوط على الخدمات بلا واجهة gRPC (§5.1). ضبطه بصفر ليس نفس الشيء:
    # الخدمة ستحاول الإصغاء عليه وتفشل.
    each.value.grpc == 0 ? {} : { OF_GRPC_PORT = tostring(each.value.grpc) },
    { for name in local.outbound[each.key] : name => local.addresses[name] },
    { OF_IDENTITY_GRPC_ADDR = local.addresses.OF_IDENTITY_GRPC_ADDR },
    { OF_IDENTITY_JWKS_URL  = local.addresses.OF_IDENTITY_JWKS_URL }
  )

  depends_on = [module.topics, module.database]
}

# ── إعدادات تخصّ خدمة واحدة ─────────────────────────────────────────────────────────────
# ما لا يعمّ الأربع عشرة يُضبط هنا صراحةً بدل حشره في common_env. الوضوح مقصود: قارئ
# يبحث عن مصدر OF_TELEMETRY_ALLOWED_REGIONS يجده في سطر واحد لا داخل دمج من ثلاث طبقات.

resource "kubernetes_config_map" "telemetry_rules" {
  metadata {
    name      = "telemetry-rules"
    namespace = "orbitalfreight"

    annotations = {
      "of.orbitalfreight/updated-at" = timestamp()
    }
  }

  # عتبات rule_code الثمانية. تُقرأ عند الإقلاع من OF_TELEMETRY_RULES_PATH، فتعديلها يحتاج
  # دورة جرابات — وهو ما تعتمد عليه incident/telemetry-alert-storm.sh حين تتراجع عنها.
  data = {
    "rules.yaml" = file("${path.module}/files/telemetry-rules.yaml")
  }
}

resource "kubernetes_config_map" "service_tuning" {
  metadata {
    name      = "service-tuning"
    namespace = "orbitalfreight"
  }

  data = {
    # telemetry-ingest: الدفعة لإقليم آخر تُرفض 403 ولا يُعاد توجيهها (§7 قاعدة 7).
    OF_TELEMETRY_ALLOWED_REGIONS        = var.region_code
    OF_TELEMETRY_BATCH_MAX_READINGS     = "5000"
    OF_TELEMETRY_SIGNATURE_REQUIRED     = tostring(var.environment != "local")
    OF_TELEMETRY_PUBLISH_SAMPLE_RATE    = "20"
    OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES = "15"
    OF_TELEMETRY_RULES_PATH             = "/etc/orbitalfreight/rules.yaml"

    # geo-service: ثلاثون ثانية هي عمر ذاكرة ResolveGeofence لكل أثر، وهي ما يمنع المعيّن أ
    # من حلّ السياج نفسه مرّتين في تعيين أسطول واحد.
    OF_GEO_FENCE_CACHE_TTL_SECONDS = "30"
    OF_GEO_MATRIX_MAX_POINTS       = "64"

    # customs-service: صفوف customs.tariff_schedules غير قابلة للتغيير، فذاكرة طويلة آمنة.
    OF_CUSTOMS_TARIFF_CACHE_TTL_SECONDS = "86400"
    OF_CUSTOMS_RETENTION_YEARS          = "10"

    OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES = "60"
    OF_LEDGER_HASH_ALGORITHM              = "sha256"

    OF_NOTIFY_MAX_ATTEMPTS = "8"   # يطابق قاعدة قائمة الرسائل الميّتة في §4.19
    OF_ANALYTICS_MV_REFRESH_CRON = "15 3 * * *"
  }
}

output "service_endpoints" {
  description = "عناوين الخدمات داخل العنقود كما تظهر في §1"
  value       = { for name, cfg in local.services : name => "http://${name}.${local.cluster_domain}:${cfg.http}" }
}

output "topic_names" {
  value = module.topics.topic_names
}
