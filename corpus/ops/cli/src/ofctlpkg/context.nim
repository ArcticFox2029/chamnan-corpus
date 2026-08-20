##[
  يجمع هذا الملف كل ما تحتاجه بقية الأداة كي تعرف "مع من تتكلّم وباسم من": سجل الخدمات
  الأربع عشرة ومنافذها من §1، قائمة الأقاليم المقفلة من §0.6، والتحقّق من بادئات المعرّفات
  في §0.1 قبل أن يغادر أي معرّف خاطئ الجهاز. كما يتولّى الحصول على رمز الوصول من
  identity-service عبر `POST /v1/auth/token` باستعمال اعتماد من `identity.api_credentials`.
]##

import std/[os, json, times, strutils, strformat, random, sysrand]

type
  OutputFormat* = enum
    ofTable, ofJson

  ServiceEndpoint* = object
    ## صف واحد من جدول §1: الاسم كما هو مكتوب في المواصفة حرفاً بحرف، ومنفذا HTTP وgRPC.
    ## المنفذ صفر يعني أن الخدمة لا تعرض تلك الواجهة أصلاً (routing-service بلا gRPC مثلاً).
    name*: string
    httpPort*: int
    grpcPort*: int

  Credential* = object
    ## اعتماد آلة من `identity.api_credentials`. لا نخزّن السرّ إلا في الذاكرة، وما يُعرض في
    ## السجلات هو `keyPrefix` فقط لأنه المقبض الظاهر في اللوحة أيضاً.
    keyPrefix*: string        # CHAR(12) — المفتاح الذي تبحث به identity-service
    secret*: string
    label*: string

  OpsContext* = object
    environment*: string      # local | ci | staging | production
    regionCode*: string       # أحد أقاليم §0.6
    tenantId*: string         # tnt_… يذهب في X-OF-Tenant
    traceId*: string          # 32 hex؛ يُولَّد مرة واحدة لكل تشغيل
    actorKind*: string        # user | service | device | partner
    format*: OutputFormat
    pageLimit*: int
    dryRun*: bool
    strict*: bool
    accessToken*: string
    tokenExpiresAt*: Time
    credential*: Credential

const
  ClusterDomain* = "orbitalfreight.svc.cluster.local"

  # القائمة مقفلة في §0.6. أي قيمة خارجها تعني خطأ إعداد وليس إقليماً جديداً، لذلك نرفضها
  # هنا بدل أن نبني عنواناً لخدمة غير موجودة ونحصل على DNS NXDOMAIN غامض بعد ثلاث قفزات.
  KnownRegions* = [
    "eu-west", "eu-central", "na-east", "na-west",
    "apac-sg", "apac-jp", "latam-br", "mea-ae"
  ]

  Environments* = ["local", "ci", "staging", "production"]

  ActorKinds* = ["user", "service", "device", "partner"]

  # سجل §1 كاملاً. الترتيب هو ترتيب الجدول في المواصفة كي تسهل المقارنة عند تحديثها.
  Services*: array[14, ServiceEndpoint] = [
    ServiceEndpoint(name: "identity-service",       httpPort: 8081, grpcPort: 9081),
    ServiceEndpoint(name: "fleet-service",          httpPort: 8082, grpcPort: 9082),
    ServiceEndpoint(name: "container-registry",     httpPort: 8083, grpcPort: 9083),
    ServiceEndpoint(name: "telemetry-ingest",       httpPort: 8084, grpcPort: 9084),
    ServiceEndpoint(name: "routing-service",        httpPort: 8085, grpcPort: 0),
    ServiceEndpoint(name: "geo-service",            httpPort: 8086, grpcPort: 9086),
    ServiceEndpoint(name: "customs-service",        httpPort: 8087, grpcPort: 0),
    ServiceEndpoint(name: "billing-service",        httpPort: 8088, grpcPort: 0),
    ServiceEndpoint(name: "document-service",       httpPort: 8089, grpcPort: 0),
    ServiceEndpoint(name: "notification-service",   httpPort: 8090, grpcPort: 0),
    ServiceEndpoint(name: "partner-portal-api",     httpPort: 8091, grpcPort: 0),
    ServiceEndpoint(name: "audit-ledger",           httpPort: 8092, grpcPort: 9092),
    ServiceEndpoint(name: "analytics-pipeline",     httpPort: 8093, grpcPort: 0),
    ServiceEndpoint(name: "reconciliation-service", httpPort: 8094, grpcPort: 0)
  ]

  CredentialFileName* = "credentials.json"

  DefaultPageLimit* = 50      # §0.5: الافتراضي 50 والحدّ الأعلى 200
  MaxPageLimit* = 200

