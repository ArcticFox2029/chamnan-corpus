##[
  أوامر الشحنة: ما يحتاجه المناوب ليفهم شحنة واحدة بالكامل من الطرفية — بياناتها وحاوياتها
  من container-registry، أثر مسحها، مسارها الحالي من routing-service، وتصاريحها الجمركية من
  customs-service. الكتابة الوحيدة المسموحة هنا هي تغيير الحالة عبر
  `PATCH /v1/shipments/{shipment_id}/status`، وهو المسار القانوني الوحيد للانتقال بين الحالات.
]##

import std/[json, strutils, strformat, parseopt, times]
import ../[context, apiclient, render]

const
  # قائمة CHECK على `freight.shipments.status` حرفياً. أي قيمة خارجها ترفضها قاعدة البيانات
  # بعد رحلة كاملة، فنرفضها هنا مبكراً برسالة تذكر البدائل.
  ShipmentStatuses = [
    "draft", "booked", "sealed", "in_transit", "at_risk",
    "held_at_customs", "delivered", "cancelled"
  ]

  # حالتان لا يضعهما إنسان مهما كانت صلاحيته:
  #  - at_risk تأتي من استهلاك container-registry لحدث telemetry.alert.raised (§4.9)، وهي
  #    الحافة التي تكسر دورة container-registry ↔ telemetry-ingest.
  #  - held_at_customs تتبع حالة `customs.customs_declarations` ويقودها customs.declaration.filed.
  # وضعها يدوياً يخلق حالة تناقض ما يراه المستهلكون، ثم يعيدها أول حدث قادم إلى ما كانت عليه.
  DerivedStatuses = ["at_risk", "held_at_customs"]

proc showShipment(ctx: var OpsContext, shipmentId: string) =
  ## `GET /v1/shipments/{shipment_id}` يعيد الحاويات مضمّنة، فلا حاجة لنداء ثانٍ على
  ## `/v1/containers`. حقل `last_reading_at` على كل حاوية يأتي أصلاً من استهلاك
  ## container-registry لحدث telemetry.reading.recorded المعيَّن (§4.8)، فتأخّره دقائق أمر طبيعي.
  let doc = ctx.request("container-registry", "/v1/shipments/" & shipmentId)
  if ctx.format == ofJson:
    echo doc.pretty()
    return
  echo &"""
الشحنة        : {doc["shipment_id"].getStr()}
المرجع        : {doc["reference"].getStr()}
المستأجر      : {doc["tenant_id"].getStr()}
الحالة        : {doc["status"].getStr()}
الإقليم       : {doc["region_code"].getStr()}
المنشأ/الوجهة : {doc["origin_facility_id"].getStr()} → {doc["destination_facility_id"].getStr()}
Incoterm      : {doc["incoterm"].getStr()}
موعد SLA      : {doc{"sla_deadline_at"}.getStr("—")}
القيمة        : {doc["declared_value_minor"].getBiggestInt()} {doc["currency"].getStr()} (وحدات صغرى)
"""
  var rows: seq[seq[string]]
  for c in doc{"containers"}:
    rows.add @[
      c["container_id"].getStr(),
      c["iso_code"].getStr(),
      c["seal_number"].getStr(),
      $c["gross_kg"].getInt(),
      c{"last_reading_at"}.getStr("—")
    ]
  if rows.len > 0:
    emitTable(ctx, @["container_id", "iso_code", "seal_number", "gross_kg", "last_reading_at"], rows)

proc showScans(ctx: var OpsContext, shipmentId: string) =
  ## أثر المسح من `GET /v1/shipments/{shipment_id}/scans`، الأحدث أولاً. الفارق بين
  ## `occurred_at` و`recorded_at` هو زمن عمل الماسح خارج التغطية؛ تجاوزه
  ## OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S يجعل container-registry يعلّم المسح للمراجعة.
  var rows: seq[seq[string]]
  for scan in ctx.paginate("container-registry", &"/v1/shipments/{shipmentId}/scans"):
    let occurred = scan["occurred_at"].getStr()
    let recorded = scan["recorded_at"].getStr()
    let drift = (parse(recorded, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()) -
                 parse(occurred, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc())).inSeconds
    rows.add @[
      scan["scan_id"].getStr(),
      scan["scan_type"].getStr(),
      scan{"facility_id"}.getStr("—"),
      scan["scanned_by_user_id"].getStr(),
      occurred,
      &"{drift}s"
    ]
  emitTable(ctx, @["scan_id", "scan_type", "facility_id", "scanned_by", "occurred_at", "drift"], rows)

