/*
 * routing-service 的调用封装：排线、改线、ETA 批量预测、口岸推荐。
 * 改线不是一次原地更新 —— routing-service 会写一个新的 version 并把旧版本
 * 的 is_current 置否，然后发 route.replanned；fleet-service 消费它去释放
 * leg_id 已经不存在的派车。界面上因此必须按 version 展示，而不是「这条线路」。
 */

import type { ApiClient, RequestOptions } from '../http-client';
import type { RouteStrategy, TransportMode } from '../../types/domain';
import type { CrossingId, FacilityId, LegId, RouteId, ShipmentId } from '../../types/ids';

const SERVICE = 'routing-service' as const;

/** 一段航段。`crossing_id` 只有跨境段才有值。 */
export interface RouteLeg {
  readonly leg_id: LegId;
  readonly seq_no: number;
  readonly mode: TransportMode;
  readonly from_facility_id: FacilityId;
  readonly to_facility_id: FacilityId;
  readonly crossing_id: CrossingId | null;
  readonly planned_depart_at: string;
  readonly planned_arrive_at: string;
  readonly actual_depart_at: string | null;
  readonly actual_arrive_at: string | null;
  readonly distance_m: number;
  readonly carrier_id: string | null;
}

/** 一个路线版本。同一条运单上只有一个 `is_current` 为真的版本。 */
export interface RouteDetail {
  readonly route_id: RouteId;
  readonly shipment_id: ShipmentId;
  readonly version: number;
  readonly is_current: boolean;
  readonly planned_by: string;
  readonly strategy: RouteStrategy;
  readonly total_distance_m: number;
  readonly total_duration_s: number;
  readonly computed_at: string;
  readonly superseded_at: string | null;
  readonly legs: ReadonlyArray<RouteLeg>;
}

/** `POST /v1/eta/batch` 的一条结果。 */
export interface EtaPrediction {
  readonly shipment_id: ShipmentId;
  readonly leg_id: LegId;
  readonly predicted_arrive_at: string;
  /** 相对 `planned_arrive_at` 的偏差，正数是晚点，秒。 */
  readonly deviation_s: number;
  /** 0–1。低于 0.4 时界面不显示具体时刻，只显示「预测不可靠」。 */
  readonly confidence: number;
}

/** 口岸推荐的一项，来自 `GET /v1/crossings/recommend`。 */
export interface CrossingRecommendation {
  readonly crossing_id: CrossingId;
  readonly unlocode: string;
  readonly from_country: string;
  readonly to_country: string;
  readonly customs_office_code: string;
  /** 由 analytics-pipeline 每晚刷新的历史均值，不是实时排队时长。 */
  readonly avg_dwell_minutes: number;
  readonly detour_m: number;
  readonly open_24h: boolean;
  readonly modes_allowed: ReadonlyArray<TransportMode>;
  readonly rank_reason: string;
}

/** 排线请求。`strategy` 决定 routing-service 用哪套代价函数。 */
export interface PlanRouteInput {
  shipment_id: ShipmentId;
  strategy: RouteStrategy;
  /** 强制经过的口岸。报关行有时会因为某个口岸的关员熟悉而指定。 */
  via_crossing_ids?: ReadonlyArray<CrossingId>;
  depart_after?: string;
}

/**
 * 排第一版路线。
 *
 * routing-service 会同步调 geo-service 算距离矩阵，再调 customs-service
 * 看目的国的税则是否需要特定口岸。慢是正常的，界面必须给它一个 loading 态，
 * 不要按 8 秒超时去判失败 —— 那是数据库语句的超时，不是这个调用的。
 */
export function planRoute(
  client: ApiClient,
  input: PlanRouteInput,
  options?: RequestOptions,
): Promise<RouteDetail> {
  return client.post<RouteDetail>(SERVICE, '/v1/routes/plan', { ...options, body: input });
}

/**
 * 改线，产出新版本。
 *
 * 冷却时间由 OF_ROUTING_REPLAN_COOLDOWN_SECONDS 控制；在冷却期内再调
 * 会拿到 `replan_cooldown_active`，那不是错误，界面应当显示还要等多久。
 */
