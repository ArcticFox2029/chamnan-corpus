# قيم الإقليم eu-west في الإنتاج. هنا ما يجوز أن يُقرأ في مراجعة طلب دمج فقط: أسماء المضيفين
# وأعداد النسخ وحدود الرصد. كل ما هو سرّي — رمز العنقود وكلمات مرور Postgres وSASL — يُمرَّر
# من خزنة خط النشر بـ ‎-var‎ عند التنفيذ ولا يهبط في ملف داخل المستودع أبداً.
#
# ملف واحد لكل زوج (بيئة، إقليم). النسخ بين الملفات الثمانية مقبول عمداً: قاعدة مشتركة
# بتجاوزات كانت ستجعل قراءة إعداد إقليم واحد تتطلّب فتح ثلاثة ملفات وحساب الفرق ذهنياً،
# وهو آخر ما يريده من يقرأ هذا في الثالثة فجراً.

region_code = "eu-west"
environment = "production"

cluster_endpoint = "https://k8s-eu-west.orbitalfreight.internal:6443"
database_host    = "postgres-eu-west.orbitalfreight.internal"

# ثلاثة وسطاء، وعامل تكرار 3 وأدنى نسخ متزامنة 2 يُشتقّان من البيئة داخل وحدة kafka-topics.
kafka_brokers = "kafka-0.eu-west.orbitalfreight.internal:9092,kafka-1.eu-west.orbitalfreight.internal:9092,kafka-2.eu-west.orbitalfreight.internal:9092"

# eu-central وحدها تكتب مخطّط identity؛ eu-west نسخة للقراءة. وحدة regional-database تقرأ
# هذه القيمة وتمنح identity-service قراءة فقط هنا، فمحاولة كتابة تفشل صراحةً بدل أن تنجح
# محلياً ثم تتضارب مع النسخة الواردة.
identity_write_region = "eu-central"

# 0.05 في الإنتاج: أثر كامل على حجم eu-west يكلّف أكثر ممّا يفيد، والحوادث تُتتبَّع بمعرّف
# الأثر الذي تحقنه سكربتات ops/ في X-OF-Trace-Id على كل طلب صادر.
otel_sample_ratio = 0.05

image_tag = "stable"

# الأعداد أعلى من الافتراضي في variables.tf لأن eu-west ثاني أعلى حمل في المنصّة بعد apac-sg.
# ملاحظة تُنسى دائماً: OF_DATABASE_MAX_CONNS محسوب لكل جراب لا لكل عنقود، فكل زيادة هنا
# تضرب سقف اتصالات Postgres بالعدد نفسه.
service_replicas = {
  identity-service       = 8
  fleet-service          = 4
  container-registry     = 8
  telemetry-ingest       = 16
  routing-service        = 5
  geo-service            = 10
  customs-service        = 4
  billing-service        = 4
  document-service       = 8
  notification-service   = 4
  partner-portal-api     = 5
  analytics-pipeline     = 2
  audit-ledger           = 3
  reconciliation-service = 1
}
