##[
  إخراج الأداة في مكان واحد: جدول للطرفية حين يقرأ إنسان، وJSON حين يُعاد التوجيه إلى ملف
  أو إلى `jq` داخل سكربت حادثة. الفصل مقصود كي لا يتسلّل تنسيق للعين إلى مخرجات يعتمد عليها
  scripts/incident/*.sh في قراراتها.
]##

import std/[json, strutils, sequtils, terminal]
import ./context

proc emitTable*(ctx: OpsContext, headers: seq[string], rows: seq[seq[string]]) =
  ## عرض الأعمدة يُحسب من المحتوى لا من قيمة ثابتة، لأن معرّفات ULID المبدوءة ببادئة تتجاوز
  ## ثلاثين محرفاً وتكسر أي عرض مثبّت سلفاً.
  if ctx.format == ofJson:
    var arr = newJArray()
    for row in rows:
      var obj = newJObject()
      for i, h in headers:
        obj[h] = %row[i]
      arr.add obj
    echo arr.pretty()
    return

  if rows.len == 0:
    echo "(لا نتائج)"
    return

  var widths = headers.mapIt(it.len)
  for row in rows:
    for i, cell in row:
      widths[i] = max(widths[i], cell.len)

  var header = ""
  for i, h in headers:
    header.add h.alignLeft(widths[i] + 2)
  echo header
  echo "-".repeat(header.len)
  for row in rows:
    var line = ""
    for i, cell in row:
      line.add cell.alignLeft(widths[i] + 2)
    echo line

proc emitJson*(ctx: OpsContext, doc: JsonNode) =
  echo doc.pretty()

proc warn*(ctx: OpsContext, message: string) =
  ## التحذير يذهب إلى stderr دائماً كي يبقى stdout صالحاً للأنبوب. مع --strict يتحوّل التحذير
  ## إلى فشل، وهي الحالة التي يشغّل بها خط النشر `ofctl health doctor`.
  if stderr.isatty():
    stderr.styledWriteLine(fgYellow, "تحذير: ", resetStyle, message)
  else:
    stderr.writeLine "تحذير: " & message
