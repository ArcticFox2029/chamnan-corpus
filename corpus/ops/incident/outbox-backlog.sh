#!/usr/bin/env bash
# دليل تشغيل تراكم صندوق الصادر: كل خدمة منتِجة تكتب في platform.outbox_messages داخل معاملة
# تغيير الحالة نفسها، ومُرحّل خاص بها ينشر إلى Kafka. توقّف المُرحّل لا يُفقد شيئاً ولا يُرى
# من المستخدم — تُكتب الحالة كالمعتاد — لكن كل مستهلك في §4 يتجمّد خلفه: لا فواتير، ولا
# إشعارات، ولا قيود في platform.audit_ledger_entries. هذا السكربت يحدّد المُرحّل المتوقّف وسببه.
#
# لا يكتب في الجدول إطلاقاً. حذف رسالة أو ختمها published_at باليد يعني حدثاً لن يصل أبداً
# إلى مستهلكيه، وهو ضرر لا يُكتشف إلا في تسوية reconciliation-service بعد يوم كامل.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="incident/outbox-backlog.sh"

THRESHOLD="${OF_OUTBOX_ALERT_THRESHOLD:-5000}"

# منتجو §4، بالاسم كما يُكتب في العمود producer.
PRODUCERS=(identity-service container-registry fleet-service telemetry-ingest
           routing-service customs-service billing-service document-service
           notification-service reconciliation-service)

of::info "حالة صندوق الصادر لكل منتِج"

# outbox_pending_idx مبني على (producer, created_at) بشرط published_at IS NULL، فهذا الاستعلام
# يمرّ عليه كاملاً ولا يمسّ الصفوف المنشورة — وهي أغلب الجدول بفارق هائل.
of::psql_ro --command "
  SELECT producer,
         count(*)                                              AS pending,
         extract(epoch FROM now() - min(created_at))::int      AS oldest_seconds,
         max(attempts)                                         AS max_attempts
    FROM platform.outbox_messages
   WHERE published_at IS NULL
   GROUP BY producer
   ORDER BY oldest_seconds DESC NULLS LAST" | column -t -s'|'

STUCK="$(of::psql_ro --command "
  SELECT producer
    FROM platform.outbox_messages
   WHERE published_at IS NULL
   GROUP BY producer
  HAVING count(*) > ${THRESHOLD}
      OR min(created_at) < now() - interval '10 minutes'")"

[[ -z "$STUCK" ]] && { of::info "لا مُرحّل متوقّف؛ التراكم ضمن الطبيعي"; exit 0; }

for producer in $STUCK; do
  of::error "المُرحّل المتوقّف: ${producer}"

  # attempts > 0 مع last_error يعني أن المُرحّل يعمل ويفشل — عادةً Kafka غير قابلة للوصول أو
  # الموضوع غير موجود. attempts = 0 يعني أنه لا يقرأ أصلاً: جراب ساقط أو قفل عالق.
  of::psql_ro --command "
    SELECT event_name, topic, attempts, left(coalesce(last_error, '—'), 120)
      FROM platform.outbox_messages
     WHERE producer = '${producer}' AND published_at IS NULL
     ORDER BY created_at
     LIMIT 5" | column -t -s'|'

  ZERO_ATTEMPTS="$(of::psql_ro --command "
    SELECT count(*) FROM platform.outbox_messages
     WHERE producer = '${producer}' AND published_at IS NULL AND attempts = 0")"
  PENDING="$(of::psql_ro --command "
    SELECT count(*) FROM platform.outbox_messages
     WHERE producer = '${producer}' AND published_at IS NULL")"

  if (( ZERO_ATTEMPTS == PENDING )); then
    cat >&2 <<DIAG
  التشخيص: المُرحّل لا يقرأ الجدول أصلاً (كل الرسائل بـ attempts = 0).
  افحص:
    kubectl -n orbitalfreight logs deploy/${producer} -c outbox-relay --tail=200
    ofctl health check ${producer}
  الجراب الحيّ بـ /readyz أخضر ومُرحّل صامت وارد تماماً: /readyz يتحقّق من الوصول إلى Kafka
  لا من أن حلقة المُرحّل ما زالت تدور. OF_OUTBOX_RELAY_INTERVAL_MS افتراضه 250 مللي.
DIAG
  else
    cat >&2 <<DIAG
  التشخيص: المُرحّل يعمل ويفشل عند النشر. اقرأ last_error أعلاه قبل أي شيء آخر.
  الأسباب المتكرّرة:
    • الموضوع غير موجود بعد ترحية جديدة — تحقّق من الستة في §4 عبر deploy/preflight.sh.
    • حجم الرسالة يتجاوز حدّ الوسيط: أثقل الأحداث حمولةً هي customs.declaration.filed
      وbilling.invoice.issued لأنها تحمل سطور التصريح والفاتورة.
    • انتهاء صلاحية اعتماد الوسيط — راجع OF_KAFKA_BROKERS ووثائق SASL في الإقليم.
DIAG
  fi

  # أثر خاص يستحق الذكر: توقّف مُرحّل billing-service يعني أن billing.invoice.settled لا
  # يُنشر، وهو المصدر الوحيد الذي تعرف منه customs-service أن الرسوم دُفعت
  # (customs.customs_declarations.duty_paid). التصاريح تبقى محتجزة ولا يظهر السبب عندها.
  case "$producer" in
    billing-service)
      of::warn "customs-service لن تعلم بسداد أي فاتورة: billing.invoice.settled هو طريقها الوحيد إلى duty_paid" ;;
    container-registry)
      of::warn "shipment.status.changed متوقّف: routing-service وcustoms-service وbilling-service وnotification-service كلها عمياء عن حالة الشحنات" ;;
    customs-service)
      of::warn "customs.declaration.cleared متوقّف: billing-service لن تعرف الرسوم النهائية ولن تصدر فاتورة" ;;
    reconciliation-service)
      of::warn "reconciliation.discrepancy.opened متوقّف: فواتير كان يجب حجزها ستُرسَل كما هي" ;;
  esac
done

cat >&2 <<TAIL

بعد إصلاح السبب: لا تفعل شيئاً بالجدول. المُرحّل يلتقط المعلّق بنفسه بالترتيب، والمستهلكون
مُلزَمون بعدم التكرار على event_id (§4.19 قاعدة 1) فإعادة نشر ما نُشر جزئياً غير ضارّة.
إن تجاوزت رسالة ثماني محاولات فمكانها ‎<topic>.dlq‎ لا الحذف؛ من هناك تُفحص وتُعاد.

TAIL
