#!/usr/bin/env bash
# دليل تشغيل «عاصفة تنبيهات»: يُستدعى حين ترتفع telemetry.alert.raised فوق المعتاد بمراتب.
# مهمّته الأولى ليست إغلاق التنبيهات بل الفرز — هل العطل في المستشعرات، أم في بوّابة عطبت
# فأرسلت قراءة واحدة سيّئة عن كل حاوياتها، أم في ملف عتبات OF_TELEMETRY_RULES_PATH نُشر خطأً؟
# الفرق مهمّ: الأول حادثة ميدانية، والثاني والثالث نتراجع عنهما ولا نغلق شيئاً باليد.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="incident/telemetry-alert-storm.sh"

WINDOW_MINUTES="${1:-30}"
of::require_region "${OF_REGION_CODE:?}"

of::info "فرز تنبيهات آخر ${WINDOW_MINUTES} دقيقة في ${OF_REGION_CODE}"

# ── 1. التوزيع على القواعد ──────────────────────────────────────────────────────────────
# ثماني قواعد فقط في CHECK على telemetry.telemetry_alerts.rule_code. تركّز واحدة منها بنسبة
# ساحقة يعني عتبة لا ظاهرة: حمولة مبرّدة حقيقية تنتج مزيجاً من temp_excursion_high وdoor_open_in_transit.
of::info "التوزيع على rule_code:"
ofctl alert list --region="$OF_REGION_CODE" --limit=200 --format=json \
  | jq -r '.items[] | .rule_code' | sort | uniq -c | sort -rn | tee /tmp/of-alert-rules.txt >&2

TOP_RULE="$(awk 'NR==1 {print $2}' /tmp/of-alert-rules.txt)"
TOP_COUNT="$(awk 'NR==1 {print $1}' /tmp/of-alert-rules.txt)"
TOTAL="$(awk '{s+=$1} END {print s}' /tmp/of-alert-rules.txt)"

# ── 2. هل هي بوّابة واحدة؟ ──────────────────────────────────────────────────────────────
# alert لا يحمل gateway_id، لكن first_reading_id يحمله عبر telemetry.telemetry_readings.
# بوّابة واحدة وراء أغلب التنبيهات = عطل عتاد أو برمجية ثابتة، لا سلسلة تبريد.
of::info "أكثر البوّابات ظهوراً خلف تنبيهات النافذة:"
of::psql_ro --command "
  SELECT r.gateway_id, g.serial, g.firmware_version, count(*) AS alerts
    FROM telemetry.telemetry_alerts a
    JOIN telemetry.telemetry_readings r
      ON r.reading_id = a.first_reading_id
     AND r.region_code = '${OF_REGION_CODE}'
    JOIN telemetry.device_gateways g ON g.gateway_id = r.gateway_id
   WHERE a.opened_at > now() - interval '${WINDOW_MINUTES} minutes'
   GROUP BY 1, 2, 3
   ORDER BY alerts DESC
   LIMIT 10"

# ── 3. هل نُشرت عتبات جديدة؟ ────────────────────────────────────────────────────────────
# ملف القواعد يُركَّب من ConfigMap. تغيّره قبل بداية العاصفة بدقائق هو التفسير الأرجح، وهو
# أيضاً أرخص شيء نتراجع عنه: تراجع الConfigMap لا يمسّ بيانات ولا يحتاج نافذة صيانة.
RULES_CHANGED_AT="$(kubectl -n orbitalfreight get configmap telemetry-rules \
                      -o jsonpath='{.metadata.annotations.of\.orbitalfreight/updated-at}')"
of::info "آخر تعديل على عتبات telemetry-rules: ${RULES_CHANGED_AT:-غير مسجَّل}"

