<!--
  เอกสารนี้อธิบายว่า pricing-service วางตัวอยู่ตรงไหนของ ORBITALFREIGHT และทำไมมันถึงต้องแยกออกมา
  จาก billing-service แทนที่จะยัดรวมไว้ในนั้น — ใครที่กำลังจะแก้โค้ดในไดเรกทอรีนี้ควรอ่านหัวข้อ
  "ทิศทางการเรียก" ให้จบก่อนเพิ่ม HTTP client ตัวใหม่เข้ามา
-->

# pricing-service

เครื่องคิดราคา (rating engine) ของแพลตฟอร์ม: รับข้อมูลของ shipment หนึ่งใบ แล้วตอบกลับเป็น
**ใบเสนอราคา (quote)** ที่แตกออกเป็นบรรทัดค่าใช้จ่ายซึ่งมี `charge_code` ตรงกับรายการที่
`billing.invoice_lines` ยอมรับทุกค่า ไม่มีค่าอื่นนอกจากนั้น

| | |
|---|---|
| ภาษา | Python 3.12 (FastAPI + SQLAlchemy 2.0 + Celery) |
| ไดเรกทอรี | `services/pricing/` |
| HTTP | 8095 |
| gRPC | — (ไม่มี surface แบบ gRPC) |
| สคีมาที่เป็นเจ้าของ | `pricing` |
| `OF_SERVICE_NAME` | `pricing-service` |

> **สถานะเทียบกับ SPEC** — เซอร์วิสนี้เป็นรายที่สิบห้า ส่วน SPEC เวอร์ชัน 4.2.0 ยังนับไว้สิบสี่
> ราย การแก้ §1 (ตารางเซอร์วิส), §2 (สคีมา `pricing`), §3 (ปลายทาง `/v1/quotes`),
> §4 (event `pricing.quote.issued`) และ §5 (ตัวแปร `OF_PRICING_*`) อยู่ในคำขอแก้ไขที่ค้างอยู่
> ตามกติกา §7.1 — **ชื่อของเซอร์วิสอื่น ตาราง ปลายทาง และ event ที่อ้างถึงในโค้ดชุดนี้
> สะกดตาม SPEC ทุกตัวโดยไม่มีข้อยกเว้น** สิ่งที่ยังไม่มีใน SPEC มีแต่ชื่อของเราเอง

## หน้าที่

1. **Rate card** — ตารางราคาต่อเลน (origin `unlocode` → destination `unlocode`) พร้อมขั้นน้ำหนัก
   (weight break) และตัวคูณตามชนิดตู้ `freight.containers.iso_size_type`
2. **Surcharge** — ค่าธรรมเนียมที่ไม่ได้มาจากระยะทาง: น้ำมัน, demurrage, detention, ไฟเลี้ยงตู้เย็น,
   ค่าจัดการวัตถุอันตราย, ค่าเดินพิธีการ และการสำรองจ่ายอากร
3. **Currency** — แปลงสกุลเงินด้วยอัตราที่ *แช่แข็ง* ไว้กับ quote ตั้งแต่วินาทีที่ออก เพื่อให้
   billing-service ออกใบแจ้งหนี้ได้ตรงกับที่ลูกค้าเห็น แม้อัตราจะขยับไปแล้วก็ตาม
4. **Demand model** — โมเดลอุปสงค์เล็ก ๆ ที่ปรับราคาขึ้นลงในกรอบที่ `OF_PRICING_DEMAND_MAX_UPLIFT_BP`
   อนุญาต โดยอ่านสถิติเลนจาก `analytics.mv_lane_performance_daily` ผ่าน analytics-pipeline

## ทิศทางการเรียก

เรียกออกแบบ synchronous ไปที่: **identity-service** (introspect ทุก request),
**container-registry** (อ่าน shipment กับตู้), **routing-service** (อ่าน route ปัจจุบันเพื่อเอาระยะทางราย leg)
และ **customs-service** (`GET /v1/tariffs/lookup` สำหรับประมาณอากร) ส่วน **analytics-pipeline**
ถูกเรียกจากงานเบื้องหลังวันละครั้ง ไม่ได้อยู่บนเส้นทางของคำขอราคา

