/*
 * 领域枚举的单一出处：这里的每一个联合类型都逐字对应 SPEC §2 里某一列的 CHECK 约束。
 * 控制台的状态徽章、筛选下拉、看板分栏全部从这里取值，所以后端加一个状态而前端没跟上时，
 * 编译会直接失败，而不是在界面上渲染出一个没有颜色的空徽章。
 */

import type {
  CarrierId,
  ContainerId,
  CrossingId,
  DeclarationId,
  FacilityId,
  GeofenceId,
  InvoiceId,
  ShipmentId,
  TenantId,
  UserId,
} from './ids';

/** SPEC §0.6 的封闭列表。多一个值就意味着要先改 SPEC，再改这里。 */
export type RegionCode =
  | 'eu-west'
  | 'eu-central'
  | 'na-east'
  | 'na-west'
  | 'apac-sg'
  | 'apac-jp'
  | 'latam-br'
  | 'mea-ae';

/** `X-OF-Actor-Kind` 的取值。审计台账里还多一个 `system`，见 {@link LedgerActorKind}。 */
export type ActorKind = 'user' | 'service' | 'device' | 'partner';

/** `platform.audit_ledger_entries.actor_kind`，比请求头多 `system`（定时任务写入）。 */
export type LedgerActorKind = ActorKind | 'system';

/** `freight.shipments.status`。状态机只能由 `PATCH /v1/shipments/{shipment_id}/status` 驱动。 */
export type ShipmentStatus =
  | 'draft'
  | 'booked'
  | 'sealed'
  | 'in_transit'
  | 'at_risk'
  | 'held_at_customs'
  | 'delivered'
  | 'cancelled';

/** `freight.shipment_scan_events.scan_type`。`proof_of_delivery` 是 billing-service 唯一关心的一种。 */
export type ScanType =
  | 'gate_in'
  | 'gate_out'
  | 'load'
  | 'unload'
  | 'seal_check'
  | 'customs_inspection'
  | 'damage_report'
  | 'proof_of_delivery';

/** `freight.facilities.kind`。 */
export type FacilityKind =
  | 'seaport'
  | 'airport'
  | 'rail_terminal'
  | 'warehouse'
  | 'customer_site'
  | 'bonded_store';

/** `fleet.vehicles.vehicle_class`。 */
export type VehicleClass =
  | 'van'
  | 'rigid'
  | 'tractor'
  | 'chassis'
  | 'reefer_tractor'
  | 'rail_wagon'
  | 'barge';

/** `routing.route_legs.mode`，同时也是 mv_lane_performance_daily 的 primary_mode。 */
export type TransportMode = 'road' | 'rail' | 'sea' | 'air' | 'barge';

/** `routing.routes.strategy`。`manual` 表示调度员手工排的线，不参与 ETA 模型回灌。 */
export type RouteStrategy =
  | 'cheapest'
  | 'fastest'
  | 'lowest_carbon'
  | 'customs_optimised'
  | 'manual';

/** `telemetry.telemetry_alerts.rule_code`，阈值本身在 telemetry-ingest 的 OF_TELEMETRY_RULES_PATH 里。 */
export type AlertRuleCode =
  | 'temp_excursion_high'
  | 'temp_excursion_low'
  | 'humidity_high'
  | 'shock_impact'
  | 'door_open_in_transit'
  | 'battery_critical'
  | 'gateway_silent'
  | 'geofence_breach';

/** 告警严重度 1–5，与 `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` 比较后决定运单是否翻成 at_risk。 */
export type AlertSeverity = 1 | 2 | 3 | 4 | 5;

/** `customs.customs_declarations.status`。`amended` 是补充申报，`mrn` 不变。 */
export type DeclarationStatus =
  | 'draft'
  | 'submitted'
  | 'under_review'
  | 'held'
  | 'cleared'
  | 'rejected'
  | 'amended';

/** `customs.customs_declarations.direction`。 */
export type DeclarationDirection = 'import' | 'export' | 'transit';

/** `billing.invoices.status`。`on_hold` 只可能由 reconciliation.discrepancy.opened 造成。 */
export type InvoiceStatus =
  | 'draft'
  | 'issued'
  | 'part_paid'
  | 'settled'
  | 'on_hold'
  | 'void'
  | 'written_off';

/** `billing.invoice_lines.charge_code`。 */
export type ChargeCode =
  | 'linehaul'
  | 'fuel_surcharge'
  | 'demurrage'
  | 'detention'
  | 'reefer_power'
  | 'customs_clearance'
  | 'duty_disbursement'
  | 'hazmat_handling'
  | 'waiting_time';

/** `billing.payments.method`。 */
export type PaymentMethod = 'sepa_dd' | 'swift' | 'card' | 'credit_note' | 'cash';

/** `platform.documents.owner_type`，取值受 `platform.document_owner_types` 这张词表约束。 */
export type DocumentOwnerType =
  | 'shipment'
  | 'container'
  | 'scan'
  | 'declaration'
  | 'invoice'
  | 'carrier';

