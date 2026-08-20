##[
  التحقّق من سجلّ التدقيق محلياً بدل تصديق ما ترويه الخدمة عن نفسها: تقرأ الوحدة إدخالات
  `platform.audit_ledger_entries` عبر audit-ledger، تعيد حساب سلسلة التجزئة على الجهاز، وتطابق
  برهان الاشتمال مع نقطة التفتيش الموقّعة. هذا هو الاستعمال الوحيد المشروع للأداة في نزاع
  قانوني، ولذلك لا تحتوي على أي مسار كتابة إلى السجلّ.
]##

import std/[json, strutils, strformat, parseopt, algorithm, times]
import nimcrypto/[sha2, hash, utils]
import ../[context, apiclient, render]

const
  # مفردات `subject_type` مشتقّة من جدول `platform.document_owner_types`، وهو ما يمنع العمود
  # من أن يصير نصاً حراً. الإجراءات مثل 'shipment.sealed' و'credential.revoked' نص حرّ عمداً.
  SubjectTypes = ["shipment", "container", "scan", "declaration", "invoice", "carrier"]

  # 32 بايت صفرية هي سلف الإدخال الأول تماماً كما في §2.8؛ أي قيمة أخرى تعني أننا ننظر إلى
  # سلسلة أخرى (تغيير OF_LEDGER_HASH_ALGORITHM يبدأ سلسلة جديدة ولا يعيد كتابة القديمة).
  GenesisPrevHash = "0000000000000000000000000000000000000000000000000000000000000000"

proc canonicalJson(entry: JsonNode): string =
  ## الشكل المعياري الذي تُحسب عليه التجزئة: مفاتيح مرتّبة أبجدياً، بلا مسافات، وبلا حقلي
  ## `entry_hash` و`checkpoint_id` لأن الأول هو الناتج والثاني يُضاف بعد الطيّ في شجرة Merkle.
  ## أي اختلاف في هذا الترتيب يجعل كل تحقّق يفشل، فلا تلمسه إلا مع تغيير مقابل في audit-ledger.
  var keys: seq[string]
  for k in entry.keys:
    if k notin ["entry_hash", "checkpoint_id"]:
      keys.add k
  keys.sort()
  var parts: seq[string]
  for k in keys:
    parts.add escapeJson(k) & ":" & $entry[k]
  "{" & parts.join(",") & "}"

proc computeEntryHash(prevHashHex: string, entry: JsonNode): string =
  ## sha256(prev || canonical_json(row)) — نفس التركيب المكتوب في §2.8. نمرّر السلف كبايتات
  ## لا كنص ست عشري، وهي التفصيلة التي أضاعت علينا يوماً كاملاً في أول تنفيذ للمدقّق.
  var ctxHash: sha256
  ctxHash.init()
  ctxHash.update(fromHex(prevHashHex))
  ctxHash.update(canonicalJson(entry).toOpenArrayByte(0, canonicalJson(entry).high))
  $ctxHash.finish()

