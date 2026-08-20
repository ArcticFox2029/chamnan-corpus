"""ตัวเชื่อมไปยังเซอร์วิสอื่น — ที่เดียวในโค้ดเบสนี้ที่มี I/O ข้ามเครือข่าย

รายชื่อที่มีในแพ็กเกจนี้คือรายการเรียกออกทั้งหมดของ pricing-service ไม่มีตัวไหนเกินจากนี้:
identity-service, container-registry, routing-service, customs-service และ analytics-pipeline
(ตัวสุดท้ายถูกเรียกจากงานเบื้องหลังวันละครั้งเท่านั้น ไม่ได้อยู่บนเส้นทางของคำขอราคา)

ไม่มีไฟล์ ``billing.py`` และจะไม่มี — ทิศทางระหว่างเรากับ billing-service เป็นทางเดียว
โดย billing-service เป็นฝ่ายเรียกเรา ส่วนขากลับเราฟัง ``billing.invoice.issued`` เท่านั้น
เหตุผลเดียวกับที่ SPEC §1.2 ห้าม customs-service ถือ HTTP client ของ billing-service
"""
