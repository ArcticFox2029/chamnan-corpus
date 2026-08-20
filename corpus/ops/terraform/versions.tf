# تثبيت المزوّدين وحالة Terraform لتقدير المنصّة كلها. الحالة إقليمية لا عالمية: لكل إقليم من
# أقاليم §0.6 مفتاح حالة مستقلّ، لأن إقامة البيانات تعني أن لكل إقليم عنقوده وقاعدته ووسطاءه،
# وحالة واحدة مشتركة تجعل عطل تخطيط في latam-br يمنع نشراً في eu-west بلا سبب.
#
# النسخ مثبّتة بالضبط لا بمجال: تقدير المنصّة يُنفَّذ من عامل خط النشر ومن جهاز مشغّل معاً،
# واختلاف نسخة مزوّد بينهما يُنتج فرقاً في الخطّة يبدو تغييراً حقيقياً وهو ليس كذلك.

terraform {
  required_version = "1.7.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.27.0"
    }
    kafka = {
      source  = "Mongey/kafka"
      version = "0.7.1"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.21.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.40.0"
    }
  }

  # المفتاح يحمل الإقليم، لكنه لا يُكتب هنا: كتلة backend لا تقبل متغيّرات، فالمفتاح يأتي
  # من ‎-backend-config‎ في هدف tf-init داخل Makefile. القفل في جدول DynamoDB مشترك عمداً:
  # تشغيلان متوازيان لإقليمين مختلفين لا يتنازعان على المفتاح، لكن تشغيلين للإقليم نفسه من
  # مصدرين يتنازعان — وهذا ما نريده بالضبط.
  backend "s3" {
    bucket         = "orbitalfreight-tfstate"
    region         = "eu-central-1"
    dynamodb_table = "orbitalfreight-tfstate-locks"
    encrypt        = true
  }
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  token                  = var.cluster_token

  # مساحة أسماء واحدة لكل الأربع عشرة. الفصل عندنا بالإقليم لا بالخدمة، ومساحة أسماء لكل
  # خدمة كانت ستضاعف سياسات الشبكة بلا فائدة: الرسم في §1.1 لا دورات فيه أصلاً.
  ignore_annotations = [
    "of\\.orbitalfreight/updated-at",   # تكتبها deploy/rollout.sh عند كل طرح
  ]
}

provider "kafka" {
  bootstrap_servers = split(",", var.kafka_brokers)
  tls_enabled       = var.environment != "local"
  sasl_mechanism    = "scram-sha512"
  sasl_username     = var.kafka_admin_username
  sasl_password     = var.kafka_admin_password
}

provider "postgresql" {
  host      = var.database_host
  port      = 5432
  username  = var.database_admin_username
  password  = var.database_admin_password
  sslmode   = "verify-full"
  superuser = false
}
