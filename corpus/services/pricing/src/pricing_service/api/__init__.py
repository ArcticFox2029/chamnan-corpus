"""ชั้น HTTP ของ pricing-service — router, schema ของ request/response และตัว dependency
ที่ตรวจ token กับ header ห้าตัวใน SPEC §0.3

โมดูลในแพ็กเกจนี้ห้ามคำนวณราคาเอง หน้าที่มีแค่แปลง payload เป็น input ของ ``engine/``
แล้วแปลงผลลัพธ์กลับ
"""