proc verifyChain(ctx: var OpsContext, subjectType, subjectId, since: string): int =
  ## يمرّ على الإدخالات بترتيب `entry_id` التصاعدي ويعيد بناء السلسلة. `entry_id` هو الاستثناء
  ## الوحيد لقاعدة ULID في §0.1 — تسلسل BIGINT — لأن السلسلة تحتاج ترتيباً كلياً لا مجرد فرادة.
  var rows: seq[seq[string]]
  var entries: seq[JsonNode]
  for e in ctx.paginate("audit-ledger", "/v1/entries",
                        @[("subject_type", subjectType), ("subject_id", subjectId), ("since", since)]):
    entries.add e
  entries.sort(proc (a, b: JsonNode): int =
    cmp(a["entry_id"].getBiggestInt(), b["entry_id"].getBiggestInt()))

  var broken = 0
  var expectedPrev = ""
  for i, e in entries:
    let declaredPrev = e["prev_entry_hash"].getStr()
    let declaredHash = e["entry_hash"].getStr()
    let recomputed = computeEntryHash(declaredPrev, e)

    var verdict = "ok"
    if recomputed != declaredHash:
      verdict = "hash_mismatch"
      inc broken
    elif i == 0 and declaredPrev != GenesisPrevHash and expectedPrev.len == 0:
      # ليست بالضرورة مشكلة: نافذة `since` تبدأ من منتصف السلسلة، فنكتفي بتثبيت نقطة البداية.
      expectedPrev = declaredHash
      verdict = "ok (بداية نافذة)"
    elif expectedPrev.len > 0 and declaredPrev != expectedPrev:
      verdict = "chain_break"
      inc broken
    if verdict.startsWith("ok"):
      expectedPrev = declaredHash

    rows.add @[
      $e["entry_id"].getBiggestInt(),
      e["action"].getStr(),
      e["actor_kind"].getStr() & ":" & e["actor_id"].getStr(),
      e["subject_type"].getStr() & "/" & e["subject_id"].getStr(),
      e["recorded_at"].getStr(),
      verdict
    ]

  emitTable(ctx, @["entry_id", "action", "actor", "subject", "recorded_at", "verify"], rows)
  if broken > 0:
    # كسر السلسلة ليس عطلاً تشغيلياً يُصلَح بإعادة تشغيل: قاعدة §7.6 تمنع التعديل والحذف
    # أصلاً، فوجود الكسر يعني تدخّلاً على مستوى قاعدة البيانات ويستدعي تصعيداً أمنياً فوراً.
    stderr.writeLine &"سلسلة السجلّ مكسورة في {broken} إدخالاً — صعّد الأمر أمنياً ولا تصلح شيئاً بنفسك."
    return 1
  0

proc showProof(ctx: var OpsContext, entryId: string) =
  ## برهان اشتمال Merkle مقابل نقطة التفتيش المنشورة. نقارن الجذر الذي يعيده البرهان بالرأس
  ## الموقّع من `GET /v1/checkpoints/latest`، والذي يُنسخ كل ساعة إلى جهة توثيق خارجية
  ## (OF_LEDGER_NOTARY_ENDPOINT) حتى لا يكون تصديق النظام على نفسه هو كل الدليل.
  let proof = ctx.request("audit-ledger", &"/v1/entries/{entryId}/proof")
  let head = ctx.request("audit-ledger", "/v1/checkpoints/latest")

  var running = proof["leaf_hash"].getStr()
  for step in proof["path"]:
    var h: sha256
    h.init()
    if step["side"].getStr() == "left":
      h.update(fromHex(step["hash"].getStr()))
      h.update(fromHex(running))
    else:
      h.update(fromHex(running))
      h.update(fromHex(step["hash"].getStr()))
    running = $h.finish()

  let publishedRoot = head["root_hash"].getStr()
  echo &"entry_id      : {entryId}"
  echo &"checkpoint_id : {head[\"checkpoint_id\"].getBiggestInt()}"
  echo &"الجذر المحسوب : {running}"
  echo &"الجذر المنشور : {publishedRoot}"
  if running == publishedRoot:
    echo "النتيجة       : الإدخال مشمول في نقطة التفتيش الموقّعة."
  else:
    echo "النتيجة       : البرهان لا يطابق الرأس المنشور — لا تعتمد هذا الإدخال كدليل."

proc run*(ctx: var OpsContext, command: string, args: seq[string]): int =
  var positional: seq[string]
  var subjectType, subjectId, since = ""
  var parser = initOptParser(args)
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: positional.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "subject-type":
        if val notin SubjectTypes:
          raise newException(ValueError, "subject_type خارج المفردات المعرّفة: " & val)
        subjectType = val
      of "subject-id": subjectId = val
      of "since":      since = val
      else: discard
    of cmdEnd: discard

  case command
  of "entries", "verify":
    return ctx.verifyChain(subjectType, subjectId, since)
  of "proof":
    ctx.showProof(positional[2])
  of "checkpoint":
    emitJson(ctx, ctx.request("audit-ledger", "/v1/checkpoints/latest"))
  else:
    stderr.writeLine "أوامر ledger: entries | verify | proof | checkpoint"
    stderr.writeLine "الإضافة إلى السجلّ تتمّ حصراً عبر audit.v1.LedgerService/Append من الخدمة المالكة للفعل."
    return 64
  0
