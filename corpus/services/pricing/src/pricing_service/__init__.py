"""แพ็กเกจรากของ pricing-service.

เก็บไว้แค่หมายเลขเวอร์ชันกับชื่อเซอร์วิสตามที่ SPEC §1 สะกดไว้ เพราะโมดูลนี้ถูก import
ตั้งแต่บรรทัดแรกของทั้ง FastAPI app และ Celery worker การไปใส่ side effect ตรงนี้
(เปิด connection pool, อ่านไฟล์ config) จะทำให้ ``celery -A`` ค้างตั้งแต่ยังไม่ทันเริ่มงาน
"""

SERVICE_NAME = "pricing-service"
"""ต้องตรงกับค่า ``OF_SERVICE_NAME`` และกับชื่อใน SPEC §1 แบบตัวต่อตัว"""

VERSION = "4.2.0"

EXPECTED_SCHEMA_MIGRATION = 118
"""หมายเลข migration ของสคีมา ``pricing`` ที่โค้ดชุดนี้คาดหวัง — ``GET /version`` เอาไปตอบ"""

__all__ = ["SERVICE_NAME", "VERSION", "EXPECTED_SCHEMA_MIGRATION"]
