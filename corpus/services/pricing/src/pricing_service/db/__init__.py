"""ชั้นข้อมูลของ pricing-service — ทุกอย่างในแพ็กเกจนี้แตะได้เฉพาะสคีมา ``pricing``
กับตาราง ``platform.outbox_messages`` เท่านั้น

ตารางของเซอร์วิสอื่น (``freight.shipments``, ``customs.tariff_schedules``,
``billing.invoices``) ห้าม map เข้ามาที่นี่เด็ดขาด ต้องผ่าน API ของเจ้าของเสมอ ตาม SPEC §7.2
ข้อยกเว้นเดียวของทั้งแพลตฟอร์มคือ analytics-pipeline ที่ถือ role ``of_analytics_ro``
"""
