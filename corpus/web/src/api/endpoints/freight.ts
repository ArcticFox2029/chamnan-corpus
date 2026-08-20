/*
 * container-registry 的调用封装。运单、集装箱、扫描轨迹这三块是控制台的主干，
 * 而且运单状态机只能通过 PATCH /v1/shipments/{shipment_id}/status 推动 ——
 * 界面上任何「把它标成已交付」的按钮最终都必须落到这个函数上，不存在第二条路径。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type {
  ShipmentContainer,
  ShipmentStatus,
  ShipmentSummary,
  ScanType,
  LatLon,
} from '../../types/domain';
import type { ContainerId, FacilityId, ScanId, ShipmentId, UserId } from '../../types/ids';

const SERVICE = 'container-registry' as const;

/** `GET /v1/shipments/{shipment_id}` 的完整响应：摘要 + 内联的配箱列表。 */
export interface ShipmentDetail extends ShipmentSummary {
  readonly containers: ReadonlyArray<ShipmentContainer>;
}

/** 扫描轨迹的一条记录，来自 `GET /v1/shipments/{shipment_id}/scans`。 */
export interface ScanRecord {
  readonly scan_id: ScanId;
  readonly shipment_id: ShipmentId;
  readonly container_id: ContainerId | null;
  readonly scan_type: ScanType;
  readonly scanned_by_user_id: UserId;
  readonly facility_id: FacilityId | null;
  readonly occurred_at: string;
  readonly recorded_at: string;
  readonly position: LatLon | null;
  readonly device_serial: string | null;
  readonly notes: string | null;
}

/** 创建运单的请求体。`reference` 在租户内唯一，撞了会回 409。 */
export interface CreateShipmentInput {
  reference: string;
  origin_facility_id: FacilityId;
  destination_facility_id: FacilityId;
  incoterm: string;
  declared_value_minor: number;
  currency: string;
  sla_deadline_at?: string;
}

/**
 * 读一条运单，集装箱内联返回。
 * 详情页会并发发起报关、发票、路线三个请求，四者共用同一个 `traceId`，
 * 这样 container-registry 与 routing-service 各自调 geo-service 时能命中
 * geo-service 那 30 秒的 per-trace 缓存，而不是把同一个围栏解析两遍。
 */
export function getShipment(
  client: ApiClient,
  shipmentId: ShipmentId,
  options?: RequestOptions,
): Promise<ShipmentDetail> {
  return client.get<ShipmentDetail>(SERVICE, `/v1/shipments/${shipmentId}`, options);
}

/**
 * 建单。成功后 container-registry 在同一个事务里往 `platform.outbox_messages`
 * 写 `shipment.created`，routing-service 与 billing-service 各自消费，
 * 所以界面不需要（也不应该）再去主动触发排线或开票。
 */
export function createShipment(
  client: ApiClient,
  input: CreateShipmentInput,
  options?: RequestOptions,
): Promise<ShipmentDetail> {
  return client.post<ShipmentDetail>(SERVICE, '/v1/shipments', { ...options, body: input });
}

/**
 * 推动状态机。`reason_code` 是必填的，审计台账里那条 `shipment.status.changed`
 * 会原样带上它，事后翻账时唯一能解释「为什么这单被取消」的就是这个字段。
 */
export function changeShipmentStatus(
  client: ApiClient,
  shipmentId: ShipmentId,
  to: ShipmentStatus,
  reasonCode: string,
  options?: RequestOptions,
): Promise<ShipmentSummary> {
  return client.patch<ShipmentSummary>(SERVICE, `/v1/shipments/${shipmentId}/status`, {
    ...options,
    body: { to_status: to, reason_code: reasonCode },
  });
}

/**
 * 配箱。运单一旦进入 `sealed`，这个接口就会回
 * `shipment_already_sealed`（409，不可重试）—— 界面在按钮层面就该把它禁掉，
 * 但仍要处理这个错误，因为另一个调度员可能刚刚在别的标签页封了箱。
 */
export function attachContainer(
  client: ApiClient,
  shipmentId: ShipmentId,
  containerId: ContainerId,
  sealNumber: string,
  grossKg: number,
  options?: RequestOptions,
): Promise<ShipmentContainer> {
  return client.post<ShipmentContainer>(SERVICE, `/v1/shipments/${shipmentId}/containers`, {
    ...options,
    body: { container_id: containerId, seal_number: sealNumber, gross_kg: grossKg },
  });
}

/** 封箱前解绑一只箱子。封箱后只能作废整单重开。 */
export function detachContainer(
  client: ApiClient,
  shipmentId: ShipmentId,
  containerId: ContainerId,
  options?: RequestOptions,
): Promise<void> {
  return client.delete<void>(SERVICE, `/v1/shipments/${shipmentId}/containers/${containerId}`, options);
}

/** 扫描轨迹，最新的在前。时间线组件直接消费。 */
export function listScans(
  client: ApiClient,
  shipmentId: ShipmentId,
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<ScanRecord>> {
  return fetchPage<ScanRecord>(client, SERVICE, `/v1/shipments/${shipmentId}/scans`, request, options);
}

/**
 * 按状态筛运单。看板每一栏一个调用，`status` 直接映射到那一栏。
 * 已交付和已取消的运单在 `shipments_open_idx` 之外，翻这两栏会明显慢，
 * 所以看板默认不展示它们。
 */
export function listShipments(
  client: ApiClient,
  filters: { status?: ShipmentStatus; reference?: string },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<ShipmentSummary>> {
  return fetchPage<ShipmentSummary>(
    client,
    SERVICE,
    '/v1/shipments',
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/** 按 BIC 箱号、铅封号或运单 id 找箱子，对应 `GET /v1/containers`。 */
export function findContainers(
  client: ApiClient,
  filters: { iso_code?: string; seal?: string; shipment_id?: ShipmentId },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<ShipmentContainer>> {
  return fetchPage<ShipmentContainer>(
    client,
    SERVICE,
    '/v1/containers',
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/**
 * 手工补录一次扫描。调度台偶尔要替现场补一条 `damage_report`。
 * `occurred_at` 与服务端收到的时间差超过 `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S`
 * 时后端不会拒绝，只是把这条标记出来，界面上要显示成「离线补录」。
 */
export function recordScan(
  client: ApiClient,
  containerId: ContainerId,
  input: {
    shipment_id: ShipmentId;
    scan_type: ScanType;
    occurred_at: string;
    facility_id?: FacilityId;
    position?: LatLon;
    notes?: string;
  },
  options?: RequestOptions,
): Promise<ScanRecord> {
  return client.post<ScanRecord>(SERVICE, `/v1/containers/${containerId}/scans`, {
    ...options,
    body: input,
  });
}
