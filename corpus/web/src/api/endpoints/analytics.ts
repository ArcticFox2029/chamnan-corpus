/*
 * analytics-pipeline 的两个指标接口，外加对账差异的读取。
 * 这里返回的每一行都来自物化视图，不是实时数据 —— mv_lane_performance_daily
 * 每天 03:15 UTC 才刷一次，界面必须把「数据截至」的时间点显式画出来，
 * 否则调度员会拿昨天的准点率去解释今天早上的延误。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type {
  CurrencyCode,
  DiscrepancyKind,
  DiscrepancyState,
  TransportMode,
} from '../../types/domain';
import type {
  DeclarationId,
  DiscrepancyId,
  InvoiceId,
  ReconciliationRunId,
  ShipmentId,
  TenantId,
} from '../../types/ids';

const ANALYTICS = 'analytics-pipeline' as const;
const RECONCILIATION = 'reconciliation-service' as const;

/** `analytics.mv_lane_performance_daily` 的一行，经 `GET /v1/metrics/lane-performance` 暴露。 */
export interface LanePerformanceRow {
  readonly tenant_id: TenantId;
  readonly business_date: string;
  /** 五位 UN/LOCODE，来自 `freight.facilities.unlocode`。 */
  readonly origin_unlocode: string;
  readonly destination_unlocode: string;
  /** 视图取的是该运单里距离最长的那一段的运输方式。 */
  readonly primary_mode: TransportMode;
  readonly shipment_count: number;
  readonly on_time_count: number;
  readonly avg_transit_seconds: number;
  readonly p95_transit_seconds: number;
  /** 该航线当天累计的温控等告警条数。 */
  readonly excursion_alerts: number;
}

/** `analytics.mv_container_utilisation_weekly` 的一行。 */
export interface ContainerUtilisationRow {
  readonly container_id: string;
  readonly iso_size_type: string;
  readonly week_start: string;
  readonly trips: number;
  readonly total_gross_kg: number;
  readonly max_gross_kg: number;
  /** 已经是百分数（两位小数），不要再乘 100。 */
  readonly fill_rate_pct: number;
}

/** 对账差异，来自 reconciliation-service 的 `GET /v1/discrepancies`。 */
export interface Discrepancy {
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
  readonly state: DiscrepancyState;
  readonly opened_at: string;
  readonly resolved_at: string | null;
  readonly resolution_note: string | null;
}

/**
 * 航线绩效。日期区间是闭区间，最长 180 天 —— 再宽就该走导出而不是页面查询了。
 * routing-service 用的是同一份视图来做 ETA 先验，所以这里看到的准点率
 * 和它排线时用的历史耗时是同一个数，两边不会打架。
 */
export function getLanePerformance(
  client: ApiClient,
  query: { from_date: string; to_date: string; origin_unlocode?: string; destination_unlocode?: string },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<LanePerformanceRow>> {
  return fetchPage<LanePerformanceRow>(
    client,
    ANALYTICS,
    '/v1/metrics/lane-performance',
    { ...request, filters: { ...request?.filters, ...query } },
    options,
  );
}

/** 空箱利用率周报，「闲置箱」页面的数据源。 */
export function getContainerUtilisation(
  client: ApiClient,
  query: { week_start_from: string; week_start_to: string; iso_size_type?: string },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<ContainerUtilisationRow>> {
  return fetchPage<ContainerUtilisationRow>(
    client,
    ANALYTICS,
    '/v1/metrics/container-utilisation',
    { ...request, filters: { ...request?.filters, ...query } },
    options,
  );
}

/**
 * 未处理的对账差异。
 *
 * `duty_mismatch` 和 `cleared_without_payment` 这两类通常已经让 billing-service
 * 把发票挂起了（它消费 reconciliation.discrepancy.opened），所以列表里应当
 * 顺带把 `invoice_id` 链到发票页，让处理的人一眼看到被挂的是哪一张。
 */
export function listOpenDiscrepancies(
  client: ApiClient,
  filters: { kind?: DiscrepancyKind; state?: DiscrepancyState },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<Discrepancy>> {
  return fetchPage<Discrepancy>(
    client,
    RECONCILIATION,
    '/v1/discrepancies',
    { ...request, filters: { state: 'open', ...request?.filters, ...filters } },
    options,
  );
}

/** 处理或豁免一条差异，必须留说明；说明会进审计台账。 */
export function resolveDiscrepancy(
  client: ApiClient,
  discrepancyId: DiscrepancyId,
  outcome: 'resolved' | 'waived',
  note: string,
  options?: RequestOptions,
): Promise<Discrepancy> {
  return client.post<Discrepancy>(RECONCILIATION, `/v1/discrepancies/${discrepancyId}/resolve`, {
    ...options,
    body: { outcome, resolution_note: note },
  });
}

/** 准点率。分母为 0 时返回 null，让界面显示「—」而不是 0%。 */
export function onTimeRate(row: LanePerformanceRow): number | null {
  if (row.shipment_count === 0) return null;
  return row.on_time_count / row.shipment_count;
}
