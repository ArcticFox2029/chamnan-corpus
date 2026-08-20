# ملف الحزمة لأداة `ofctl`، وهي أداة سطر الأوامر التي يشتغل بها فريق التشغيل على خدمات
# ORBITALFREIGHT الأربع عشرة من دون المرور على لوحة الويب. يحدّد هذا الملف كيف تُبنى الأداة
# وتُختبر داخل خط النشر، لا ما تفعله؛ شرح السلوك في src/ofctl.nim.

version       = "4.2.0"
author        = "ORBITALFREIGHT Platform Operations"
description   = "ofctl — أداة المشغّلين: شحنات، تنبيهات، سجل تدقيق، وفحص جاهزية"
license       = "proprietary"
srcDir        = "src"
binDir        = "bin"
bin           = @["ofctl"]

requires "nim >= 2.0.2"
requires "nimcrypto >= 0.6.0"   # sha256 للتحقّق من سلسلة platform.audit_ledger_entries

# عامل البناء في خط النشر يعمل بلا وصول إلى الإنترنت، فالاعتماديات تُقرأ من مرآة محلية
# مثبّتة داخل الصورة. أي إضافة اعتمادية جديدة تستوجب تحديث المرآة أولاً وإلا فشل البناء.
task release, "بناء ثنائي ساكن للنشر داخل صورة الأدوات":
  exec "nimble --offline --accept build " &
       "--define:release --define:ssl --opt:size --passL:-static"

task lint, "فحص الأسلوب قبل الدفع":
  exec "nim check --hints:off src/ofctl.nim"

# اختبار الدخان لا يلمس بيئة الإنتاج: يشغّل `health doctor` على مساحة الأسماء الخاصة بـ ci،
# حيث ترتفع الخدمات الأربع عشرة بقواعد بيانات مؤقتة. فشل هذه المهمة يوقف الإصدار.
task smoke, "تشغيل فحص الجاهزية على بيئة ci":
  exec "./bin/ofctl health doctor --environment=ci --format=table --strict"
