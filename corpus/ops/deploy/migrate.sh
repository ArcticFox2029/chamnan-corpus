#!/usr/bin/env bash
# تطبيق ترحيلات المخطّط من db/ على عنقود Postgres الواحد الذي تتقاسمه المخططات العشرة.
# المخطّطات لخدمات مختلفة لكن قاعدة البيانات واحدة، فالترحيل عملية منصّة لا عملية فريق:
# يأخذ قفلاً استشارياً واحداً، يطبّق بالترتيب، ويتوقّف عند أول فشل من دون تنفيذ ما بعده.
# لا يلمس شيئاً في مخطّط analytics: ذلك المخطّط مشتقّ بالكامل وتعيد analytics-pipeline بناءه.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="deploy/migrate.sh"

MIGRATIONS_DIR="${OF_MIGRATIONS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../db/migrations}"
TARGET_VERSION="${1:-latest}"

# 8274 رقم اعتباطي ثابت. المهم أن يكون هو نفسه في كل مكان يطبّق ترحيلاً: تشغيلان متوازيان
# من خطّي نشر لإقليمين مختلفين يصلان إلى القاعدة نفسها في eu-central حيث تُكتب identity.
readonly ADVISORY_LOCK_KEY=8274

of::require_region "${OF_REGION_CODE:?}"
of::confirm_production

# مخطّط identity يُكتب في eu-central وحده ويُنسخ إلى بقيّة الأقاليم (§2). تطبيق ترحيل يمسّه
# من إقليم آخر ينجح محلياً ثم يتضارب مع النسخة الواردة، وهو أسوأ من الفشل الصريح.
touches_identity() { grep -qiE '\bidentity\.[a-z_]+' "$1"; }

psql_rw() {
  psql "${OF_DATABASE_URL:?}" --no-psqlrc --set ON_ERROR_STOP=1 --quiet "$@"
}

applied_version() {
  psql_rw --tuples-only --no-align \
    --command 'SELECT coalesce(max(version), 0) FROM public.schema_migrations'
}

of::info "المطبَّق حالياً: $(applied_version)؛ الهدف: ${TARGET_VERSION}"

pending=()
for file in "$MIGRATIONS_DIR"/*.sql; do
  version="$(basename "$file" | cut -d_ -f1)"
  (( 10#$version > $(applied_version) )) || continue
  [[ "$TARGET_VERSION" != "latest" && 10#$version -gt 10#$TARGET_VERSION ]] && continue
  if touches_identity "$file" && [[ "$OF_REGION_CODE" != "eu-central" ]]; then
    OF_EXIT_CODE=64 of::die "الترحيل $(basename "$file") يمسّ مخطّط identity، وهو يُكتب في eu-central فقط"
  fi
  pending+=("$file")
done

(( ${#pending[@]} == 0 )) && { of::info "لا ترحيلات معلّقة"; exit 0; }
of::info "${#pending[@]} ترحيلاً معلّقاً"

# القفل الاستشاري يُؤخذ على الجلسة كلها ويُحرَّر بانتهائها حتى لو قُتل السكربت، وهو الفرق
# العملي عن جدول أقفال يدوي يبقى محجوزاً بعد انهيار ويحتاج تنظيفاً يدوياً في الثالثة فجراً.
of::info "طلب القفل الاستشاري ${ADVISORY_LOCK_KEY}"
exec 9< <(psql "${OF_DATABASE_URL}" --no-psqlrc --quiet \
            --command "SELECT pg_advisory_lock(${ADVISORY_LOCK_KEY})" \
            --command "SELECT pg_sleep(${OF_MIGRATION_LOCK_HOLD_S:-1800})")
sleep 2

for file in "${pending[@]}"; do
  version="$(basename "$file" | cut -d_ -f1)"
  of::info "تطبيق $(basename "$file")"

  # كل ترحيل داخل معاملة واحدة مع صفّه في schema_migrations، لأن ترحيلاً طُبّق ولم يُسجَّل
  # سيُعاد تطبيقه في المرّة القادمة على مخطّط تغيّر أصلاً.
  if ! psql_rw --single-transaction \
        --file "$file" \
        --command "INSERT INTO public.schema_migrations (version, applied_at, applied_by)
                   VALUES (${version}, now(), '${OF_OPS_SCRIPT}')"; then
    of::error "فشل $(basename "$file")؛ توقّف عند الإصدار $(applied_version)"
    of::error "الترحيلات التالية لم تُطبَّق، فالمخطّط متّسق مع هذا الإصدار وليس نصف مطبَّق"
    exit 70
  fi
done

of::info "بلغ المخطّط الإصدار $(applied_version)"

# telemetry.telemetry_readings مقسّم بالقائمة على region_code (§2.5). ترحيل يضيف عموداً إلى
# الجدول الأب يمسّ الأقسام الثمانية، فنتحقّق أنها كلها ما زالت مربوطة قبل إعلان النجاح:
# قسم انفصل يعني قراءات إقليم كامل تكتب في مكان لا يقرأه أحد.
attached="$(of::psql_ro --command "
  SELECT count(*) FROM pg_inherits
   WHERE inhparent = 'telemetry.telemetry_readings'::regclass")"
(( attached == 8 )) || of::warn "عدد أقسام telemetry_readings ${attached} بدل 8 — أقاليم §0.6 كلها يجب أن تكون مربوطة"

# analytics مشتقّ ويُعاد بناؤه، لكن العروض المتحقّقة لا تنعش نفسها بعد ترحيل يغيّر مصدرها.
# التنبيه هنا مقصود بدل الإنعاش التلقائي: mv_lane_performance_daily تغذّي OF_ROUTING_ETA_MODEL_PATH
# وإنعاشها وسط ساعة الذروة يثقل العنقود أكثر من انتظارها إلى موعد OF_ANALYTICS_MV_REFRESH_CRON.
of::warn "إن مسّ الترحيل مصادر analytics.mv_lane_performance_daily أو analytics.mv_container_utilisation_weekly فأنعشهما عبر analytics-pipeline"
