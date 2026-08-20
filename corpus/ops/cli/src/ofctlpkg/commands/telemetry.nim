##[
  أوامر التنبيهات وقراءات المستشعرات عند telemetry-ingest: ما يفتحه المناوب أولاً حين يرنّ
  إنذار سلسلة التبريد. يعرض التنبيهات المفتوحة، يقرّها، يغلقها بعد معالجتها ميدانياً، ويسحب
  نافذة قراءات من قسم الإقليم كي يرى المنحنى الذي تسبّب في التنبيه.
]##

import std/[json, strutils, strformat, parseopt, times]
import ../[context, apiclient, render]

const
  # قائمة CHECK على `telemetry.telemetry_alerts.rule_code` كما في §2.5.
  RuleCodes = [
    "temp_excursion_high", "temp_excursion_low", "humidity_high", "shock_impact",
    "door_open_in_transit", "battery_critical", "gateway_silent", "geofence_breach"
  ]

proc listAlerts(ctx: var OpsContext, state, ruleCode, containerId: string, severityMin: int) =
  ## `GET /v1/alerts` مع مرشّحات §3.4. تذكّر أن هذه القائمة هي منظور telemetry-ingest وحده:
  ## قلب الشحنة إلى `at_risk` يتمّ عند container-registry بعد استهلاك telemetry.alert.raised
  ## (§4.9) وبشرط أن تبلغ الخطورة OF_FREIGHT_AUTO_AT_RISK_SEVERITY، فوجود تنبيه خطورته 2
  ## وشحنة ما زالت `in_transit` ليس تناقضاً بل هو السلوك المضبوط.
  if ruleCode.len > 0 and ruleCode notin RuleCodes:
    raise newException(ValueError, "rule_code غير معروف: " & ruleCode & " — راجع §2.5")
  var rows: seq[seq[string]]
  var openCount = 0
  for alert in ctx.paginate("telemetry-ingest", "/v1/alerts", @[
      ("state", state), ("rule_code", ruleCode), ("container_id", containerId),
      ("severity_min", if severityMin > 0: $severityMin else: "")]):
    let closed = alert{"closed_at"}.getStr("")
    if closed.len == 0: inc openCount
    rows.add @[
      alert["alert_id"].getStr(),
      alert["container_id"].getStr(),
      alert{"shipment_id"}.getStr("—"),      # يُحلّ عبر freight.v1.ContainerLookup/ResolveShipmentForContainer وقت الرفع
      alert["rule_code"].getStr(),
      $alert["severity"].getInt(),
      alert["threshold_value"].getStr(),
      alert{"peak_value"}.getStr("—"),
      alert["opened_at"].getStr(),
      if closed.len > 0: "closed" else: (if alert{"acknowledged_at"}.getStr("").len > 0: "acked" else: "open")
    ]
  emitTable(ctx, @["alert_id", "container", "shipment", "rule", "sev",
                   "threshold", "peak", "opened_at", "state"], rows)
  if ctx.format == ofTable and openCount > 0:
    warn(ctx, &"{openCount} تنبيهاً مفتوحاً؛ التنبيه المفتوح يبقي الشحنة في at_risk ويمنع تسليمها.")

proc acknowledgeAlert(ctx: var OpsContext, alertId: string) =
  ## الإقرار يوقف تكرار الإشعار عبر notification-service ولا يغلق التنبيه: يبقى
  ## `closed_at` فارغاً وتبقى الشحنة في `at_risk` حتى يُحلّ السبب فعلاً على الأرض.
  let doc = ctx.request("telemetry-ingest", &"/v1/alerts/{alertId}/acknowledge",
                        httpMethod = HttpPost, body = %*{})
  if ctx.dryRun: return
  echo &"{alertId}: أُقرّ بواسطة {doc[\"acknowledged_by\"].getStr()} في {doc[\"acknowledged_at\"].getStr()}"

proc closeAlert(ctx: var OpsContext, alertId, note: string) =
  ## الإغلاق اليدوي مخصّص للحالة التي عولجت ميدانياً بينما ما زال المستشعر يقرأ قيمة سيّئة
  ## (باب مفتوح أثناء التفريغ مثلاً). لا يمحو التنبيه: الصف يبقى في `telemetry.telemetry_alerts`
  ## ونسخته التي لا تُعدَّل موجودة في `platform.audit_ledger_entries`.
  if note.len == 0:
    raise newException(ValueError, "--note مطلوب عند الإغلاق اليدوي؛ يُقرأ في مراجعة الحادثة")
  let doc = ctx.request("telemetry-ingest", &"/v1/alerts/{alertId}/close",
                        httpMethod = HttpPost, body = %*{"note": note})
  if ctx.dryRun: return
  echo &"{alertId}: أُغلق في {doc[\"closed_at\"].getStr()}"

proc showReadings(ctx: var OpsContext, containerId: string, sinceMinutes: int) =
  ## `GET /v1/containers/{container_id}/readings` استعلام نافذة زمنية يصيب قسم الإقليم وحده
  ## (`telemetry.telemetry_readings` مقسّمة LIST على region_code). طلب حاوية خارج إقليمنا يعود
  ## بـ 403 لا بإعادة توجيه، وهذا مقصود: OF_TELEMETRY_ALLOWED_REGIONS يمنع الخلط لا يصلحه.
  let since = (getTime() - initDuration(minutes = sinceMinutes)).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var rows: seq[seq[string]]
  for r in ctx.paginate("telemetry-ingest", &"/v1/containers/{containerId}/readings",
                        @[("since", since)]):
    rows.add @[
      r["reading_id"].getStr(),
      r["recorded_at"].getStr(),
      r["received_at"].getStr(),
      r{"temperature_c"}.getStr("—"),
      r{"humidity_pct"}.getStr("—"),
      r{"shock_g"}.getStr("—"),
      if r{"door_open"}.getBool(false): "open" else: "closed",
      $r{"battery_pct"}.getInt(0),
      r["gateway_id"].getStr()
    ]
  emitTable(ctx, @["reading_id", "recorded_at", "received_at", "temp_c",
                   "humidity", "shock_g", "door", "battery", "gateway"], rows)
  if rows.len == 0:
    warn(ctx, "لا قراءات في النافذة المطلوبة — تحقّق من صمت البوابة عبر " &
              "alert list --rule=gateway_silent قبل أن تشكّ في الحاوية نفسها.")

proc run*(ctx: var OpsContext, command: string, args: seq[string]): int =
  var positional: seq[string]
  var state = "open"
  var ruleCode, containerId, note = ""
  var severityMin = 0
  var sinceMinutes = 120

  var parser = initOptParser(args)
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: positional.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "state":        state = val
      of "rule":         ruleCode = val
      of "container":    containerId = requirePrefix(val, "cnt_")
      of "severity-min": severityMin = parseInt(val)
      of "since-minutes": sinceMinutes = parseInt(val)
      of "note":         note = val
      else: discard
    of cmdEnd: discard

  case command
  of "list":
    ctx.listAlerts(state, ruleCode, containerId, severityMin)
  of "ack":
    ctx.acknowledgeAlert(requirePrefix(positional[2], "alr_"))
  of "close":
    ctx.closeAlert(requirePrefix(positional[2], "alr_"), note)
  of "readings":
    ctx.showReadings(requirePrefix(positional[2], "cnt_"), sinceMinutes)
  else:
    stderr.writeLine "أوامر alert: list | ack | close | readings"
    return 64
  0
