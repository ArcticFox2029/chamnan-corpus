"""งานเบื้องหลังของ pricing-service — Celery worker กับ Kafka consumer

สองอย่างนี้อยู่ในแพ็กเกจเดียวกันเพราะแชร์การตั้งค่าและการผูกบริบท (``context.scoped``)
แต่รันคนละ process กัน: worker กิน queue ``pricing.default`` และ ``pricing.fx``
ส่วน consumer กิน topic ห้าหัวข้อจาก §4
"""