# ── 4. الأثر على الشحنات ────────────────────────────────────────────────────────────────
# container-registry هي التي تقلب الشحنة إلى at_risk، وذلك باستهلاكها telemetry.alert.raised
# (§4.9) لا بنداء متزامن من telemetry-ingest — الحافة الوحيدة التي تكسر الدورة بين الخدمتين.
# العتبة التي تحكم القلب هي OF_FREIGHT_AUTO_AT_RISK_SEVERITY، فتنبيه خطورته 2 لا يقلب شيئاً.
# نعدّ من قراءة of_analytics_ro لأن §3.3 لا تعرض سرداً للشحنات: القراءة الفردية بالمعرّف فقط.
AT_RISK="$(of::psql_ro --command "
  SELECT count(*) FROM freight.shipments
   WHERE status = 'at_risk' AND region_code = '${OF_REGION_CODE}'")"
of::info "شحنات في at_risk الآن: ${AT_RISK}"

if (( TOP_COUNT * 100 / TOTAL > 80 )); then
  cat >&2 <<TRIAGE

الحكم: ${TOP_COUNT} من ${TOTAL} تنبيهاً على قاعدة واحدة (${TOP_RULE}) — هذه عتبة لا ظاهرة.

الخطوات:
  1. تراجع عن ConfigMap العتبات:
       kubectl -n orbitalfreight rollout undo deploy/telemetry-ingest
     العتبات تُقرأ من OF_TELEMETRY_RULES_PATH عند الإقلاع، فالتراجع يحتاج دورة جرابات كاملة.
  2. لا تغلق التنبيهات المفتوحة يدوياً قبل ذلك. الإغلاق عبر
       POST /v1/alerts/{alert_id}/close
     لا يعيد الشحنة من at_risk: تلك رحلة منفصلة عبر
       PATCH /v1/shipments/{shipment_id}/status
     على container-registry، وهي المسار القانوني الوحيد للانتقال بين الحالات.
  3. أبلغ المناوب أن notification-service قد أرسل بالفعل لكل تنبيه: هو مستهلك
     telemetry.alert.raised أيضاً، ولا سبيل لسحب ما أُرسل.

TRIAGE
else
  cat >&2 <<TRIAGE

الحكم: التنبيهات موزّعة على قواعد متعدّدة — رجّح ظاهرة ميدانية حقيقية أو عطل بوّابة.

الخطوات:
  1. راجع الجدول أعلاه: بوّابة واحدة بأكثر من ثلث التنبيهات تعني عتاداً، لا حمولة.
  2. اسحب منحنى القراءات للحاوية الأسوأ قبل أن تقرّر:
       ofctl alert readings <container_id> --since-minutes=${WINDOW_MINUTES}
     القراءات تأتي من قسم إقليمك وحده؛ حاوية في latam-br لا تُقرأ من هنا (§7 قاعدة 7).
  3. أقرّ التنبيهات التي تولّى المشغّل الميداني أمرها كي تخرج من قائمة المناوب:
       ofctl alert ack <alert_id>
     الإقرار يختم acknowledged_by/acknowledged_at ولا يغلق شيئاً.

TRIAGE
fi

# البوّابة الصامتة تُعلَن مرّتين بطريقتين مختلفتين: حدث gateway.heartbeat.missed يذهب إلى
# notification-service وanalytics-pipeline، وتنبيه بقاعدة gateway_silent يفتح في
# telemetry.telemetry_alerts. لذلك انقطاع شبكة مستودع واحد يظهر أعلاه كأنه عاصفة تنبيهات،
# وهذا العدّ هو ما يميّز الحالتين قبل أن يُستدعى أحد إلى الميدان بلا سبب.
SILENT="$(of::psql_ro --command "
  SELECT count(*) FROM telemetry.device_gateways
   WHERE region_code = '${OF_REGION_CODE}'
     AND decommissioned_at IS NULL
     AND last_heartbeat_at < now() - interval '${OF_TELEMETRY_HEARTBEAT_TIMEOUT_MINUTES:-15} minutes'")"
of::warn "بوّابات صامتة في الإقليم: ${SILENT} — قارنها بعدد تنبيهات gateway_silent أعلاه"