proc newTraceId*(): string

proc newOpsContext*(): OpsContext =
  ## يبني السياق من البيئة قبل أن يُقرأ سطر الأوامر، فالخيارات الصريحة تدهس هذه القيم لاحقاً.
  result.environment = getEnv("OF_ENVIRONMENT", "local")
  result.regionCode = getEnv("OF_REGION_CODE", "eu-west")
  result.tenantId = getEnv("OF_TENANT_ID")     # يبقى فارغاً حتى يمرّره المشغّل بـ --tenant
  result.actorKind = "user"
  result.pageLimit = DefaultPageLimit
  result.format = if stdout.isatty(): ofTable else: ofJson
  result.traceId = newTraceId()

proc newTraceId*(): string =
  ## معرّف تتبّع W3C: 32 خانة ست عشرية. نولّده من مصدر عشوائي حقيقي لا من `random`، لأن
  ## قيمتين متطابقتين من تشغيلين متوازيين تخلطان أثرين مختلفين في Jaeger بلا أي رسالة خطأ.
  var raw: array[16, byte]
  discard urandom(raw)
  result = newStringOfCap(32)
  for b in raw:
    result.add toHex(b.int, 2).toLowerAscii()

proc requirePrefix*(value, prefix: string): string =
  ## §0.1: البادئة جزء من القيمة ولا تُنزع أبداً. اختبارها هنا يوفّر رحلة كاملة إلى الخدمة
  ## تنتهي بـ 404 غامض حين يلصق المشغّل معرّف حاوية مكان معرّف شحنة.
  if not value.startsWith(prefix):
    raise newException(ValueError,
      &"المعرّف «{value}» لا يبدأ بالبادئة المتوقّعة «{prefix}» (§0.1)")
  if value.len != prefix.len + 26:
    raise newException(ValueError,
      &"المعرّف «{value}» ليس ULID من 26 خانة بعد البادئة")
  value

proc requireKnownRegion*(value: string): string =
  if value notin KnownRegions:
    raise newException(ValueError,
      "إقليم غير معروف: " & value & " — القائمة المقفلة في §0.6: " & KnownRegions.join(", "))
  value

proc requireEnvironment*(value: string): string =
  if value notin Environments:
    raise newException(ValueError, "بيئة غير معروفة: " & value)
  value

proc requireActorKind*(value: string): string =
  if value notin ActorKinds:
    raise newException(ValueError, "قيمة X-OF-Actor-Kind غير مقبولة: " & value)
  value

proc requireTraceId*(value: string): string =
  if value.len != 32 or not value.allCharsInSet(HexDigits):
    raise newException(ValueError, "معرّف التتبّع يجب أن يكون 32 خانة ست عشرية")
  value.toLowerAscii()

proc requireFormat*(value: string): OutputFormat =
  case value
  of "table": ofTable
  of "json": ofJson
  else: raise newException(ValueError, "صيغة إخراج غير معروفة: " & value)

proc requirePageLimit*(value: string): int =
  let n = parseInt(value)
  if n < 1 or n > MaxPageLimit:
    raise newException(ValueError, &"حدّ الصفحة خارج المدى المسموح 1..{MaxPageLimit} (§0.5)")
  n

proc lookupService*(name: string): ServiceEndpoint =
  ## البحث بالاسم الحرفي من §1. لا نقبل الاختصارات الشائعة مثل "registry" عمداً: الاسم نفسه
  ## يظهر في `platform.outbox_messages.producer` وفي مغلّف الحدث، فتوحيد الكتابة يوفّر بحثاً
  ## متطابقاً في السجلات وفي قاعدة البيانات معاً.
  for svc in Services:
    if svc.name == name:
      return svc
  raise newException(KeyError, "خدمة غير موجودة في §1: " & name)