/** `platform.documents.kind`。 */
export type DocumentKind =
  | 'bill_of_lading'
  | 'commercial_invoice'
  | 'packing_list'
  | 'certificate_of_origin'
  | 'proof_of_delivery'
  | 'damage_photo'
  | 'insurance_certificate'
  | 'customs_decision'
  | 'rendered_invoice'
  | 'credit_note';

/** `platform.notifications.channel`。控制台自己只订阅 `console` 这一路。 */
export type NotificationChannel = 'email' | 'sms' | 'push' | 'webhook' | 'console';

/** `platform.notifications.state`。 */
export type NotificationState = 'queued' | 'sending' | 'sent' | 'failed' | 'suppressed';

/** `analytics.reconciliation_discrepancies.kind`。 */
export type DiscrepancyKind =
  | 'missing_declaration'
  | 'missing_invoice'
  | 'duty_mismatch'
  | 'weight_mismatch'
  | 'orphan_payment'
  | 'unbilled_accessorial'
  | 'cleared_without_payment';

/** `analytics.reconciliation_discrepancies.state`。 */
export type DiscrepancyState = 'open' | 'acknowledged' | 'resolved' | 'waived';

/** ISO 4217 三字母币种，永远与某个 `*_minor` 字段成对出现（SPEC §0.2）。 */
export type CurrencyCode = string;

/** ISO 3166-1 alpha-2，大写。 */
export type CountryCode = string;

/** WGS84 经纬度。geo-service 的 GeoJSON 输出与遥测读数共用这一种形状。 */
export interface LatLon {
  readonly lat: number;
  readonly lon: number;
}

/**
 * 运单摘要 —— `GET /v1/shipments/{shipment_id}` 的响应去掉内联集装箱之后的部分。
 * 看板列表只需要这些字段，详情页才会去取完整对象。
 */
export interface ShipmentSummary {
  readonly shipment_id: ShipmentId;
  readonly tenant_id: TenantId;
  readonly reference: string;
  readonly origin_facility_id: FacilityId;
  readonly destination_facility_id: FacilityId;
  readonly incoterm: string;
  readonly status: ShipmentStatus;
  readonly sla_deadline_at: string | null;
  readonly declared_value_minor: number;
  readonly currency: CurrencyCode;
  readonly region_code: RegionCode;
  readonly created_at: string;
  readonly delivered_at: string | null;
}

/** `POST /v1/shipments/{shipment_id}/containers` 之后内联回来的配箱信息。 */
export interface ShipmentContainer {
  readonly container_id: ContainerId;
  readonly iso_code: string;
  readonly iso_size_type: string;
  readonly seal_number: string;
  readonly gross_kg: number;
  readonly is_reefer: boolean;
  readonly setpoint_c: number | null;
  readonly loaded_at: string | null;
  readonly unloaded_at: string | null;
}

/** 报关单摘要，来自 `GET /v1/shipments/{shipment_id}/declarations`。 */
export interface DeclarationSummary {
  readonly declaration_id: DeclarationId;
  readonly shipment_id: ShipmentId;
  readonly crossing_id: CrossingId;
  readonly customs_office_code: string;
  readonly direction: DeclarationDirection;
  readonly status: DeclarationStatus;
  readonly mrn: string | null;
  readonly assessed_duty_minor: number | null;
  readonly assessed_vat_minor: number | null;
  readonly currency: CurrencyCode;
  readonly duty_paid: boolean;
  readonly filed_at: string | null;
  readonly cleared_at: string | null;
}

/** 发票摘要，来自 `GET /v1/invoices/{invoice_id}`。 */
export interface InvoiceSummary {
  readonly invoice_id: InvoiceId;
  readonly tenant_id: TenantId;
  readonly shipment_id: ShipmentId;
  readonly invoice_number: string | null;
  readonly currency: CurrencyCode;
  readonly subtotal_minor: number;
  readonly duty_minor: number;
  readonly tax_minor: number;
  readonly total_minor: number;
  readonly status: InvoiceStatus;
  readonly hold_reason: string | null;
  readonly issued_at: string | null;
  readonly due_on: string | null;
  readonly settled_at: string | null;
}

/** `GET /v1/geofences/{geofence_id}` 返回的 GeoJSON 包装，供地图图层直接消费。 */
export interface GeofenceFeature {
  readonly geofence_id: GeofenceId;
  readonly name: string;
  readonly kind: 'facility' | 'depot' | 'border_zone' | 'restricted' | 'customer_site' | 'corridor';
  readonly buffer_m: number;
  readonly dwell_alert_minutes: number | null;
  readonly boundary: { type: 'Polygon'; coordinates: ReadonlyArray<ReadonlyArray<[number, number]>> };
}

/** 承运人在列表里的最小投影，派车抽屉里用。 */
export interface CarrierRef {
  readonly carrier_id: CarrierId;
  readonly name: string;
  readonly scac_code: string | null;
  readonly country_code: CountryCode;
  readonly is_subcontractor: boolean;
  readonly insurance_expires_on: string;
}

/** 操作人的显示信息，用于时间线上的头像与姓名。 */
export interface ActorRef {
  readonly actor_kind: LedgerActorKind;
  readonly actor_id: UserId | string;
  readonly display_name: string;
}
