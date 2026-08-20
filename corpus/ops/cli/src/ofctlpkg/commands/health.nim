##[
  مسح جاهزية العنقود: يطرق `/healthz` و`/readyz` و`/version` و`/metrics` على الخدمات الأربع
  عشرة في §1، ويقرأ من العدّادات ما يخبر فعلاً بحال المنصة — تأخّر مُرحّل صندوق الصادر
  وتراكم مجموعات الاستهلاك. تعمّد ألا يمرّ عبر apiclient: حين يكون identity-service نفسه
  هو المتعطّل، أداة تحتاج رمزاً منه لن تستطيع أن تخبرك بذلك.
]##

import std/[httpclient, json, strutils, strformat, parseopt, tables, algorithm]
import ../[context, render]

type
  ProbeResult = object
    service: string
    live: bool
    ready: bool
    version: string
    migration: int
    outboxPending: int
    consumerLag: int
    detail: string

const
  ProbeTimeoutMs = 3_000

  # أسماء العدّادات كما تعرضها كل خدمة على `/metrics`. المُرحّل يستطلع
  # `platform.outbox_messages` كل OF_OUTBOX_RELAY_INTERVAL_MS، فالمتوقّع أن يبقى المعلّق قريباً
  # من الصفر؛ ارتفاعه المستمر يعني أن المُرحّل متوقّف لا أن الإنتاج ازداد.
  MetricOutboxPending = "of_outbox_pending_messages"
  MetricConsumerLag = "of_kafka_consumer_group_lag"

  # فوق هذا الحدّ لم يعد التأخّر تذبذباً: مستهلكو `of.freight.v1` الأبطأ يبدأون بتأخير
  # تحديث `freight.containers.last_reading_at` وتعليق ما يعتمد عليه في التسوية الليلية.
  OutboxWarnThreshold = 5_000
  ConsumerLagWarnThreshold = 50_000

proc scrapeMetric(body: string, name: string): int =
  ## قراءة مبسّطة لصيغة Prometheus: نجمع كل العيّنات التي تحمل الاسم مهما اختلفت وسومها،
  ## لأن ما يهمّ المناوب هو المجموع لكل خدمة لا التفصيل حسب الموضوع.
  for line in body.splitLines():
    if line.len == 0 or line[0] == '#': continue
    if not line.startsWith(name): continue
    let parts = line.rsplit(' ', maxsplit = 1)
    if parts.len == 2:
      try:
        result += int(parseFloat(parts[1]))
      except ValueError:
        discard

proc probe(ctx: OpsContext, svc: ServiceEndpoint): ProbeResult =
  result.service = svc.name
  let base = ctx.baseUrl(svc.name)
  let client = newHttpClient(timeout = ProbeTimeoutMs)
  defer: client.close()

  try:
    # `/healthz` لا يلمس قاعدة البيانات إطلاقاً (§3.15): نجاحه يعني أن العملية حيّة فقط.
    result.live = client.get(base & "/healthz").code.int == 200
  except CatchableError:
    result.detail = "لا استجابة على /healthz"
    return

  try:
    # `/readyz` هو الفحص المركّب: قاعدة البيانات وKafka وidentity-service. فشله مع نجاح
    # `/healthz` يعني عادةً أن التبعية هي المتعطّلة لا الخدمة.
    let resp = client.get(base & "/readyz")
    result.ready = resp.code.int == 200
    if not result.ready:
      result.detail = resp.body.strip()[0 ..< min(resp.body.strip().len, 80)]
  except CatchableError:
    result.detail = "مهلة على /readyz"

  try:
    let ver = parseJson(client.getContent(base & "/version"))
    result.version = ver["version"].getStr() & "+" & ver["build_sha"].getStr()[0 ..< 7]
    result.migration = ver["schema_migration"].getInt()
  except CatchableError:
    result.version = "?"

  try:
    let metrics = client.getContent(base & "/metrics")
    result.outboxPending = scrapeMetric(metrics, MetricOutboxPending)
    result.consumerLag = scrapeMetric(metrics, MetricConsumerLag)
  except CatchableError:
    discard

