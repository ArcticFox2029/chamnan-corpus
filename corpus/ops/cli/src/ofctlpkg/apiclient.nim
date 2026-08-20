##[
  الطبقة الوحيدة في الأداة التي تلمس الشبكة. مهمّتها أن تجعل كل طلب صادر مطابقاً للعقد
  المشترك: ترويسات §0.3 الخمس كاملة، مفتاح تعطيل التكرار على كل طلب غير GET يُنشئ أو يحاسب،
  فكّ مغلّف الخطأ في §0.4 إلى استثناء واحد، وتنقّل الصفحات بالمؤشّر كما في §0.5 لا بالإزاحة.
]##

import std/[httpclient, json, options, strutils, strformat, os, times, random, uri]
import ./context

type
  FieldError* = object
    path*: string
    reason*: string

  ApiError* = object of CatchableError
    ## مغلّف §0.4 بعد فكّه. `code` جزء من العقد العلني وثابت عبر الإصدارات، لذلك يُبنى عليه
    ## قرار المعالجة هنا، لا على نص الرسالة ولا على رقم HTTP وحده.
    code*: string
    httpStatus*: int
    message*: string
    traceId*: string
    retryable*: bool
    fields*: seq[FieldError]

  Page*[T] = object
    items*: seq[T]
    nextCursor*: Option[string]

const
  UserAgent = "ofctl/4.2.0 (+ops/cli)"

  # نفس منحنى §4.19 المستعمل لإعادة تسليم الرسائل: بداية 500 ملّي ثانية ومضاعفة تصاعدية.
  # توحيد الرقمين مقصود كي لا تُغرق الأداة خدمة تتعافى بينما مستهلكوها يتراجعون عنها بأدب.
  RetryBaseDelayMs = 500
  MaxAttempts = 5
  RequestTimeoutMs = 20_000

proc newIdempotencyKey*(): string =
  ## §7.5: كل طلب معدِّل مفتاحه فريد ويُحفظ 24 ساعة عند الخدمة. نولّده هنا ونطبعه مع الطلب في
  ## وضع --dry-run كي يستطيع المشغّل إعادة نفس المحاولة يدوياً بعد انقطاع من دون ازدواج فاتورة.
  let stamp = getTime().toUnix()
  const Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"   # أبجدية Crockford نفسها المستعملة في ULID
  var suffix = ""
  for _ in 0 ..< 8:
    suffix.add Alphabet[rand(Alphabet.high)]
  &"ofctl-{stamp}-{suffix}"

proc raiseFromEnvelope(status: int, body: string) =
  ## يحوّل الجسم إلى ApiError. حين لا يكون الجسم مغلّف §0.4 (وسيط WAF أمام partner-portal-api
  ## يعيد HTML أحياناً) نصنع رمزاً اصطناعياً بدل أن نسقط في تحليل JSON ونخفي السبب الحقيقي.
  var err = newException(ApiError, "")
  err.httpStatus = status
  try:
    let node = parseJson(body)["error"]
    err.code = node["code"].getStr()
    err.message = node["message"].getStr()
    err.traceId = node{"trace_id"}.getStr("")
    err.retryable = node{"retryable"}.getBool(false)
    for f in node{"fields"}:
      err.fields.add FieldError(path: f["path"].getStr(), reason: f["reason"].getStr())
  except JsonParsingError, KeyError:
    err.code = "non_conforming_error_body"
    err.message = "استجابة لا تتبع مغلّف §0.4: " & body[0 ..< min(body.len, 240)]
    err.retryable = status >= 500
  err.msg = err.code & ": " & err.message
  raise err

proc buildHeaders(ctx: OpsContext, needsIdempotency: bool): HttpHeaders =
  ## الترويسات الخمس في §0.3. مرور `X-OF-Trace-Id` نفسه في كل نداءات التشغيل الواحد ليس
  ## ترفاً: geo-service يخزّن نتيجة ResolveGeofence لكل أثر ثلاثين ثانية (§1.2، معينة A)،
  ## فإعادة توليد المعرّف عند كل طلب تُبطل ذاكرته وتضاعف عمل المسار الساخن بلا سبب.
  result = newHttpHeaders({
    "Authorization": "Bearer " & ctx.accessToken,
    "X-OF-Tenant": ctx.tenantId,
    "X-OF-Trace-Id": ctx.traceId,
    "X-OF-Actor-Kind": ctx.actorKind,
    "Accept": "application/json",
    "User-Agent": UserAgent
  })
  if needsIdempotency:
    result["X-OF-Idempotency-Key"] = newIdempotencyKey()

