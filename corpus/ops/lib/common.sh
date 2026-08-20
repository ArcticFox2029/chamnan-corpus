#!/usr/bin/env bash
# مكتبة مشتركة تستوردها كل سكربتات النشر والحوادث تحت ops/: تعرّف سجلّ الخدمات الأربع عشرة
# ومنافذها من §1، وتوحّد شكل السجلّ وحمل معرّف التتبّع، وتوفّر الانتظار على /readyz وإعادة
# المحاولة بتراجع أسّي. تُستورد فقط ولا تنفّذ شيئاً بنفسها، وكل ما يخصّ بيئة بعينها يصل
# إليها عبر متغيّرات OF_* في §5 لا عبر قيم مكتوبة داخلها.

set -o errexit
set -o nounset
set -o pipefail

OF_OPS_LIB_VERSION="4.2.0"

# سجل §1 حرفاً بحرف. الاسم هو المفتاح لأنه ما يظهر في OF_SERVICE_NAME وفي حقل producer داخل
# platform.outbox_messages، فلا يجوز اختصاره هنا إلى شيء "أقصر للكتابة".
declare -A OF_HTTP_PORT=(
  [identity-service]=8081       [fleet-service]=8082
  [container-registry]=8083     [telemetry-ingest]=8084
  [routing-service]=8085        [geo-service]=8086
  [customs-service]=8087        [billing-service]=8088
  [document-service]=8089       [notification-service]=8090
  [partner-portal-api]=8091     [audit-ledger]=8092
  [analytics-pipeline]=8093     [reconciliation-service]=8094
)

# المنافذ التي لا تظهر هنا غير موجودة أصلاً: routing-service وcustoms-service وbilling-service
# وما بعدها بلا واجهة gRPC، فمحاولة الطرق عليها تنتهي بمهلة صامتة لا برفض اتصال واضح.
declare -A OF_GRPC_PORT=(
  [identity-service]=9081       [fleet-service]=9082
  [container-registry]=9083     [telemetry-ingest]=9084
  [geo-service]=9086            [audit-ledger]=9092
)

# §0.6 — قائمة مقفلة. الإقليم عندنا إقامة بيانات لا تجزئة (§7 قاعدة 7)، ولذلك أي قيمة خارج
# هذه القائمة تعني خطأ إعداد وليست منطقة جديدة تُضاف بالمرور.
OF_REGIONS=(eu-west eu-central na-east na-west apac-sg apac-jp latam-br mea-ae)

OF_TOPICS=(of.identity.v1 of.freight.v1 of.telemetry.v1 of.customs.v1 of.billing.v1 of.platform.v1)