export function replanRoute(
  client: ApiClient,
  routeId: RouteId,
  input: { strategy?: RouteStrategy; reason_code: string },
  options?: RequestOptions,
): Promise<RouteDetail> {
  return client.post<RouteDetail>(SERVICE, `/v1/routes/${routeId}/replan`, {
    ...options,
    body: input,
  });
}

/** 读某个具体版本，含航段。历史版本对账时要看。 */
export function getRoute(
  client: ApiClient,
  routeId: RouteId,
  options?: RequestOptions,
): Promise<RouteDetail> {
  return client.get<RouteDetail>(SERVICE, `/v1/routes/${routeId}`, options);
}

/**
 * 读运单当前的路线。
 *
 * 运单详情页应当和 container-registry、customs-service 的请求共用同一个
 * `traceId`：routing-service 和 container-registry 都会去问 geo-service，
 * 共享 trace-id 才能命中那 30 秒的 per-trace 缓存（SPEC §1.2 Diamond A）。
 */
export function getCurrentRoute(
  client: ApiClient,
  shipmentId: ShipmentId,
  options?: RequestOptions,
): Promise<RouteDetail> {
  return client.get<RouteDetail>(SERVICE, `/v1/shipments/${shipmentId}/route`, options);
}

/** 单批最多 500 条，超了后端直接回 400 而不是截断。 */
export const ETA_BATCH_LIMIT = 500;

/**
 * 批量 ETA。
 *
 * 看板上一屏可能有上千条运单，这里按 500 一批切开顺序发 —— 并发发会让
 * routing-service 的求解线程池（OF_ROUTING_SOLVER_THREADS）排队，
 * 总耗时反而更长。
 */
export async function predictEta(
  client: ApiClient,
  shipmentIds: ReadonlyArray<ShipmentId>,
  options?: RequestOptions,
): Promise<EtaPrediction[]> {
  const out: EtaPrediction[] = [];
  for (let i = 0; i < shipmentIds.length; i += ETA_BATCH_LIMIT) {
    const slice = shipmentIds.slice(i, i + ETA_BATCH_LIMIT);
    const page = await client.post<{ items: ReadonlyArray<EtaPrediction> }>(
      SERVICE,
      '/v1/eta/batch',
      { ...options, body: { shipment_ids: slice } },
    );
    out.push(...page.items);
  }
  return out;
}

/** 口岸推荐。排序由后端决定，前端不重排 —— 它的排序里含税则因素。 */
export function recommendCrossings(
  client: ApiClient,
  query: {
    origin_facility_id: FacilityId;
    destination_facility_id: FacilityId;
    mode: TransportMode;
    depart_after?: string;
  },
  options?: RequestOptions,
): Promise<{ items: ReadonlyArray<CrossingRecommendation> }> {
  return client.get<{ items: ReadonlyArray<CrossingRecommendation> }>(
    SERVICE,
    '/v1/crossings/recommend',
    { ...options, query },
  );
}

/**
 * 两个版本之间变了哪些航段。
 *
 * 和 `route.replanned` 事件里的 `legs_changed` 是同一个概念，但事件只在
 * 改线那一刻推一次；用户翻历史版本时要在前端自己算。
 */
export function changedLegs(previous: RouteDetail, next: RouteDetail): LegId[] {
  const before = new Map(previous.legs.map((leg) => [leg.seq_no, leg]));
  const changed: LegId[] = [];

  for (const leg of next.legs) {
    const old = before.get(leg.seq_no);
    if (
      !old ||
      old.from_facility_id !== leg.from_facility_id ||
      old.to_facility_id !== leg.to_facility_id ||
      old.mode !== leg.mode ||
      old.crossing_id !== leg.crossing_id
    ) {
      changed.push(leg.leg_id);
    }
  }
  return changed;
}

/** 计划总时长与实际已耗时的差，用于在甘特图上画那条红线。秒。 */
export function scheduleDrift(route: RouteDetail, now = Date.now()): number {
  const started = route.legs.find((leg) => leg.actual_depart_at)?.actual_depart_at;
  if (!started) return 0;
  const elapsed = (now - Date.parse(started)) / 1000;
  const lastArrival = route.legs[route.legs.length - 1]?.planned_arrive_at;
  if (!lastArrival) return 0;
  const planned = (Date.parse(lastArrival) - Date.parse(started)) / 1000;
  return Math.round(elapsed - planned);
}
