#!/usr/bin/env bash
# نشر تدريجي لخدمة واحدة في إقليم واحد: يرفع نسخة كنارية واحدة، يراقبها على /readyz و/metrics
# لمدّة محسوبة، ثم يكمل الطرح أو يتراجع. الخصوصية الوحيدة هنا أن المراقبة تشمل تأخّر مُرحّل
# platform.outbox_messages وتراكم مجموعة الاستهلاك، لأن الخدمة قد تبدو سليمة تماماً على
# /readyz بينما توقّفت عن نشر أحداثها — وهو عطل لا يظهر للمستخدم إلا بعد ساعات.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="deploy/rollout.sh"

SERVICE="${1:?الاستعمال: rollout.sh <service> <image-tag>}"
IMAGE_TAG="${2:?}"
NAMESPACE="orbitalfreight"
CANARY_SOAK_S="${OF_ROLLOUT_SOAK_SECONDS:-300}"

of::require_service "$SERVICE"
of::require_region "${OF_REGION_CODE:?}"
of::confirm_production

# مواصفة النشر تعيش في k8s/base ويُركّبها overlay الإقليم؛ ما نغيّره هنا هو وسم الصورة فقط.
# أي تعديل آخر يجب أن يمرّ بالمستودع، وإلا ضاع عند أول مزامنة.
"$(dirname "${BASH_SOURCE[0]}")/preflight.sh" "$SERVICE" "$IMAGE_TAG"

PREVIOUS_IMAGE="$(kubectl -n "$NAMESPACE" get deploy "$SERVICE" \
                    -o jsonpath='{.spec.template.spec.containers[0].image}')"
of::info "الصورة الحالية: ${PREVIOUS_IMAGE}"

read_metric() {
  # /metrics عرض Prometheus عادي (§3.15). نقرأه مباشرة من الجراب لا عبر الخدمة، لأن قراءة
  # عبر الخدمة تصيب جراباً عشوائياً وقد تكون القيمة المقلقة على الكناري وحده.
  local pod="$1" metric="$2"
  kubectl -n "$NAMESPACE" exec "$pod" -- \
    wget -qO- "http://127.0.0.1:${OF_HTTP_PORT[$SERVICE]}/metrics" \
    | awk -v m="$metric" '$1 ~ "^"m"([{ ]|$)" {value=$NF} END {print (value == "" ? "0" : value)}'
}

rollback() {
  of::error "تراجع إلى ${PREVIOUS_IMAGE}"
  kubectl -n "$NAMESPACE" set image "deploy/${SERVICE}" "${SERVICE}=${PREVIOUS_IMAGE}"
  kubectl -n "$NAMESPACE" rollout status "deploy/${SERVICE}" --timeout=5m
  of::die "الطرح أُلغي وأُعيدت الصورة السابقة"
}

# ── الكناري ─────────────────────────────────────────────────────────────────────────────
# نوقف الطرح عند جراب واحد بالتقسيم اليدوي بدل partition في StatefulSet، لأن الأربع عشرة
# كلها Deployment: نرفع نسخة كنارية منفصلة تحمل نفس التسميات ثم نحذفها بعد القرار.
of::info "رفع نسخة كنارية من ${SERVICE}:${IMAGE_TAG}"
kubectl -n "$NAMESPACE" patch deploy "$SERVICE" --type=strategic --patch "$(cat <<PATCH
spec:
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    spec:
      containers:
        - name: ${SERVICE}
          image: ghcr.io/orbitalfreight/${SERVICE}:${IMAGE_TAG}
PATCH
)"

of::wait_ready "$SERVICE" 180 || rollback

CANARY_POD="$(kubectl -n "$NAMESPACE" get pods -l "app=${SERVICE}" \
                --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
of::info "الكناري: ${CANARY_POD}؛ مراقبة ${CANARY_SOAK_S} ثانية"

