"""นิยามฐานร่วมของทุก ORM model: declarative base, ตัวสร้าง ULID ที่มี prefix ตาม SPEC §0.1
และชนิดคอลัมน์สำเร็จรูปสำหรับเงิน/อัตรา/ระยะทาง เพื่อไม่ให้แต่ละไฟล์ประกาศเองแล้วเพี้ยนกัน

ชนิด ``Money`` ที่นี่คือ ``BIGINT`` เปล่า ๆ โดยเจตนา — ไม่มี NUMERIC และไม่มี float ในสายราคา
เลยแม้แต่คอลัมน์เดียว
"""

from __future__ import annotations

import datetime as dt
from typing import Annotated, Final

from sqlalchemy import BigInteger, CheckConstraint, DateTime, Integer, MetaData, String, text
from sqlalchemy.orm import DeclarativeBase, mapped_column
from ulid import ULID

SCHEMA: Final[str] = "pricing"

# ชื่อ constraint ที่คาดเดาได้ ทำให้ migration ที่ alembic สร้างอ่านรู้เรื่องและ diff ได้จริง
NAMING_CONVENTION: Final[dict[str, str]] = {
    "ix": "%(table_name)s_%(column_0_N_name)s_idx",
    "uq": "%(table_name)s_%(column_0_N_name)s_key",
    "ck": "%(table_name)s_%(constraint_name)s_chk",
    "fk": "%(table_name)s_%(column_0_name)s_fkey",
    "pk": "%(table_name)s_pkey",
}


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA, naming_convention=NAMING_CONVENTION)


def new_id(prefix: str) -> str:
    """สร้าง identifier รูปแบบ ``<prefix>_<ULID>`` ตามที่ §0.1 กำหนด

    Args:
        prefix: prefix สามหรือสี่ตัวอักษร เช่น ``quo`` ``rcd`` ``fxr``

    Returns:
        str: ค่าเช่น ``quo_01J8ZK4T9QW3RM7XN2VB6HD5PC`` — prefix เป็นส่วนหนึ่งของค่า
        และห้ามถูกตัดทิ้งระหว่างทาง ไม่ว่าจะใน JSON, ล็อก หรือ partition key ของ Kafka
    """

    return f"{prefix}_{ULID()}"


# ---- ชนิดคอลัมน์ที่ใช้ซ้ำทั้งเซอร์วิส -------------------------------------------------

Id = Annotated[str, mapped_column(String(31), primary_key=True)]
Ref = Annotated[str, mapped_column(String(31))]
Money = Annotated[int, mapped_column(BigInteger)]
BasisPoints = Annotated[int, mapped_column(Integer)]
Metres = Annotated[int, mapped_column(BigInteger)]
Kilograms = Annotated[int, mapped_column(Integer)]
Currency = Annotated[str, mapped_column(String(3))]
Timestamp = Annotated[dt.datetime, mapped_column(DateTime(timezone=True))]


def utcnow_default() -> "text":
    """ค่า default ฝั่งฐานข้อมูล ไม่ใช่ฝั่ง Python — เวลาของแถวต้องมาจากนาฬิกาเดียว

    ใช้ ``now()`` (เวลาเริ่มทรานแซกชัน) เหมือนตารางอื่นในแพลตฟอร์ม ยกเว้น
    ``platform.audit_ledger_entries`` ที่ใช้ ``clock_timestamp()`` เพราะโซ่แฮชต้องเรียงจริง
    """

    return text("now()")


def positive_money(column: str, name: str) -> CheckConstraint:
    return CheckConstraint(f"{column} >= 0", name=name)
