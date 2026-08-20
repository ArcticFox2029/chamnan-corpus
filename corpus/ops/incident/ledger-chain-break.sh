#!/usr/bin/env bash
# دليل تشغيل انكسار سلسلة التدقيق: يُستدعى حين يُبلّغ audit-ledger أن التحقّق فشل، أو حين
# يعطي `ofctl ledger verify` نتيجة مخالفة. الغرض جمع الدليل وتحديد أول إدخال منكسر بدقّة،
# لا «الإصلاح» — platform.audit_ledger_entries جدول إلحاق فقط بلا صلاحية UPDATE أو DELETE،
# وأي محاولة لتصحيح صفّ فيه تكسر التحقّق من كل صفّ بعده وتحوّل عطلاً تقنياً إلى مشكلة قانونية.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
OF_OPS_SCRIPT="incident/ledger-chain-break.sh"

# التحقّق يمشي على السلسلة كلها افتراضياً. تمرير نوع موضوع يضيّقه إلى إدخالات ذلك النوع
# وحده — أسرع بكثير، لكنه لا يثبت سلامة السلسلة: التجزئة تربط كل الإدخالات لا إدخالات نوع.
SUBJECT_TYPE="${1:-}"
VERIFY_ARGS=(--format=json)
[[ -n "$SUBJECT_TYPE" ]] && VERIFY_ARGS+=("--subject-type=${SUBJECT_TYPE}")

of::confirm_production

# 32 بايت صفرية هي سلف الإدخال الأول تماماً (§2.8). قيمة أخرى في entry_id = 1 لا تعني كسراً:
# تعني أننا ننظر إلى سلسلة أخرى، وهو ما يحدث بعد تغيير OF_LEDGER_HASH_ALGORITHM — تغييره
# يبدأ سلسلة جديدة ولا يعيد كتابة القديمة.
readonly GENESIS_PREV_HASH='\x0000000000000000000000000000000000000000000000000000000000000000'

# قبل أي شيء: هل نحن ننظر إلى السلسلة التي نظنّها؟ سلف مختلف عند الإدخال الأول يعني سلسلة
# أخرى بدأت بتغيير الخوارزمية، وليس كسراً — والفرق بينهما هو الفرق بين حادثة وسوء فهم.
ACTUAL_GENESIS="$(of::psql_ro --command "
  SELECT encode(prev_entry_hash, 'hex') FROM platform.audit_ledger_entries WHERE entry_id = 1")"
if [[ "\\x${ACTUAL_GENESIS}" != "${GENESIS_PREV_HASH}" ]]; then
  of::warn "سلف الإدخال الأول ليس اثنين وثلاثين بايتاً صفرية — هذه سلسلة أخرى بدأت بعد تغيير OF_LEDGER_HASH_ALGORITHM"
  of::warn "لا تقارن ما بعدها بنقاط تفتيش السلسلة السابقة؛ لكل سلسلة رأسها الموقّع الخاصّ"
fi

of::info "التحقّق محلياً${SUBJECT_TYPE:+ على موضوعات من نوع ${SUBJECT_TYPE}}"

# التحقّق نفسه يجري داخل ofctl لأنه يعيد حساب sha256 على الجهاز بدل تصديق ما ترويه الخدمة
# عن نفسها. السكربت هنا يحيط بذلك بالسياق: أين انكسرت، ومن كتب حولها، وماذا كان يجري.
if ofctl ledger verify "${VERIFY_ARGS[@]}" > /tmp/of-ledger-verify.json; then
  of::info "السلسلة سليمة حتى الرأس؛ لا حادثة"
  exit 0
fi

BROKEN_AT="$(jq -r '.first_broken_entry_id' /tmp/of-ledger-verify.json)"
of::error "أول إدخال لا يطابق تجزئته: ${BROKEN_AT}"

# ── 1. جوار الكسر ───────────────────────────────────────────────────────────────────────
of::info "الإدخالات المحيطة:"
of::psql_ro --command "
  SELECT entry_id, actor_kind, actor_id, action, subject_type, subject_id,
         trace_id, recorded_at, checkpoint_id
    FROM platform.audit_ledger_entries
   WHERE entry_id BETWEEN ${BROKEN_AT} - 3 AND ${BROKEN_AT} + 3
   ORDER BY entry_id" | column -t -s'|'