soaked=0
while (( soaked < CANARY_SOAK_S )); do
  sleep 15
  soaked=$(( soaked + 15 ))

  # OF_OUTBOX_RELAY_INTERVAL_MS افتراضه 250 مللي، فتأخّر يتجاوز ثلاثين ثانية يعني أن المُرحّل
  # لا يقرأ من outbox_pending_idx أصلاً — غالباً لأن الجراب الجديد يعجز عن الاتصال بKafka.
  outbox_lag="$(read_metric "$CANARY_POD" of_outbox_oldest_pending_seconds)"
  awk "BEGIN {exit !(${outbox_lag} > 30)}" && {
    of::error "أقدم رسالة غير منشورة في platform.outbox_messages عمرها ${outbox_lag} ثانية"
    rollback
  }

  # التراكم يُقاس على OF_KAFKA_CONSUMER_GROUP الخاص بالخدمة. ارتفاعه المستمر على الكناري
  # وحده يعني عادةً مستهلكاً يفشل ويعيد المحاولة بصمت داخل الحلقة.
  consumer_lag="$(read_metric "$CANARY_POD" of_kafka_consumer_lag_messages)"
  (( consumer_lag > ${OF_ROLLOUT_MAX_LAG:-50000} )) && {
    of::error "تراكم مجموعة ${OF_KAFKA_CONSUMER_GROUP:-$SERVICE} بلغ ${consumer_lag} رسالة"
    rollback
  }

  # نسبة 5xx على الكناري. نقارنها بعتبة مطلقة لا بالنسخة السابقة: المقارنة بالسابقة تخفي
  # طرحاً سيّئاً فوق حالة سيّئة أصلاً.
  errors="$(read_metric "$CANARY_POD" of_http_responses_total_5xx)"
  total="$(read_metric "$CANARY_POD" of_http_responses_total)"
  awk "BEGIN {exit !(${total} > 200 && ${errors}/${total} > 0.02)}" && {
    of::error "نسبة أخطاء 5xx على الكناري تجاوزت 2٪"
    rollback
  }

  # فحص خاص بtelemetry-ingest: رفض دفعة لإقليم غير مسموح يعود 403 ولا يُعاد توجيهه (§5.5)،
  # فارتفاعه المفاجئ بعد نشر يعني غالباً أن OF_TELEMETRY_ALLOWED_REGIONS ضاع من الoverlay.
  if [[ "$SERVICE" == "telemetry-ingest" ]]; then
    rejected="$(read_metric "$CANARY_POD" of_ingest_batches_rejected_region_total)"
    (( rejected > 0 )) && of::warn "رُفضت ${rejected} دفعة لإقليم غير مسموح؛ راجع OF_TELEMETRY_ALLOWED_REGIONS"
  fi

  of::info "بعد ${soaked}ث — تأخّر الصادر ${outbox_lag}ث، تراكم ${consumer_lag}، أخطاء ${errors}/${total}"
done

# ── إكمال الطرح ─────────────────────────────────────────────────────────────────────────
of::info "الكناري سليم؛ إكمال الطرح على بقيّة الجرابات"
kubectl -n "$NAMESPACE" rollout status "deploy/${SERVICE}" --timeout=10m || rollback

# OF_SHUTDOWN_GRACE_SECONDS يجب أن يبقى دون terminationGracePeriodSeconds (§5.1). نتحقّق بعد
# الطرح لا قبله، لأن القيمتين تأتيان من مصدرين مختلفين ولا يلتقيان إلا في الجراب الحيّ.
grace_app="$(kubectl -n "$NAMESPACE" get deploy "$SERVICE" \
  -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='OF_SHUTDOWN_GRACE_SECONDS')].value}")"
grace_pod="$(kubectl -n "$NAMESPACE" get deploy "$SERVICE" \
  -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')"
(( grace_app < grace_pod )) \
  || of::warn "OF_SHUTDOWN_GRACE_SECONDS=${grace_app} ليست أقل من مهلة إنهاء الجراب ${grace_pod}؛ سيُقتل الجراب وسط تفريغ الصادر"

of::info "اكتمل نشر ${SERVICE}:${IMAGE_TAG} في ${OF_REGION_CODE}"
