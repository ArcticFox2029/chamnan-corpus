##[
  نقطة الدخول لأداة `ofctl`: تفصل الخيارات العامة عن الأمر الفرعي، تبني سياق تشغيل واحداً
  (المستأجر، الإقليم، معرّف التتبّع، رمز الوصول) تتشاركه كل النداءات الصادرة، ثم تسلّم التنفيذ
  إلى الوحدة المسؤولة عن المجموعة المطلوبة. الأداة لا تفتح اتصالاً بقاعدة البيانات إطلاقاً؛
  كل قراءة أو تعديل يمرّ عبر واجهة الخدمة المالكة للبيانات كما في §3.
]##

import std/[os, strutils, parseopt, terminal]
import ofctlpkg/[context, apiclient]
import ofctlpkg/commands/[shipment, telemetry, ledger, health]

const
  ToolVersion = "4.2.0"

  Usage = """
ofctl <المجموعة> <الأمر> [خيارات]

المجموعات:
  shipment   قراءة الشحنات وتغيير حالتها عبر container-registry
  alert      تنبيهات telemetry-ingest: عرض، إقرار، إغلاق
  ledger     إدخالات audit-ledger وبراهين الاشتمال مقابل نقطة التفتيش المنشورة
  health     فحص /healthz و/readyz و/version و/metrics لخدمات §1 كلها

الخيارات العامة:
  --tenant=tnt_…         قيمة ترويسة X-OF-Tenant؛ يجب أن تطابق مطالبة tid في الرمز
  --region=eu-west       أحد أقاليم §0.6؛ الافتراضي من OF_REGION_CODE
  --environment=…        local | ci | staging | production
  --trace-id=<32 hex>    يُعاد استعماله في كل نداءات الجلسة؛ يُولَّد إذا غاب
  --actor=user|service   قيمة X-OF-Actor-Kind؛ الافتراضي user
  --format=table|json    الافتراضي table على الطرفية وjson عند إعادة التوجيه
  --limit=<1..200>       حجم الصفحة في ترقيم §0.5
  --dry-run              يطبع الطلب الذي كان سيُرسَل ثم يخرج
  --strict               يعتبر أي تحذير فشلاً (يستعمله خط النشر)
  -h, --help             هذه الرسالة
  -v, --version

أمثلة:
  ofctl shipment show shp_01J8ZK4T9QW3RM7XN2VB6HD5PC
  ofctl alert list --rule=temp_excursion_high --severity-min=4
  ofctl ledger proof 918273 --subject-type=shipment
  ofctl health doctor --environment=production --format=json
"""

type
  UsageError* = object of CatchableError
    ## خطأ في سطر الأوامر نفسه، يُميَّز عن خطأ الخدمة كي يعود برمز خروج 64 لا 70.

proc splitInvocation(raw: seq[string]): tuple[group, command: string, rest: seq[string]] =
  ## يفصل أول وسيطين غير المسبوقين بشرطة، ويترك الباقي كما هو لتفكّه وحدة المجموعة نفسها.
  ## الخيارات العامة قد تسبق المجموعة أو تليها، لأن المشغّلين يكتبونها بالترتيبين.
  var positional: seq[string]
  for token in raw:
    if not token.startsWith("-"):
      positional.add token
  if positional.len == 0:
    raise newException(UsageError, "لم تُذكر أي مجموعة")
  result.group = positional[0]
  result.command = if positional.len > 1: positional[1] else: ""
  result.rest = raw

proc applyGlobalFlag(ctx: var OpsContext, key, val: string): bool =
  ## يعيد true إذا ابتلع الخيار هنا؛ ما عداه يُترك لوحدة المجموعة.
  case key
  of "tenant":      ctx.tenantId = requirePrefix(val, "tnt_"); true
  of "region":      ctx.regionCode = requireKnownRegion(val); true
  of "environment": ctx.environment = requireEnvironment(val); true
  of "trace-id":    ctx.traceId = requireTraceId(val); true
  of "actor":       ctx.actorKind = requireActorKind(val); true
  of "format":      ctx.format = requireFormat(val); true
  of "limit":       ctx.pageLimit = requirePageLimit(val); true
  of "dry-run":     ctx.dryRun = true; true
  of "strict":      ctx.strict = true; true
  else: false

proc dispatch(ctx: var OpsContext, group, command: string, args: seq[string]): int =
  ## التوجيه مسطّح عن قصد: مجموعة واحدة لكل خدمة يلمسها المشغّل، ولا مجموعة بلا وحدة تنفّذها.
  case group
  of "shipment": shipment.run(ctx, command, args)
  of "alert":    telemetry.run(ctx, command, args)
  of "ledger":   ledger.run(ctx, command, args)
  of "health":   health.run(ctx, command, args)
  else:
    raise newException(UsageError, "مجموعة غير معروفة: " & group)

proc main(): int =
  var ctx = newOpsContext()           # يقرأ OF_REGION_CODE وOF_ENVIRONMENT وملف الاعتماد
  var raw: seq[string]
  var parser = initOptParser(commandLineParams())

  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument:
      raw.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        stdout.write Usage
        return 0
      of "v", "version":
        echo "ofctl ", ToolVersion
        return 0
      else:
        if not applyGlobalFlag(ctx, key, val):
          # خيار خاص بالمجموعة: نعيد تركيبه كما ورد كي تفكّه الوحدة بنفسها.
          raw.add(if val.len > 0: "--" & key & "=" & val else: "--" & key)
    of cmdEnd:
      discard

  if raw.len == 0:
    stdout.write Usage
    return 64

  let call = splitInvocation(raw)

  # الإقليم بيانات إقامة لا مجرد وسم (قاعدة §7.7): إذا طلب المشغّل إقليماً غير الذي تعمل فيه
  # الأداة، نرفض بدل أن نمرّر الطلب إلى نسخة الخدمة الخطأ ونسرّب صفاً خارج إقليمه.
  ctx.assertRegionReachable()

  # الرمز يُطلب مرة واحدة لكل تشغيل من identity-service عبر POST /v1/auth/token، وعمره 15 دقيقة
  # وهو أطول من أي أمر تنفّذه الأداة، فلا حاجة لدورة تجديد داخل العملية.
  ctx.ensureAccessToken()

  dispatch(ctx, call.group, call.command, call.rest)

when isMainModule:
  try:
    quit main()
  except UsageError as e:
    stderr.writeLine "ofctl: " & e.msg
    stderr.writeLine "جرّب: ofctl --help"
    quit 64
  except ApiError as e:
    # مغلّف الخطأ في §0.4 مصمَّم ليُقرأ بالعين: نطبع الرمز الثابت ومعرّف التتبّع أولاً لأنهما
    # ما سيلصقه المشغّل في بلاغ الحادثة، ثم الحقول المرفوضة إن وُجدت.
    stderr.styledWriteLine(fgRed, "خطأ ", e.code, " (HTTP ", $e.httpStatus, ")")
    stderr.writeLine "  " & e.message
    stderr.writeLine "  trace_id: " & e.traceId
    for field in e.fields:
      stderr.writeLine "  - " & field.path & ": " & field.reason
    if e.retryable:
      stderr.writeLine "  الخطأ قابل للإعادة؛ أعد المحاولة بنفس X-OF-Idempotency-Key."
    quit 70
  except OSError as e:
    stderr.writeLine "ofctl: تعذّر الوصول إلى الشبكة أو الملفات: " & e.msg
    quit 74
