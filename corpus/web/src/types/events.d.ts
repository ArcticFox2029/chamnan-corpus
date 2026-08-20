/*
 * SPEC §0.7 的事件信封，以及控制台实际会渲染的那几个 payload 的类型。
 * 控制台不直接连 Kafka —— 它订阅 notification-service 的 console 通道，
 * 拿到的是原样透传的信封，所以这里的形状必须和后端消费者看到的完全一致。
 */

import type {
  AlertId,
  AssignmentId,
  ContainerId,
  DeclarationId,
  DocumentId,
  DiscrepancyId,
  DriverId,
  EventId,
  InvoiceId,
  LegId,
  PaymentId,
  ReadingId,
  ReconciliationRunId,
  RouteId,
  ScanId,
  ShipmentId,
  TenantId,
  TraceId,
  UserId,
  VehicleId,
} from './ids';
import type {
  AlertRuleCode,
  AlertSeverity,
  CurrencyCode,
  DiscrepancyKind,
  DocumentKind,
  DocumentOwnerType,
  LatLon,
  RegionCode,
  RouteStrategy,
  ScanType,
  ShipmentStatus,
} from './domain';

/** SPEC §4 的六个主题。DLQ 主题是 `${OfTopic}.dlq`，控制台不订阅。 */
export type OfTopic =
  | 'of.identity.v1'
  | 'of.freight.v1'
  | 'of.telemetry.v1'
  | 'of.customs.v1'
  | 'of.billing.v1'
  | 'of.platform.v1';

/** SPEC §1 里的服务名，用作信封的 `producer`。 */
export type ProducerService =
  | 'identity-service'
  | 'fleet-service'
  | 'container-registry'
  | 'telemetry-ingest'
  | 'routing-service'
  | 'geo-service'
  | 'customs-service'
  | 'billing-service'
  | 'document-service'
  | 'notification-service'
  | 'partner-portal-api'
  | 'analytics-pipeline'
  | 'audit-ledger'
  | 'reconciliation-service';

/**
 * 统一信封。只有 `payload` 随事件变化，其余字段每个主题都一样。
 *
 * @typeParam N - 事件名，dotted.lower.case。
 * @typeParam P - 该事件的 payload 形状。
 */
export interface EventEnvelope<N extends string, P> {
  readonly event_id: EventId;
  readonly event_name: N;
  readonly schema_version: number;
  readonly occurred_at: string;
  readonly tenant_id: TenantId;
  readonly region_code: RegionCode;
  readonly producer: ProducerService;
  readonly trace_id: TraceId;
  /** 以 `shipment_id` 为键的事件，其顺序是平台唯一保证的顺序。 */
  readonly partition_key: string;
  readonly payload: P;
}

/** `shipment.created` —— container-registry 发布。 */
export interface ShipmentCreatedPayload {
  readonly shipment_id: ShipmentId;
  readonly tenant_id: TenantId;
  readonly reference: string;
  readonly origin_facility_id: string;
  readonly destination_facility_id: string;
  readonly incoterm: string;
  readonly sla_deadline_at: string | null;
  readonly region_code: RegionCode;
  readonly created_by: UserId;
}

/** `shipment.scanned` —— 运单时间线上最密集的一类条目。 */
export interface ShipmentScannedPayload {
  readonly scan_id: ScanId;
  readonly shipment_id: ShipmentId;
  readonly container_id: ContainerId | null;
  readonly scan_type: ScanType;
  readonly facility_id: string | null;
  readonly scanned_by_user_id: UserId;
  readonly occurred_at: string;
  /** 离线扫描回传时会明显晚于 `occurred_at`，超过容差的那些要在界面上标出来。 */
  readonly recorded_at: string;
  readonly position: LatLon | null;
  readonly device_serial: string | null;
}

/** `shipment.status.changed` —— 状态徽章的唯一变更来源。 */
export interface ShipmentStatusChangedPayload {
  readonly shipment_id: ShipmentId;
  readonly tenant_id: TenantId;
  readonly from_status: ShipmentStatus;
  readonly to_status: ShipmentStatus;
  readonly reason_code: string;
  readonly changed_by: string;
  readonly changed_at: string;
}