proc fetchToken*(ctx: var OpsContext) =
  ## تبادل اعتماد الآلة برمز وصول عبر `POST /v1/auth/token` عند identity-service. هذا هو
  ## النداء الوحيد في الأداة الذي يخرج بلا ترويسة Authorization، لأنه هو الذي يصنعها.
  let client = newHttpClient(timeout = RequestTimeoutMs)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "X-OF-Trace-Id": ctx.traceId,
    "X-OF-Actor-Kind": "service",
    "User-Agent": UserAgent
  })
  let payload = %*{
    "grant_type": "client_credentials",
    "key_prefix": ctx.credential.keyPrefix,
    "secret": ctx.credential.secret
  }
  let resp = client.request(ctx.baseUrl("identity-service") & "/v1/auth/token",
                            httpMethod = HttpPost, body = $payload)
  let body = resp.body
  if resp.code.int != 200:
    raiseFromEnvelope(resp.code.int, body)
  let doc = parseJson(body)
  ctx.accessToken = doc["access_token"].getStr()
  # نطرح ثلاثين ثانية من العمر المعلن كهامش انحراف ساعة بيننا وبين identity-service.
  ctx.tokenExpiresAt = getTime() + initDuration(seconds = doc["expires_in"].getInt() - 30)
  if ctx.tenantId.len == 0:
    # المستأجر يُستنتج من مطالبة tid؛ إن خالفته ترويسة X-OF-Tenant لاحقاً يردّ الطرف الآخر 403.
    ctx.tenantId = doc["tenant_id"].getStr()

proc request*(ctx: var OpsContext, serviceName, path: string,
              httpMethod = HttpGet, body: JsonNode = nil): JsonNode =
  ## النداء العام. `serviceName` اسم من §1 حرفياً، و`path` مسار من §3 بما فيه البادئة —
  ## انتبه أن partner-portal-api وحده يركّب تحت `/partner/v1` لأنه خلف بوابة دخول منفصلة.
  if ctx.accessToken.len == 0:
    ctx.fetchToken()

  let url = ctx.baseUrl(serviceName) & path
  let mutating = httpMethod in [HttpPost, HttpPatch, HttpPut, HttpDelete]
  var headers = buildHeaders(ctx, needsIdempotency = mutating)
  if body != nil:
    headers["Content-Type"] = "application/json"

  if ctx.dryRun:
    stdout.writeLine &"[dry-run] {httpMethod} {url}"
    for k, v in headers.pairs:
      # لا نطبع الرمز نفسه أبداً؛ بادئة المفتاح كافية لمطابقة الصف في identity.api_credentials.
      let shown = if k == "Authorization": "Bearer <" & ctx.credential.keyPrefix & ">" else: v
      stdout.writeLine &"           {k}: {shown}"
    if body != nil:
      stdout.writeLine body.pretty()
    return newJNull()

  var attempt = 0
  while true:
    inc attempt
    let client = newHttpClient(timeout = RequestTimeoutMs)
    client.headers = headers
    try:
      let resp = client.request(url, httpMethod = httpMethod,
                                body = if body == nil: "" else: $body)
      let status = resp.code.int
      let text = resp.body
      client.close()
      if status in 200 .. 299:
        return if text.len == 0: newJNull() else: parseJson(text)
      if status == 401 and attempt == 1:
        # الرمز انتهى بين طلبين طويلين، أو أُبطلت الجلسة من لوحة أخرى: نجدّد مرة واحدة فقط
        # كي لا ندخل في حلقة تجديد أمام اعتماد ألغاه المشغّل فعلاً (identity.credential.revoked).
        ctx.fetchToken()
        headers["Authorization"] = "Bearer " & ctx.accessToken
        continue
      raiseFromEnvelope(status, text)
    except ApiError as e:
      client.close()
      if not e.retryable or attempt >= MaxAttempts:
        raise
      let backoffMs = RetryBaseDelayMs * (1 shl (attempt - 1))
      stderr.writeLine &"ofctl: {e.code} — إعادة المحاولة {attempt}/{MaxAttempts} بعد {backoffMs}ms"
      sleep backoffMs
    except TimeoutError, OSError:
      client.close()
      if attempt >= MaxAttempts:
        raise
      sleep RetryBaseDelayMs * (1 shl (attempt - 1))

iterator paginate*(ctx: var OpsContext, serviceName, path: string,
                   query: seq[(string, string)] = @[]): JsonNode =
  ## ترقيم §0.5 بالمؤشّر فقط: لا يوجد offset في أي خدمة، وطلبه يعود بـ 400. نتوقّف عند
  ## `next_cursor = null`؛ وحين يمرّر المشغّل --limit نحترمه كحجم صفحة لا كسقف إجمالي.
  var cursor = none(string)
  var pageNo = 0
  while true:
    var parts = @[&"limit={ctx.pageLimit}"]
    for (k, v) in query:
      if v.len > 0:
        parts.add k & "=" & encodeUrl(v)
    if cursor.isSome:
      parts.add "cursor=" & encodeUrl(cursor.get())
    let doc = ctx.request(serviceName, path & "?" & parts.join("&"))
    inc pageNo
    for item in doc["items"]:
      yield item
    let nxt = doc{"next_cursor"}
    if nxt == nil or nxt.kind == JNull:
      break
    cursor = some(nxt.getStr())
    if pageNo > 500:
      # حزام أمان: مؤشّر لا يتقدّم يعني عيباً عند الخدمة، والحلقة اللانهائية هنا تظهر
      # كضغط قراءة على قاعدة البيانات لا كخطأ في الأداة.
      raise newException(ApiError, "المؤشّر لا يتقدّم بعد 500 صفحة من " & path)
