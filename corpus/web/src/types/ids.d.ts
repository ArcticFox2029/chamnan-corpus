/*
 * 把 SPEC §0.1 的「前缀 ULID」抬进类型系统。控制台里同时握着 shipment_id、
 * declaration_id、invoice_id 三个长得一模一样的字符串，一旦传错位置，后端只会
 * 回一个 404，排查成本远高于在编译期挡住它。这里用 branded type 让每种主键互不兼容。
 */

/**
 * 品牌化字符串。`__ofPrefix` 只存在于类型层面，运行时永远是一个普通 string。
 *
 * @typeParam P - SPEC §0.1 表格里的前缀，含下划线，例如 `'shp_'`。
 */
export type PrefixedUlid<P extends string> = string & {
  readonly __ofPrefix: P;
};

/** 租户。等同 `identity.tenants.tenant_id`，也是 `X-OF-Tenant` 头的取值。 */
export type TenantId = PrefixedUlid<'tnt_'>;
/** 组织单元。`identity.org_units.org_unit_id`；控制台的权限树按它展开。 */
export type OrgUnitId = PrefixedUlid<'org_'>;
/** 用户。`identity.users.user_id`。 */
export type UserId = PrefixedUlid<'usr_'>;
/** 会话。`identity.sessions.session_id`，撤销单个会话时用。 */
export type SessionId = PrefixedUlid<'ses_'>;
/** API 凭据。`identity.api_credentials.credential_id`。 */
export type CredentialId = PrefixedUlid<'cred_'>;

/** 承运人。`fleet.carriers.carrier_id`。 */
export type CarrierId = PrefixedUlid<'car_'>;
/** 车辆。`fleet.vehicles.vehicle_id`。 */
export type VehicleId = PrefixedUlid<'veh_'>;
/** 司机。`fleet.drivers.driver_id`。 */
export type DriverId = PrefixedUlid<'drv_'>;
/** 派车记录。`fleet.vehicle_assignments.assignment_id`。 */
export type AssignmentId = PrefixedUlid<'asg_'>;
/** 堆场。`fleet.depots.depot_id`。 */
export type DepotId = PrefixedUlid<'dep_'>;

/** 场站。`freight.facilities.facility_id`。 */
export type FacilityId = PrefixedUlid<'fac_'>;
/** 集装箱。`freight.containers.container_id`。 */
export type ContainerId = PrefixedUlid<'cnt_'>;
/** 运单。`freight.shipments.shipment_id`，也是 of.freight.v1 上的 partition_key。 */
export type ShipmentId = PrefixedUlid<'shp_'>;
/** 扫描事件。`freight.shipment_scan_events.scan_id`。 */
export type ScanId = PrefixedUlid<'scn_'>;

/** 路线。`routing.routes.route_id`。 */
export type RouteId = PrefixedUlid<'rte_'>;
/** 路段。`routing.route_legs.leg_id`。 */
export type LegId = PrefixedUlid<'leg_'>;
/** 围栏。`geo.geofences.geofence_id`。 */
export type GeofenceId = PrefixedUlid<'gfn_'>;
/** 口岸。`geo.border_crossings.crossing_id`。 */
export type CrossingId = PrefixedUlid<'bxg_'>;

/** 网关。`telemetry.device_gateways.gateway_id`。 */
export type GatewayId = PrefixedUlid<'gwy_'>;
/** 遥测读数。`telemetry.telemetry_readings.reading_id`。 */
export type ReadingId = PrefixedUlid<'rdg_'>;
/** 遥测告警。`telemetry.telemetry_alerts.alert_id`。 */
export type AlertId = PrefixedUlid<'alr_'>;

/** 报关单。`customs.customs_declarations.declaration_id`。 */
export type DeclarationId = PrefixedUlid<'dcl_'>;
/** 报关单行。`customs.declaration_line_items.line_id`。 */
export type LineItemId = PrefixedUlid<'lin_'>;
/** 税则版本行。`customs.tariff_schedules.tariff_id`。 */
export type TariffId = PrefixedUlid<'trf_'>;

/** 发票。`billing.invoices.invoice_id`。 */
export type InvoiceId = PrefixedUlid<'inv_'>;
/** 发票行。`billing.invoice_lines.invoice_line_id`。 */
export type InvoiceLineId = PrefixedUlid<'ivl_'>;
/** 付款。`billing.payments.payment_id`。 */
export type PaymentId = PrefixedUlid<'pay_'>;

/** 文档。`platform.documents.document_id`，由 document-service 分配。 */
export type DocumentId = PrefixedUlid<'doc_'>;
/** 通知。`platform.notifications.notification_id`。 */
export type NotificationId = PrefixedUlid<'ntf_'>;
/** 事件信封 id。`platform.outbox_messages.message_id`，消费端据此去重。 */
export type EventId = PrefixedUlid<'evt_'>;

/** 对账批次。`analytics.reconciliation_runs.run_id`。 */
export type ReconciliationRunId = PrefixedUlid<'rec_'>;
/** 对账差异。`analytics.reconciliation_discrepancies.discrepancy_id`。 */
export type DiscrepancyId = PrefixedUlid<'dsc_'>;
/** analytics-pipeline 的作业运行 id。 */
export type AnalyticsJobRunId = PrefixedUlid<'job_'>;

/**
 * W3C trace-id：32 位小写十六进制。缺失时由 web/proxy 的 request_headers.lua 生成，
 * 之后原样透传给每一个下游服务 —— geo-service 的 30 秒 per-trace 缓存（SPEC §1.2 Diamond A）
 * 依赖的就是这个值不被中途换掉。
 */
export type TraceId = string & { readonly __ofTrace: unique symbol };

/**
 * 运行时校验：仅检查前缀与 base32 长度，不做 ULID 时间戳解析。
 * URL 里拿到的 id 在进 API 层之前都要过一遍，避免把用户乱贴的字符串打到后端。
 */
export declare function assertPrefixed<P extends string>(
  value: string,
  prefix: P,
): asserts value is PrefixedUlid<P>;

/** 只读取前缀，用于把一个来路不明的 id 路由到正确的详情页。 */
export declare function prefixOf(value: string): string | null;