/** `fleet.assignment.created` —— fleet-service 在 `fleet.v1.FleetService/Assign` 成功后发布。 */
export interface FleetAssignmentCreatedPayload {
  readonly assignment_id: AssignmentId;
  readonly shipment_id: ShipmentId;
  readonly leg_id: LegId | null;
  readonly vehicle_id: VehicleId;
  readonly driver_id: DriverId;
  readonly carrier_id: string;
  readonly assigned_at: string;
  readonly assigned_by: string;
}

/** `fleet.assignment.released`。 */
export interface FleetAssignmentReleasedPayload {
  readonly assignment_id: AssignmentId;
  readonly shipment_id: ShipmentId;
  readonly vehicle_id: VehicleId;
  readonly driver_id: DriverId;
  readonly released_at: string;
  readonly distance_travelled_m: number;
  readonly release_reason: string;
}

/**
 * `telemetry.alert.raised` —— 告警面板的实时来源。
 * 注意这同时也是 container-registry 把运单翻成 `at_risk` 的那条边，
 * 所以界面上几乎总会紧跟着一条 `shipment.status.changed`；两者要合并成一行显示。
 */
export interface TelemetryAlertRaisedPayload {
  readonly alert_id: AlertId;
  readonly container_id: ContainerId;
  readonly shipment_id: ShipmentId | null;
  readonly rule_code: AlertRuleCode;
  readonly severity: AlertSeverity;
  readonly threshold_value: number;
  readonly peak_value: number | null;
  readonly first_reading_id: ReadingId;
  readonly opened_at: string;
}

/** `telemetry.reading.recorded`。已按 `OF_TELEMETRY_PUBLISH_SAMPLE_RATE` 抽样，别当成完整曲线画。 */
export interface TelemetryReadingRecordedPayload {
  readonly reading_id: ReadingId;
  readonly region_code: RegionCode;
  readonly container_id: ContainerId;
  readonly shipment_id: ShipmentId | null;
  readonly gateway_id: string;
  readonly recorded_at: string;
  readonly temperature_c: number | null;
  readonly humidity_pct: number | null;
  readonly shock_g: number | null;
  readonly door_open: boolean | null;
  readonly battery_pct: number | null;
  readonly position: LatLon | null;
}

/** `route.replanned` —— routing-service 发布；fleet-service 据此释放失效路段的派车。 */
export interface RouteReplannedPayload {
  readonly route_id: RouteId;
  readonly shipment_id: ShipmentId;
  readonly previous_version: number;
  readonly version: number;
  readonly strategy: RouteStrategy;
  readonly reason_code: string;
  readonly total_distance_m: number;
  readonly total_duration_s: number;
  readonly legs_changed: ReadonlyArray<LegId>;
  readonly computed_at: string;
}

/** `customs.declaration.filed`。 */
export interface CustomsDeclarationFiledPayload {
  readonly declaration_id: DeclarationId;
  readonly shipment_id: ShipmentId;
  readonly crossing_id: string;
  readonly customs_office_code: string;
  readonly direction: 'import' | 'export' | 'transit';
  readonly mrn: string | null;
  readonly line_count: number;
  readonly assessed_duty_minor: number | null;
  readonly assessed_vat_minor: number | null;
  readonly currency: CurrencyCode;
  readonly filed_at: string;
  readonly filed_by: string;
}

/** `customs.declaration.cleared` —— billing-service 就是在这里拿到最终税额的。 */
export interface CustomsDeclarationClearedPayload {
  readonly declaration_id: DeclarationId;
  readonly shipment_id: ShipmentId;
  readonly mrn: string;
  readonly cleared_at: string;
  readonly assessed_duty_minor: number;
  readonly assessed_vat_minor: number;
  readonly currency: CurrencyCode;
  readonly inspection_performed: boolean;
  readonly decision_document_id: DocumentId | null;
}