proc doctor(ctx: var OpsContext): int =
  var results: seq[ProbeResult]
  for svc in Services:
    results.add probe(ctx, svc)

  var rows: seq[seq[string]]
  var problems = 0
  var warnings = 0
  for r in results:
    var flags: seq[string]
    if not r.live: flags.add "down"
    elif not r.ready: flags.add "not-ready"
    if r.outboxPending > OutboxWarnThreshold: flags.add &"outbox={r.outboxPending}"
    if r.consumerLag > ConsumerLagWarnThreshold: flags.add &"lag={r.consumerLag}"
    if not r.live or not r.ready: inc problems
    elif flags.len > 0: inc warnings
    rows.add @[
      r.service,
      if r.live: "up" else: "down",
      if r.ready: "ready" else: "-",
      r.version,
      $r.migration,
      $r.outboxPending,
      $r.consumerLag,
      if flags.len > 0: flags.join(",") else: r.detail
    ]
  emitTable(ctx, @["service", "live", "ready", "version", "migration",
                   "outbox", "lag", "ملاحظات"], rows)

  # identity-service جذر بياني §1.1: كل الخدمات الثلاث عشرة تستدعي
  # identity.v1.TokenIntrospection/Introspect. سقوطه يجعل البقية تعمل على JWKS مخزّن لمدة
  # OF_IDENTITY_JWKS_GRACE_SECONDS ثم ترفض كل نداء باعتماد آلة، فنقولها صراحةً بدل أن يقرأ
  # المناوب أربعة عشر سطر "not-ready" ويظنّها أربعة عشر عطلاً منفصلاً.
  for r in results:
    if r.service == "identity-service" and not r.ready:
      warn(ctx, "identity-service غير جاهز: بقية الخدمات على مهلة JWKS المخزّن " &
                "(OF_IDENTITY_JWKS_GRACE_SECONDS) وسترفض نداءات الاعتمادات بعدها. ابدأ من هنا.")

  # اختلاف رقم الهجرة أثناء طرح تدريجي أمر طبيعي لدقائق؛ بقاؤه بعد انتهاء الطرح يعني نشراً
  # نصفياً: خدمة تتوقّع مخطّطاً وأخرى تكتب بمخطّط آخر على نفس العنقود.
  var migrations = initCountTable[int]()
  for r in results:
    if r.migration > 0: migrations.inc r.migration
  if migrations.len > 1:
    var seen: seq[string]
    for m, c in migrations.pairs:
      seen.add &"{m}×{c}"
    warn(ctx, "أرقام هجرة مختلفة عبر الخدمات: " & seen.join(", ") &
              " — تحقّق من اكتمال آخر طرح قبل أي إجراء آخر.")
    inc warnings

  if problems > 0: return 1
  if warnings > 0 and ctx.strict: return 1
  0

proc outboxDetail(ctx: var OpsContext, serviceName: string): int =
  ## تفصيل مُرحّل خدمة واحدة. قاعدة §7.3 تجعل تغيّر الحالة ونشر حدثه معاملة واحدة، لذلك تراكم
  ## الصادر يعني أن الحالة تغيّرت فعلاً وأن المستهلكين وحدهم هم من لم يعلم بعد — وهو فرق جوهري
  ## في قرار الحادثة: لا تعيد تشغيل المنتج، أصلح المُرحّل.
  let svc = lookupService(serviceName)
  let client = newHttpClient(timeout = ProbeTimeoutMs)
  defer: client.close()
  let metrics = client.getContent(ctx.baseUrl(svc.name) & "/metrics")
  var rows: seq[seq[string]]
  for line in metrics.splitLines():
    if line.startsWith(MetricOutboxPending) or line.startsWith(MetricConsumerLag):
      let parts = line.rsplit(' ', maxsplit = 1)
      rows.add @[parts[0], parts[1]]
  emitTable(ctx, @["metric", "value"], rows)
  0

proc run*(ctx: var OpsContext, command: string, args: seq[string]): int =
  var positional: seq[string]
  var parser = initOptParser(args)
  for kind, key, val in parser.getopt():
    if kind == cmdArgument: positional.add key

  case command
  of "doctor": return ctx.doctor()
  of "outbox":
    let target = if positional.len > 2: positional[2] else: "container-registry"
    return ctx.outboxDetail(target)
  else:
    stderr.writeLine "أوامر health: doctor | outbox <service-name>"
    return 64