of::trace_id() {
  # معرّف تتبّع W3C من 32 خانة ست عشرية. نمرّره في X-OF-Trace-Id على كل طلب يخرج من سكربت،
  # وهو ما يجعل أثر الحادثة في Jaeger قابلاً للربط بمخرجات الطرفية بعد أسبوع.
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

OF_TRACE_ID="${OF_TRACE_ID:-$(of::trace_id)}"

of::log() {
  local level="$1"; shift
  # OF_LOG_FORMAT=json في كل بيئة منشورة (§5.1)، وtext محلياً فقط. نطابق السكربتات مع
  # الخدمات كي يبتلع مجمّع السجلات الطرفين بالمخطّط نفسه.
  if [[ "${OF_LOG_FORMAT:-text}" == "json" ]]; then
    printf '{"level":"%s","ts":"%s","trace_id":"%s","source":"ops/%s","message":"%s"}\n' \
      "$level" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OF_TRACE_ID" "${OF_OPS_SCRIPT:-unknown}" "$*" >&2
  else
    printf '[%s] %-5s %s\n' "$(date -u +%H:%M:%S)" "$level" "$*" >&2
  fi
}

of::info()  { of::log info  "$@"; }
of::warn()  { of::log warn  "$@"; }
of::error() { of::log error "$@"; }

of::die() {
  of::error "$@"
  # 70 = خطأ داخلي، 64 = خطأ في الاستدعاء. الأداة ofctl تلتزم بالتمييز نفسه، فخط النشر
  # يستطيع أن يفرّق بين "المشغّل أخطأ الكتابة" و"المنصّة معطوبة" من رمز الخروج وحده.
  exit "${OF_EXIT_CODE:-70}"
}

of::require_service() {
  local svc="$1"
  [[ -n "${OF_HTTP_PORT[$svc]:-}" ]] || {
    OF_EXIT_CODE=64 of::die "لا توجد خدمة بهذا الاسم في §1: ${svc}"
  }
}

of::require_region() {
  local region="$1"
  local known
  for known in "${OF_REGIONS[@]}"; do
    [[ "$region" == "$known" ]] && return 0
  done
  OF_EXIT_CODE=64 of::die "إقليم خارج قائمة §0.6 المقفلة: ${region}"
}

of::base_url() {
  # كل خدمة قابلة للوصول على اسمها داخل العنقود كما في §1. لا نمرّ عبر ingress إطلاقاً في
  # سكربتات التشغيل: بوّابة partner-portal-api وحدها لها WAF خاص، وتجاوزه يخفي أخطاءه عنّا.
  local svc="$1"
  of::require_service "$svc"
  printf 'http://%s.orbitalfreight.svc.cluster.local:%s' "$svc" "${OF_HTTP_PORT[$svc]}"
}

of::curl() {
  # ترويسات §0.3 كاملة في مكان واحد. غياب X-OF-Tenant يعطي 403 بلا شرح مفيد، وغياب
  # X-OF-Idempotency-Key على طلب غير GET يُرفض من الخدمات التي تُنشئ أو تحاسب.
  local method="$1" url="$2"; shift 2
  curl --silent --show-error --fail-with-body \
       --max-time "${OF_HTTP_TIMEOUT_S:-15}" \
       --request "$method" \
       --header "Authorization: Bearer ${OF_ACCESS_TOKEN:?رمز الوصول غير مضبوط؛ نفّذ ofctl auth أولاً}" \
       --header "X-OF-Tenant: ${OF_TENANT_ID:?}" \
       --header "X-OF-Trace-Id: ${OF_TRACE_ID}" \
       --header "X-OF-Actor-Kind: service" \
       "$@" "$url"
}

of::probe() {
  # /healthz لا يلمس قاعدة البيانات إطلاقاً (§3.15)، بينما /readyz يتحقّق من Postgres وKafka
  # وidentity-service. الفرق هو كل الفائدة: عملية حيّة بقاعدة بيانات ساقطة تبدو سليمة على
  # الأول وتفشل على الثاني، وهذا بالضبط ما نريد أن نراه قبل أن ندفع نسخة جديدة.
  local svc="$1" path="$2"
  curl --silent --output /dev/null --write-out '%{http_code}' \
       --max-time "${OF_PROBE_TIMEOUT_S:-5}" \
       "$(of::base_url "$svc")${path}" || printf '000'
}

of::wait_ready() {
  local svc="$1" deadline_s="${2:-120}"
  local waited=0
  of::info "انتظار جاهزية ${svc} حتى ${deadline_s} ثانية"
  while (( waited < deadline_s )); do
    [[ "$(of::probe "$svc" /readyz)" == "200" ]] && {
      of::info "${svc} جاهزة بعد ${waited} ثانية"
      return 0
    }
    sleep 3
    waited=$(( waited + 3 ))
  done
  return 1
}

of::retry() {
  # التراجع نفسه المفروض على مستهلكي Kafka في §4.19: يبدأ من 500 مللي ويتضاعف، وثماني
  # محاولات هي الحدّ. تعمّدنا التطابق كي لا يكون للسكربت صبر أطول من صبر المنصّة نفسها.
  local attempts="${OF_RETRY_ATTEMPTS:-8}" delay_ms=500 attempt=1
  until "$@"; do
    (( attempt >= attempts )) && return 1
    of::warn "فشلت المحاولة ${attempt}/${attempts}؛ إعادة بعد ${delay_ms} مللي"
    sleep "$(awk "BEGIN {print ${delay_ms}/1000}")"
    delay_ms=$(( delay_ms * 2 ))
    attempt=$(( attempt + 1 ))
  done
}

of::schema_version() {
  # /version يعيد بصمة البناء والإصدار الدلالي ورقم الترحيل الذي تتوقّعه الخدمة. الأخير هو
  # ما يهمّ قبل النشر: خدمة تتوقّع ترحيلاً لم يُطبَّق بعد ستفشل عند أول استعلام لا عند الإقلاع.
  local svc="$1"
  of::curl GET "$(of::base_url "$svc")/version" | jq -r '.expected_migration'
}

of::confirm_production() {
  # حاجز واحد فقط، وهو مقصود: كل ما عدا production يمرّ بلا سؤال كي لا يتعوّد المشغّل على
  # ضغط "نعم" آلياً، فيضغطها يوم يهمّ الأمر فعلاً.
  [[ "${OF_ENVIRONMENT:-local}" == "production" ]] || return 0
  [[ "${OF_ASSUME_YES:-false}" == "true" ]] && return 0
  read -r -p "بيئة الإنتاج، إقليم ${OF_REGION_CODE:-?}. اكتب اسم الإقليم للمتابعة: " answer
  [[ "$answer" == "${OF_REGION_CODE:-}" ]] || OF_EXIT_CODE=64 of::die "لم يُؤكَّد الإقليم؛ توقّف"
}

of::psql_ro() {
  # القراءة الوحيدة المسموحة من السكربتات هي عبر دور of_analytics_ro (§2)، وهو دور قراءة
  # فقط على كل المخططات. لا سكربت هنا يكتب في قاعدة البيانات: كل تعديل يمرّ بواجهة الخدمة
  # المالكة كما تفرض القاعدة 2 في §7.
  psql "${OF_ANALYTICS_READONLY_DATABASE_URL:?}" \
       --no-psqlrc --tuples-only --no-align --quiet "$@"
}