/** `billing.invoice.issued`。 */
export interface BillingInvoiceIssuedPayload {
  readonly invoice_id: InvoiceId;
  readonly tenant_id: TenantId;
  readonly shipment_id: ShipmentId;
  readonly invoice_number: string;
  readonly currency: CurrencyCode;
  readonly subtotal_minor: number;
  readonly duty_minor: number;
  readonly tax_minor: number;
  readonly total_minor: number;
  readonly due_on: string;
  readonly rendered_document_id: DocumentId | null;
  readonly issued_at: string;
}

/**
 * `billing.invoice.settled`。这是 customs-service 得知税款已付的唯一途径，
 * 也是 `customs.customs_declarations.duty_paid` 唯一的写入来源；
 * 控制台在报关详情页上把这条事件显示成「税款已结清」的时间戳。
 */
export interface BillingInvoiceSettledPayload {
  readonly invoice_id: InvoiceId;
  readonly tenant_id: TenantId;
  readonly shipment_id: ShipmentId;
  readonly declaration_id: DeclarationId | null;
  readonly total_minor: number;
  readonly currency: CurrencyCode;
  readonly settled_at: string;
  readonly final_payment_id: PaymentId;
}

/** `document.uploaded` —— document-service 发布，附件抽屉据此增量刷新。 */
export interface DocumentUploadedPayload {
  readonly document_id: DocumentId;
  readonly tenant_id: TenantId;
  readonly owner_type: DocumentOwnerType;
  readonly owner_id: string;
  readonly kind: DocumentKind;
  readonly mime_type: string;
  readonly byte_size: number;
  /** 十六进制的 `platform.documents.sha256`；重复上传会命中同一个 doc_ id。 */
  readonly sha256: string;
  readonly region_code: RegionCode;
  readonly uploaded_by: string;
  readonly uploaded_at: string;
}

/** `reconciliation.discrepancy.opened` —— 发票被挂起的原因就在这里。 */
export interface ReconciliationDiscrepancyOpenedPayload {
  readonly discrepancy_id: DiscrepancyId;
  readonly run_id: ReconciliationRunId;
  readonly tenant_id: TenantId;
  readonly shipment_id: ShipmentId;
  readonly declaration_id: DeclarationId | null;
  readonly invoice_id: InvoiceId | null;
  readonly kind: DiscrepancyKind;
  readonly expected_minor: number | null;
  readonly observed_minor: number | null;
  readonly currency: CurrencyCode | null;
  readonly opened_at: string;
}

/** 控制台会渲染的全部事件的判别联合。未列出的事件到达时按未知类型静默丢弃。 */
export type ConsoleEvent =
  | EventEnvelope<'shipment.created', ShipmentCreatedPayload>
  | EventEnvelope<'shipment.scanned', ShipmentScannedPayload>
  | EventEnvelope<'shipment.status.changed', ShipmentStatusChangedPayload>
  | EventEnvelope<'fleet.assignment.created', FleetAssignmentCreatedPayload>
  | EventEnvelope<'fleet.assignment.released', FleetAssignmentReleasedPayload>
  | EventEnvelope<'telemetry.alert.raised', TelemetryAlertRaisedPayload>
  | EventEnvelope<'telemetry.reading.recorded', TelemetryReadingRecordedPayload>
  | EventEnvelope<'route.replanned', RouteReplannedPayload>
  | EventEnvelope<'customs.declaration.filed', CustomsDeclarationFiledPayload>
  | EventEnvelope<'customs.declaration.cleared', CustomsDeclarationClearedPayload>
  | EventEnvelope<'billing.invoice.issued', BillingInvoiceIssuedPayload>
  | EventEnvelope<'billing.invoice.settled', BillingInvoiceSettledPayload>
  | EventEnvelope<'document.uploaded', DocumentUploadedPayload>
  | EventEnvelope<'reconciliation.discrepancy.opened', ReconciliationDiscrepancyOpenedPayload>;

/** 事件名到 payload 的映射，供订阅函数按名字取回正确的形状。 */
export type ConsoleEventName = ConsoleEvent['event_name'];

/** 取出某个事件名对应的信封类型。 */
export type EnvelopeOf<N extends ConsoleEventName> = Extract<ConsoleEvent, { event_name: N }>;