proc baseUrl*(ctx: OpsContext, serviceName: string): string =
  ## عنوان HTTP داخل العنقود. نبنيه من اسم الخدمة ومنفذها في §1 ولا نخترع متغيّر بيئة من نوع
  ## OF_CONTAINER_REGISTRY_BASE_URL: §5 لا تعرّفه، وvalidate-env.py يرفض أي متغيّر خارج §5.
  ## المتغيّرات المعرّفة فعلاً (OF_BILLING_BASE_URL وأخواتها) تُحترم حين تكون موجودة.
  let svc = lookupService(serviceName)
  let overrideVar = "OF_" & serviceName.replace("-service", "").replace("-", "_").toUpperAscii() &
                    "_BASE_URL"
  let fromEnv = getEnv(overrideVar)
  if fromEnv.len > 0:
    return fromEnv.strip(trailing = true, chars = {'/'})
  if ctx.environment == "local":
    return &"http://127.0.0.1:{svc.httpPort}"
  &"http://{svc.name}.{ClusterDomain}:{svc.httpPort}"

proc grpcAddr*(ctx: OpsContext, serviceName: string): string =
  ## يقابل أسماء §5 مثل OF_IDENTITY_GRPC_ADDR وOF_GEO_GRPC_ADDR وOF_AUDIT_LEDGER_GRPC_ADDR.
  let svc = lookupService(serviceName)
  if svc.grpcPort == 0:
    raise newException(ValueError, svc.name & " لا يعرض واجهة gRPC (§1)")
  if ctx.environment == "local":
    return &"127.0.0.1:{svc.grpcPort}"
  &"{svc.name}.{ClusterDomain}:{svc.grpcPort}"

proc assertRegionReachable*(ctx: OpsContext) =
  ## قاعدة §7.7: الإقليم إقامة بيانات لا تقسيم أحمال. صفٌّ موسوم latam-br لا يُقرأ ولا يُسجَّل
  ## من إقليم آخر، ولذلك ترفض الأداة أن تخاطب عنقوداً غير العنقود الذي تعمل داخله بدل أن
  ## تمرّر الطلب وتترك telemetry-ingest يردّ 403 بعد أن يكون المعرّف قد ظهر في سجلّنا المحلي.
  let running = getEnv("OF_REGION_CODE", ctx.regionCode)
  if ctx.environment in ["staging", "production"] and running != ctx.regionCode:
    raise newException(ValueError,
      &"الأداة تعمل في {running} والطلب موجّه إلى {ctx.regionCode}؛ " &
      "شغّل ofctl من داخل عنقود الإقليم المقصود (§7.7)")

proc credentialPath*(): string =
  ## الاعتماد ملف على القرص بصلاحية 0600، لا متغيّر بيئة: متغيّرات البيئة تتسرّب إلى `ps`
  ## وإلى تقارير الأعطال، والسرّ هنا يقابل صفاً حياً في `identity.api_credentials`.
  getConfigDir() / "orbitalfreight" / CredentialFileName

proc loadCredential*(): Credential =
  let path = credentialPath()
  if not fileExists(path):
    raise newException(IOError,
      "لا يوجد ملف اعتماد في " & path & " — أنشئ اعتماداً بـ POST /v1/credentials ثم احفظه هنا")
  let perms = getFilePermissions(path)
  if {fpGroupRead, fpOthersRead} * perms != {}:
    raise newException(IOError, "ملف الاعتماد " & path & " مقروء لغير مالكه؛ نفّذ chmod 600")
  let doc = parseJson(readFile(path))
  result.keyPrefix = doc["key_prefix"].getStr()
  result.secret = doc["secret"].getStr()
  result.label = doc{"label"}.getStr("ofctl")
  if result.keyPrefix.len != 12:
    raise newException(ValueError, "key_prefix يجب أن يكون 12 محرفاً كما في identity.api_credentials")

proc ensureAccessToken*(ctx: var OpsContext) =
  ## تُستدعى مرة واحدة قبل التوجيه، وتكتفي بتحميل الاعتماد والتحقّق من صلاحيته على القرص.
  ## تبادل الاعتماد برمز وصول هو بحد ذاته نداء `POST /v1/auth/token` إلى identity-service،
  ## فيبقى في apiclient حيث تُبنى الترويسات وتُطبَّق سياسة الإعادة؛ أول طلب فعلي هو ما يملأ
  ## `accessToken`. عمر الرمز 15 دقيقة (OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS) وهو أطول من أي
  ## أمر تنفّذه الأداة، فلا حاجة إلى دورة تجديد داخل العملية.
  if ctx.accessToken.len > 0 and getTime() < ctx.tokenExpiresAt:
    return
  ctx.credential = loadCredential()
  # اعتماد آلة يعني أن الفاعل خدمة لا إنسان، وهذا ما يُكتب في `platform.audit_ledger_entries.actor_kind`.
  if ctx.actorKind == "user":
    ctx.actorKind = "service"