# ── 2. هل الكسر قبل نقطة تفتيش منشورة أم بعدها؟ ─────────────────────────────────────────
# checkpoint_id يُملأ عند طيّ الإدخال في نقطة Merkle، والرأس الموقّع يُنسخ كل ساعة إلى
# الموثّق الخارجي (OF_LEDGER_NOTARY_ENDPOINT، وOF_LEDGER_CHECKPOINT_INTERVAL_MINUTES = 60).
# كسر قبل نقطة منشورة يعني أن نسخة خارجية تناقضنا، وهذا أخطر بكثير من كسر في الذيل.
CHECKPOINTED="$(of::psql_ro --command "
  SELECT coalesce(checkpoint_id::text, 'none')
    FROM platform.audit_ledger_entries WHERE entry_id = ${BROKEN_AT}")"

if [[ "$CHECKPOINTED" != "none" ]]; then
  of::error "الإدخال مطويّ في نقطة التفتيش ${CHECKPOINTED} — أي أن رأساً موقّعاً نُشر فوقه"
  of::error "قارن فوراً بالموثّق الخارجي قبل أي إجراء آخر:"
  of::error "  GET /v1/checkpoints/latest على audit-ledger مقابل نسخة ${OF_LEDGER_NOTARY_ENDPOINT:-الموثّق}"
  of::error "  GET /v1/entries/${BROKEN_AT}/proof للحصول على برهان الاشتمال"
else
  of::warn "الإدخال لم يُطوَ في نقطة تفتيش بعد؛ الكسر محصور في الذيل غير المنشور"
fi

# ── 3. من كان يكتب؟ ─────────────────────────────────────────────────────────────────────
# audit.v1.LedgerService/Append هو مسار الكتابة الوحيد، وكل الخدمات تنادي عبره لا عبر SQL.
# كتابتان متزامنتان تحسبان prev_entry_hash نفسه هما التفسير الأرجح لكسر في الذيل، ولذلك
# نعدّ الإدخالات في الثانية المحيطة: تسلسل عالٍ لحظة الكسر يرجّح السباق على العبث.
of::info "معدّل الإلحاق حول لحظة الكسر:"
of::psql_ro --command "
  SELECT date_trunc('second', recorded_at) AS at_second, count(*)
    FROM platform.audit_ledger_entries
   WHERE entry_id BETWEEN ${BROKEN_AT} - 200 AND ${BROKEN_AT} + 200
   GROUP BY 1 ORDER BY 1"

TRACE="$(of::psql_ro --command "
  SELECT coalesce(trace_id, '') FROM platform.audit_ledger_entries WHERE entry_id = ${BROKEN_AT}")"
[[ -n "$TRACE" ]] && of::info "أثر الطلب الذي كتب الإدخال: ${TRACE}"

cat >&2 <<TAIL

ما لا يُفعل، بلا استثناء:
  • لا UPDATE ولا DELETE على platform.audit_ledger_entries. الصلاحيات لا تسمح، ومشغّل
    البيانات يرفع خطأً في كل الأحوال، ومن يلتفّ على ذلك يكسر التحقّق من كل إدخال بعده.
  • لا إعادة حساب entry_hash «لتصحيح» السلسلة. التصحيح في هذه المنصّة إلحاق دائماً:
    قيد معوّض جديد، تماماً كتعديل تصريح على customs.customs_declarations وإشعار دائن في billing.

ما يُفعل:
  1. جمّد الإلحاق مؤقتاً إن كان الكسر في الذيل: قلّل نسخ audit-ledger إلى واحدة، وهو ما
     يُنهي السباق على prev_entry_hash إن كان هو السبب.
  2. سجّل الحادثة بقيد معوّض عبر audit.v1.LedgerService/Append بعد الاستقرار.
  3. سلّم /tmp/of-ledger-verify.json وبرهان الاشتمال إلى المسؤول القانوني كما هما.

TAIL
exit 70