proc showRoute(ctx: var OpsContext, shipmentId: string) =
  ## المسار الحالي فقط من routing-service. النسخ السابقة تبقى في `routing.routes` بعلم
  ## `is_current = false`؛ من أراد تاريخ إعادة التخطيط فليقرأ أحداث route.replanned.
  let doc = ctx.request("routing-service", &"/v1/shipments/{shipmentId}/route")
  var rows: seq[seq[string]]
  for leg in doc["legs"]:
    rows.add @[
      $leg["seq_no"].getInt(),
      leg["mode"].getStr(),
      leg["from_facility_id"].getStr(),
      leg["to_facility_id"].getStr(),
      leg{"crossing_id"}.getStr("—"),
      leg["planned_arrive_at"].getStr(),
      leg{"actual_arrive_at"}.getStr("—")
    ]
  echo &"route_id={doc[\"route_id\"].getStr()} version={doc[\"version\"].getInt()} " &
       &"strategy={doc[\"strategy\"].getStr()}"
  emitTable(ctx, @["seq", "mode", "from", "to", "crossing", "planned_arrive", "actual_arrive"], rows)

proc showDeclarations(ctx: var OpsContext, shipmentId: string) =
  ## `GET /v1/shipments/{shipment_id}/declarations` عند customs-service. عمود duty_paid لا
  ## يقلبه إلا استهلاك حدث billing.invoice.settled (§4.15)؛ إن رأيته false مع فاتورة مسدّدة
  ## فالمشكلة في مُستهلك customs-service لا في التصريح نفسه.
  var rows: seq[seq[string]]
  for dcl in ctx.paginate("customs-service", &"/v1/shipments/{shipmentId}/declarations"):
    rows.add @[
      dcl["declaration_id"].getStr(),
      dcl["direction"].getStr(),
      dcl["status"].getStr(),
      dcl{"mrn"}.getStr("—"),
      $dcl{"assessed_duty_minor"}.getBiggestInt(0),
      dcl["currency"].getStr(),
      $dcl["duty_paid"].getBool()
    ]
  emitTable(ctx, @["declaration_id", "direction", "status", "mrn", "duty_minor", "ccy", "duty_paid"], rows)

proc changeStatus(ctx: var OpsContext, shipmentId, toStatus, reasonCode: string) =
  ## المسار الشرعي الوحيد لتغيير الحالة. يعالج container-registry الانتقال داخل معاملة واحدة
  ## مع صفّ في `platform.outbox_messages` ينشر `shipment.status.changed` (§4.5)، ولذلك لا
  ## يوجد أي سبيل لتغيير الحالة من دون أن يعلم المستهلكون: notification-service وrouting-service
  ## وcustoms-service وbilling-service وanalytics-pipeline وaudit-ledger.
  if toStatus notin ShipmentStatuses:
    raise newException(ValueError,
      "حالة غير معروفة: " & toStatus & " — المسموح: " & ShipmentStatuses.join(", "))
  if toStatus in DerivedStatuses:
    raise newException(ValueError,
      &"الحالة {toStatus} مشتقّة من حدث ولا تُضبط يدوياً؛ راجع §4.9 و§4.12")
  if reasonCode.len == 0:
    raise newException(ValueError, "--reason مطلوب: يُكتب في reason_code داخل الحدث المنشور")

  let payload = %*{"to_status": toStatus, "reason_code": reasonCode}
  let doc = ctx.request("container-registry", &"/v1/shipments/{shipmentId}/status",
                        httpMethod = HttpPatch, body = payload)
  if ctx.dryRun: return
  echo &"{shipmentId}: {doc[\"from_status\"].getStr()} → {doc[\"to_status\"].getStr()} " &
       &"(event_id={doc[\"event_id\"].getStr()})"

proc run*(ctx: var OpsContext, command: string, args: seq[string]): int =
  var positional: seq[string]
  var reasonCode = ""
  var parser = initOptParser(args)
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument: positional.add key
    of cmdLongOption, cmdShortOption:
      if key == "reason": reasonCode = val
    of cmdEnd: discard

  # positional[0] هو اسم المجموعة و[1] هو الأمر، فالمعرّف يبدأ من الثالث.
  let target = if positional.len > 2: requirePrefix(positional[2], "shp_") else: ""

  case command
  of "show":         ctx.showShipment(target)
  of "scans":        ctx.showScans(target)
  of "route":        ctx.showRoute(target)
  of "declarations": ctx.showDeclarations(target)
  of "status":
    let toStatus = if positional.len > 3: positional[3] else: ""
    ctx.changeStatus(target, toStatus, reasonCode)
  else:
    stderr.writeLine "أوامر shipment: show | scans | route | declarations | status"
    return 64
  0