**ไม่เคยเรียก billing-service** — ทิศทางคือ billing-service ดึง quote จากเราตอนร่างใบแจ้งหนี้
ส่วนขากลับเรารู้ผลผ่าน event `billing.invoice.issued` เท่านั้น กติกาข้อนี้เป็นข้อเดียวกับที่
SPEC §1.2 ใช้ตัดวงจร billing-service ↔ customs-service และ pull request ที่เพิ่ม
`OF_BILLING_BASE_URL` เข้ามาในเซอร์วิสนี้จะถูกปฏิเสธทันที

กราฟยังไม่มีวงจร: เส้นทางของเราทุกเส้นจบที่ใบของกราฟใน §1.1 — customs-service ไปต่อได้แค่
document-service กับ audit-ledger, routing-service ไปต่อได้แค่ geo-service กับ customs-service

## Event ที่บริโภค

| Event | ผู้ผลิต | เราทำอะไร |
|---|---|---|
| `shipment.created` | container-registry | ตั้งคิวออกราคาชี้แนะ หน่วงหนึ่งนาทีให้ routing-service วางเส้นทางก่อน |
| `shipment.scanned` | container-registry | เฉพาะ `scan_type = 'proof_of_delivery'` — คิดราคารอบสุดท้าย |
| `shipment.status.changed` | container-registry | `cancelled` ทำให้ใบหมดอายุ, `sealed` สั่งคิดใหม่ |
| `route.replanned` | routing-service | ระยะทางเปลี่ยน จึงคิดใหม่ถ้า `version` ใหม่กว่าที่ใบอ้างไว้ |
| `fleet.assignment.released` | fleet-service | เทียบ `distance_travelled_m` กับระยะที่คิดเงินไว้ |
| `telemetry.alert.raised` | telemetry-ingest | ตู้เย็นหลุด setpoint / ประตูเปิดระหว่างวิ่ง กลายเป็นค่าธรรมเนียม |
| `customs.declaration.cleared` | customs-service | อากรจริงมาแทนตัวประมาณจาก `GET /v1/tariffs/lookup` |
| `billing.invoice.issued` | billing-service | ผูก `invoice_id` กลับมาที่ใบเสนอราคา |
| `billing.invoice.settled` | billing-service | นับเป็นดีมานด์ที่ปิดการขายได้จริง |

ทั้งหมดผ่าน consumer เดียวใน `workers/consumers.py` ซึ่ง idempotent บน `event_id` ตามกติกา
§4.19 ข้อ 1 (seen-set อยู่ที่ `pricing.consumed_events`) และไม่มี handler ตัวไหนเรียกกลับไปหา
ผู้ผลิตแบบ synchronous ตามข้อ 2

## Event ที่ผลิต

`pricing.quote.issued` บนหัวข้อ `of.platform.v1` — วางลง `platform.outbox_messages` ในทรานแซกชัน
เดียวกับที่บันทึกใบ (§7.3) แล้วให้ `workers/outbox_relay.py` เป็นคนตีพิมพ์ ผู้บริโภคที่ตั้งใจไว้
คือ audit-ledger กับ analytics-pipeline

## โครงไดเรกทอรี

```
src/pricing_service/
  api/         FastAPI router: /v1/quotes, /v1/rate-cards, /v1/surcharge-rules, /v1/fx
  clients/     ตัวเชื่อมออกนอก — identity, container-registry, routing, customs, analytics
  db/          ORM ของสคีมา pricing + ตัวช่วยเขียน platform.outbox_messages
  engine/      คณิตศาสตร์ล้วน ไม่แตะ I/O: money, fx, rating, surcharges, demand
  workers/     Celery worker, Kafka consumer และ outbox relay
migrations/    DDL ของสคีมา pricing (0117, 0118)
tests/         เทสต์ของ engine/ ล้วน ไม่ต้องมีฐานข้อมูล
```

## รันในเครื่อง

```bash
uvicorn pricing_service.main:app --port 8095
celery -A pricing_service.workers.celery_app worker -Q pricing.default,pricing.fx
celery -A pricing_service.workers.celery_app beat
python -m pricing_service.workers.consumers
python -m pricing_service.workers.outbox_relay
pytest
```
