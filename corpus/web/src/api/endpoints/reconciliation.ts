/*
 * reconciliation-service 的调用封装。每晚的三方核对（运单 / 报关单 / 发票）
 * 产生的差异在这里被取出来给财务看。要点是差异一旦打开，billing-service
 * 会消费 reconciliation.discrepancy.opened 把发票挂起 —— 所以在控制台上
 * 「解决差异」并不会自动解挂发票，那需要财务再去 billing 那边动作。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type {
  CurrencyCode,
  DiscrepancyKind,
  DiscrepancyState,
} from '../../types/domain';
import type {
  DeclarationId,
  DiscrepancyId,
  InvoiceId,
  ReconciliationRunId,
  ShipmentId,
  TenantId,
  UserId,
} from '../../types/ids';

const SERVICE = 'reconciliation-service' as const;

/** 一次核对运行。同一个 (租户, 业务日, 引擎版本) 只会有一条。 */
export interface ReconciliationRun {
  readonly run_id: ReconciliationRunId;
  readonly tenant_id: TenantId;
  readonly business_date: string;
  readonly started_at: string;
  readonly finished_at: string | null;
  readonly state: 'running' | 'succeeded' | 'failed' | 'partial';
  readonly shipments_examined: number;
  readonly discrepancies_opened: number;
  /** OF_RECON_ENGINE_VERSION 的值；换版本会重新跑同一个业务日。 */
  readonly engine_version: string;
}

/** 一条差异。金额字段在 `kind` 不涉及金额时为 null。 */
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
  readonly resolved_by: UserId | null;
  readonly resolution_note: string | null;
}

/**
 * 手工发起一次核对。
 *
 * 正常情况下这是定时任务的活；界面上这个按钮存在，是因为财务在月结当天
 * 需要用当天最新的数据重跑一次，而不是等到夜里。
 */
export function startRun(
  client: ApiClient,
  input: { tenant_id: TenantId; business_date: string },
  options?: RequestOptions,
): Promise<ReconciliationRun> {
  return client.post<ReconciliationRun>(SERVICE, '/v1/runs', { ...options, body: input });
}

/** 读一次运行的状态与计数。 */
export function getRun(
  client: ApiClient,
  runId: ReconciliationRunId,
  options?: RequestOptions,
): Promise<ReconciliationRun> {
  return client.get<ReconciliationRun>(SERVICE, `/v1/runs/${runId}`, options);
}

/** 差异列表。缺省只看未处理的。 */
export function listDiscrepancies(
  client: ApiClient,
  filters: { state?: DiscrepancyState; kind?: DiscrepancyKind } = { state: 'open' },
  request: PageRequest = {},
  options?: RequestOptions,
): Promise<Page<Discrepancy>> {
  return fetchPage<Discrepancy>(
    client,
    SERVICE,
    '/v1/discrepancies',
    { ...request, filters: { ...request.filters, ...filters } },
    options,
  );
}

/**
 * 处理一条差异。
 *
 * `waived` 是「知道有差、决定不追」，`resolved` 是「已经改好了」。
 * 两者在 analytics 的报表里分开统计，所以界面上必须让人明确选，
 * 不能把「关闭」做成一个按钮。
 */
export function resolveDiscrepancy(
  client: ApiClient,
  discrepancyId: DiscrepancyId,
  input: { state: 'resolved' | 'waived'; note: string },
  options?: RequestOptions,
): Promise<Discrepancy> {
  return client.post<Discrepancy>(SERVICE, `/v1/discrepancies/${discrepancyId}/resolve`, {
    ...options,
    body: input,
  });
}

/**
 * 差异的金额缺口。
 *
 * 两个金额都在时才有意义；`missing_declaration` 这类结构性差异没有金额，
 * 返回 null 让界面显示一个横杠而不是 0 —— 0 会被读成「差额为零」。
 */
export function shortfallMinor(discrepancy: Discrepancy): number | null {
  if (discrepancy.expected_minor === null || discrepancy.observed_minor === null) {
    return null;
  }
  return discrepancy.expected_minor - discrepancy.observed_minor;
}

/**
 * 差异是否在容差之内。
 *
 * 后端用 OF_RECON_TOLERANCE_MINOR 判过一次了，正常不会返回容差内的差异；
 * 这个函数是给「换了容差之后回看历史差异」那个分析视图用的，
 * 它需要在前端按新阈值重新过一遍旧数据。
 */
export function withinTolerance(discrepancy: Discrepancy, toleranceMinor: number): boolean {
  const gap = shortfallMinor(discrepancy);
  return gap !== null && Math.abs(gap) <= toleranceMinor;
}

/** 界面上的严重程度分档。结构性缺失永远排在金额差之前。 */
const KIND_WEIGHT: Readonly<Record<DiscrepancyKind, number>> = {
  cleared_without_payment: 100,
  missing_declaration: 90,
  missing_invoice: 80,
  duty_mismatch: 70,
  orphan_payment: 60,
  weight_mismatch: 50,
  unbilled_accessorial: 40,
};

/**
 * 差异队列的排序。
 *
 * 先按类别权重，再按金额绝对值。故意不按时间 —— 一条挂了三周的
 * `cleared_without_payment` 比今早刚开的重量差重要得多。
 */
export function sortForTriage(items: ReadonlyArray<Discrepancy>): Discrepancy[] {
  return [...items].sort((a, b) => {
    const byKind = KIND_WEIGHT[b.kind] - KIND_WEIGHT[a.kind];
    if (byKind !== 0) return byKind;
    return Math.abs(shortfallMinor(b) ?? 0) - Math.abs(shortfallMinor(a) ?? 0);
  });
}
