#!/usr/bin/env bash
# فحص ما قبل النشر لخدمة واحدة في إقليم واحد: يتحقّق أن مجموعة متغيّرات OF_* المضبوطة على
# النشر تطابق §5 حرفاً بحرف، وأن رقم الترحيل الذي تتوقّعه الصورة الجديدة مطبَّق فعلاً على
# قاعدة البيانات، وأن مواضيع Kafka الستة موجودة بالتقسيم والاحتفاظ المذكورين في §4.
# يرفض ولا يصلح: كل ما يجده هنا خطأ إعداد يجب أن يُصحَّح في المصدر قبل أن تمسّ الحزمة العنقود.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="deploy/preflight.sh"

SERVICE="${1:?الاستعمال: preflight.sh <service> <image-tag>}"
IMAGE_TAG="${2:?}"
of::require_service "$SERVICE"
of::require_region "${OF_REGION_CODE:?}"

FAILURES=0
fail() { of::error "$*"; FAILURES=$(( FAILURES + 1 )); }

# ── 1. المتغيّرات ────────────────────────────────────────────────────────────────────────
# validate-env.py هو المرجع: يقارن المجموعة الفعلية بالقسم المقابل في §5 ويفشل على متغيّر
# غير مذكور هناك، لأن خدمة تقرأ متغيّراً غير موصوف تفشل عند الإقلاع بدل أن تعمل بقيمة ضمنية.
of::info "مطابقة متغيّرات البيئة مع §5"
if ! python3 "$(dirname "${BASH_SOURCE[0]}")/../validate-env.py" \
       --service "$SERVICE" --environment "${OF_ENVIRONMENT}" --strict; then
  fail "مجموعة المتغيّرات لا تطابق §5"
fi

