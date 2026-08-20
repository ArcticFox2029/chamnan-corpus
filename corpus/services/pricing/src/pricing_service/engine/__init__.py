"""หัวใจของ rating engine — โมดูลในแพ็กเกจนี้เป็นฟังก์ชันล้วน ไม่แตะฐานข้อมูล ไม่ยิง HTTP
และไม่รู้จัก FastAPI เลย

ข้อจำกัดนั้นตั้งใจ: ราคาต้องทดสอบได้ด้วยการป้อนตัวเลขเข้าไปตรง ๆ และต้องให้ผลเดิมทุกครั้ง
เมื่อ input เดิม ตัวที่ไปเอาข้อมูลมาจาก container-registry / routing-service / customs-service
อยู่ในแพ็กเกจ ``clients/`` ต่างหาก
"""

from pricing_service.engine.money import Money, allocate, mul_bp
from pricing_service.engine.rating import RatingInput, RatingResult, rate_shipment

__all__ = ["Money", "allocate", "mul_bp", "RatingInput", "RatingResult", "rate_shipment"]
