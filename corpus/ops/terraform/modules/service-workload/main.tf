# قالب النشر الموحّد لأي خدمة من §1: Deployment وService وسياسة تعطّل وسياسة شبكة. الغرض أن
# تكون الأربع عشرة متطابقة في كل ما لا سبب لاختلافها فيه — المجسّات على /healthz و/readyz،
# مهلة الإنهاء مقابل OF_SHUTDOWN_GRACE_SECONDS، وحقن X-OF-Trace-Id من الحافة. ما يختلف فعلاً
# يأتي من المتغيّرات: المنافذ وعدد النسخ ومجموعة OF_* الخاصّة بالخدمة.

variable "service_name" {
  description = "الاسم كما في §1 حرفاً بحرف؛ يذهب إلى OF_SERVICE_NAME وإلى عمود producer"
  type        = string
}

variable "http_port"  { type = number }
variable "grpc_port"  { type = number }   # صفر = لا واجهة gRPC، فلا منفذ ولا مجسّ
variable "replicas"   { type = number }
variable "image"      { type = string }
variable "region_code" { type = string }
variable "environment" { type = string }
variable "database_secret_name" { type = string }
variable "common_env" { type = map(string) }

locals {
  # مهلة إنهاء الجراب أكبر دائماً من OF_SHUTDOWN_GRACE_SECONDS بعشر ثوانٍ. الترتيب مهمّ:
  # الخدمة تتوقّف عن قبول طلبات جديدة، تُفرِغ ما في يدها، تدع مُرحّل صندوق الصادر ينشر ما
  # كُتب للتوّ، ثم تخرج. جراب يُقتل قبل ذلك يترك رسائل في platform.outbox_messages لا تصل
  # إلى مستهلكيها حتى تُقلع نسخة أخرى وتلتقطها.
  shutdown_grace  = tonumber(lookup(var.common_env, "OF_SHUTDOWN_GRACE_SECONDS", "25"))
  termination_grace = local.shutdown_grace + 10

  labels = {
    "app"                            = var.service_name
    "of.orbitalfreight/region"       = var.region_code
    "of.orbitalfreight/environment"  = var.environment
  }
}

resource "kubernetes_deployment" "service" {
  metadata {
    name      = var.service_name
    namespace = "orbitalfreight"
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = var.service_name }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        # صفر غير متاح: كل خدمة هنا إمّا في مسار طلب حارّ أو تستهلك موضوعاً، وفقدان نسخة
        # أثناء الطرح يعني تراكماً فورياً على مجموعة الاستهلاك.
        max_surge       = 1
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = tostring(var.http_port)
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        termination_grace_period_seconds = local.termination_grace

        container {
          name  = var.service_name
          image = var.image

          port {
            name           = "http"
            container_port = var.http_port
          }

          dynamic "port" {
            for_each = var.grpc_port == 0 ? [] : [var.grpc_port]
            content {
              name           = "grpc"
              container_port = port.value
            }
          }

          dynamic "env" {
            for_each = var.common_env
            content {
              name  = env.key
              value = env.value
            }
          }

          # الرابط يحمل كلمة المرور، فيأتي من Secret لا من ConfigMap. باقي الضبط في
          # service-tuning مشترك ولا يضرّ ظهوره في وصف الجراب.
          env {
            name = "OF_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = var.database_secret_name
                key  = "OF_DATABASE_URL"
              }
            }
          }

          env_from {
            config_map_ref { name = "service-tuning" }
          }

          # /healthz لا يلمس قاعدة البيانات (§3.15). هذا هو الفرق كلّه: مجسّ حياة يتحقّق من
          # Postgres يقتل الأسطول بأكمله عند أول تعثّر في قاعدة البيانات بدل أن ينتظر تعافيها.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          # /readyz يتحقّق من قاعدة البيانات وKafka وidentity-service. سقوطه يُخرج الجراب من
          # الخدمة ولا يقتله، وهو التصرّف الصحيح حين تكون التبعية هي المتعطّلة لا نحن.
          readiness_probe {
            http_get {
              path = "/readyz"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 2
          }

          resources {
            requests = {
              # OF_DATABASE_MAX_CONNS محسوب لكل جراب لا لكل عنقود (§5.1)، فعدد النسخ يضربه.
              # زيادة النسخ من غير مراجعة سقف اتصالات Postgres هي كيف استهلكنا العنقود مرّة.
              cpu    = var.service_name == "telemetry-ingest" ? "1000m" : "250m"
              memory = var.service_name == "geo-service" ? "3Gi" : "512Mi"
            }
            limits = {
              cpu    = var.service_name == "telemetry-ingest" ? "3000m" : "1000m"
              # geo-service تُسقط الرسم الطرقي في الذاكرة من OF_GEO_ROAD_GRAPH_PATH، فحدّها
              # يقاس بحجم الرسم لا بحمل الطلبات.
              memory = var.service_name == "geo-service" ? "6Gi" : "1Gi"
            }
          }

          dynamic "volume_mount" {
            for_each = var.service_name == "telemetry-ingest" ? [1] : []
            content {
              name       = "telemetry-rules"
              mount_path = "/etc/orbitalfreight"
              read_only  = true
            }
          }
        }

        dynamic "volume" {
          for_each = var.service_name == "telemetry-ingest" ? [1] : []
          content {
            name = "telemetry-rules"
            config_map { name = "telemetry-rules" }
          }
        }

        # نشر النسخ على مناطق التوفّر. الإقليم إقامة بيانات لا تجزئة (§7 قاعدة 7)، فالتوزيع
        # يبقى داخل حدود الإقليم دائماً ولا يمتدّ إلى إقليم مجاور مهما كانت السعة هناك.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = var.service_name }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "service" {
  metadata {
    name      = var.service_name
    namespace = "orbitalfreight"
    labels    = local.labels
  }

  spec {
    selector = { app = var.service_name }

    port {
      name        = "http"
      port        = var.http_port
      target_port = "http"
    }

    dynamic "port" {
      for_each = var.grpc_port == 0 ? [] : [var.grpc_port]
      content {
        name        = "grpc"
        port        = port.value
        target_port = "grpc"
      }
    }
  }
}

# identity-service جذر الرسم: سقوطها يوقف كل تحقّق من الرموز بعد انقضاء
# OF_IDENTITY_JWKS_GRACE_SECONDS. لذلك حدّها الأدنى أعلى من غيرها.
resource "kubernetes_pod_disruption_budget_v1" "service" {
  metadata {
    name      = var.service_name
    namespace = "orbitalfreight"
  }

  spec {
    min_available = var.service_name == "identity-service" ? "75%" : "50%"
    selector {
      match_labels = { app = var.service_name }
    }
  }
}

output "cluster_url" {
  value = "http://${var.service_name}.orbitalfreight.svc.cluster.local:${var.http_port}"
}