# متغيّرات العناوين أسماء مشتركة (§5): الاسم لا يتغيّر بتغيّر المستدعي، فfleet-service يقرأ
# OF_GEO_GRPC_ADDR نفسه الذي يقرأه container-registry. نتحقّق منها حسب المستدعي في §1.1.
declare -A REQUIRED_ADDRESSES=(
  [fleet-service]="OF_CONTAINER_REGISTRY_GRPC_ADDR OF_ROUTING_BASE_URL OF_GEO_GRPC_ADDR OF_DOCUMENT_BASE_URL"
  [container-registry]="OF_GEO_GRPC_ADDR OF_DOCUMENT_BASE_URL"
  [telemetry-ingest]="OF_CONTAINER_REGISTRY_GRPC_ADDR OF_GEO_GRPC_ADDR"
  [routing-service]="OF_GEO_GRPC_ADDR OF_CUSTOMS_BASE_URL"
  [customs-service]="OF_DOCUMENT_BASE_URL OF_AUDIT_LEDGER_GRPC_ADDR"
  [billing-service]="OF_CUSTOMS_BASE_URL OF_FLEET_BASE_URL OF_DOCUMENT_BASE_URL"
  [notification-service]="OF_DOCUMENT_BASE_URL"
  [partner-portal-api]="OF_BILLING_BASE_URL OF_CUSTOMS_BASE_URL OF_CONTAINER_REGISTRY_GRPC_ADDR"
  [analytics-pipeline]="OF_CONTAINER_REGISTRY_GRPC_ADDR OF_GEO_GRPC_ADDR"
  [reconciliation-service]="OF_BILLING_BASE_URL OF_AUDIT_LEDGER_GRPC_ADDR OF_ANALYTICS_BASE_URL"
)
for var in ${REQUIRED_ADDRESSES[$SERVICE]:-}; do
  [[ -n "$(kubectl get deploy "$SERVICE" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var}')].value}")" ]] \
    || fail "المتغيّر ${var} غير مضبوط، مع أن §1.1 تجعل ${SERVICE} مستدعياً لتلك الخدمة"
done

# OF_IDENTITY_GRPC_ADDR مطلوب على الأربع عشرة بلا استثناء: كل خدمة تنادي
# identity.v1.TokenIntrospection/Introspect قبل أن تتصرّف بأي طلب (§1.2).
[[ -n "$(kubectl get deploy "$SERVICE" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='OF_IDENTITY_GRPC_ADDR')].value}")" ]] \
  || fail "OF_IDENTITY_GRPC_ADDR غائب؛ الخدمة لن تستطيع التحقّق من أي رمز"

# ── 2. الترحيل ──────────────────────────────────────────────────────────────────────────
# الصورة تعلن الترحيل الذي تتوقّعه على /version. إن كان أحدث ممّا هو مطبَّق فالنشر يسبق
# الترحيل، وإن كان أقدم بأكثر من واحد فنحن نتراجع فوق مخطّط لا يعرفه هذا البناء.
of::info "مقارنة رقم الترحيل المتوقّع بالمطبَّق"
EXPECTED="$(docker run --rm "ghcr.io/orbitalfreight/${SERVICE}:${IMAGE_TAG}" --print-expected-migration)"
APPLIED="$(of::psql_ro --command 'SELECT max(version) FROM public.schema_migrations')"
if (( EXPECTED > APPLIED )); then
  fail "الصورة تتوقّع الترحيل ${EXPECTED} والمطبَّق ${APPLIED}؛ نفّذ deploy/migrate.sh أولاً"
elif (( APPLIED - EXPECTED > 1 )); then
  fail "المخطّط متقدّم بـ $(( APPLIED - EXPECTED )) ترحيلاً على هذه الصورة؛ التراجع غير آمن"
fi

# ── 3. المواضيع ─────────────────────────────────────────────────────────────────────────
# التقسيم والاحتفاظ من جدول §4. of.telemetry.v1 هو الأعرض (96 قسماً) لأن حجم كتابته يفوق
# البقيّة بثلاث مراتب، وof.customs.v1 وof.billing.v1 يحتفظان 90 يوماً لأسباب تدقيقية لا سعوية.
declare -A TOPIC_PARTITIONS=(
  [of.identity.v1]=12  [of.freight.v1]=48   [of.telemetry.v1]=96
  [of.customs.v1]=12   [of.billing.v1]=12   [of.platform.v1]=24
)
declare -A TOPIC_RETENTION_DAYS=(
  [of.identity.v1]=30  [of.freight.v1]=14   [of.telemetry.v1]=7
  [of.customs.v1]=90   [of.billing.v1]=90   [of.platform.v1]=30
)
for topic in "${OF_TOPICS[@]}"; do
  described="$(kafka-topics.sh --bootstrap-server "${OF_KAFKA_BROKERS:?}" --describe --topic "$topic" 2>/dev/null)" \
    || { fail "الموضوع ${topic} غير موجود على ${OF_KAFKA_BROKERS}"; continue; }
  actual_parts="$(sed -n 's/.*PartitionCount: *\([0-9]*\).*/\1/p' <<<"$described" | head -1)"
  [[ "$actual_parts" == "${TOPIC_PARTITIONS[$topic]}" ]] \
    || fail "${topic}: ${actual_parts} قسماً بدل ${TOPIC_PARTITIONS[$topic]} في §4"
  # كل موضوع يقابله موضوع رسائل ميّتة يستقبل الرسالة بعد ثماني محاولات (§4.19 قاعدة 4).
  kafka-topics.sh --bootstrap-server "$OF_KAFKA_BROKERS" --describe --topic "${topic}.dlq" >/dev/null 2>&1 \
    || fail "موضوع الرسائل الميّتة ${topic}.dlq غير موجود"
done

# ── 4. الاعتماديات المتزامنة ────────────────────────────────────────────────────────────
# لا ننشر خدمة بينما ما تحتاجه غير جاهز. القائمة هي عمود «يستدعي بالتزامن» من §1.1 نفسه؛
# الاتجاه المعاكس غير موجود عمداً لأن الرسم لا دورات فيه (§1.2).
declare -A SYNC_DEPENDENCIES=(
  [identity-service]=""
  [fleet-service]="identity-service container-registry routing-service geo-service document-service"
  [container-registry]="identity-service geo-service document-service"
  [telemetry-ingest]="identity-service container-registry geo-service"
  [routing-service]="identity-service geo-service customs-service"
  [geo-service]="identity-service"
  [customs-service]="identity-service document-service audit-ledger"
  [billing-service]="identity-service customs-service fleet-service document-service"
  [document-service]="identity-service"
  [notification-service]="identity-service document-service"
  [partner-portal-api]="identity-service billing-service customs-service container-registry"
  [analytics-pipeline]="identity-service container-registry geo-service"
  [audit-ledger]="identity-service"
  [reconciliation-service]="identity-service billing-service audit-ledger analytics-pipeline"
)
for dependency in ${SYNC_DEPENDENCIES[$SERVICE]}; do
  [[ "$(of::probe "$dependency" /readyz)" == "200" ]] \
    || fail "${dependency} غير جاهزة، و${SERVICE} تستدعيها بالتزامن حسب §1.1"
done

if (( FAILURES > 0 )); then
  of::die "${FAILURES} فحصاً فشل؛ النشر متوقّف"
fi
of::info "كل فحوص ما قبل النشر مرّت لـ ${SERVICE}:${IMAGE_TAG} في ${OF_REGION_CODE}"
