/*
 * telemetry-ingest 的只读面：告警列表、认领与关闭，以及冷链曲线要用的读数窗口查询。
 * 控制台从不往 /v1/ingest/batch 写东西 —— 那条路径只属于 edge/ 下的网关代理，
 * 而且要求 Ed25519 签名，浏览器既没有私钥也不该有。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type { AlertRuleCode, AlertSeverity, LatLon, RegionCode } from '../../types/domain';
import type { AlertId, ContainerId, GatewayId, ReadingId, ShipmentId, UserId } from '../../types/ids';

const SERVICE = 'telemetry-ingest' as const;

/** `GET /v1/alerts` 的一行，对应 `telemetry.telemetry_alerts`。 */
export interface TelemetryAlert {
  readonly alert_id: AlertId;
  readonly container_id: ContainerId;
  /** 起警时通过 freight.v1.ContainerLookup/ResolveShipmentForContainer 解析出来；空箱时为 null。 */
  readonly shipment_id: ShipmentId | null;
  readonly rule_code: AlertRuleCode;
  readonly severity: AlertSeverity;
  readonly opened_at: string;
  readonly closed_at: string | null;
  readonly peak_value: number | null;
  readonly threshold_value: number;
  readonly first_reading_id: ReadingId;
  readonly acknowledged_by: UserId | null;
  readonly acknowledged_at: string | null;
}

/** 一条读数。冷链曲线只画 `temperature_c`，其余字段给详情浮层用。 */
export interface TelemetryReading {
  readonly reading_id: ReadingId;
  readonly region_code: RegionCode;
  readonly container_id: ContainerId;
  readonly gateway_id: GatewayId;
  /** 传感器自己的时钟。 */
  readonly recorded_at: string;
  /** telemetry-ingest 收到的时刻。断链补传时两者可以差好几个小时。 */
  readonly received_at: string;
  readonly temperature_c: number | null;
  readonly humidity_pct: number | null;
  readonly shock_g: number | null;
  readonly door_open: boolean | null;
  readonly battery_pct: number | null;
  readonly position: LatLon | null;
}

/**
 * 告警列表。
 *
 * `severity_min` 通常设成与 container-registry 的 `OF_FREIGHT_AUTO_AT_RISK_SEVERITY`
 * 相同的值，这样值班面板上看到的就正好是「会把运单打成 at_risk 的那一批」。
 */
export function listAlerts(
  client: ApiClient,
  filters: {
    state?: 'open' | 'acknowledged' | 'closed';
    rule_code?: AlertRuleCode;
    container_id?: ContainerId;
    severity_min?: AlertSeverity;
  },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<TelemetryAlert>> {
  return fetchPage<TelemetryAlert>(
    client,
    SERVICE,
    '/v1/alerts',
    { ...request, filters: { ...request?.filters, ...filters } },
    options,
  );
}

/**
 * 认领一条告警。只写 `acknowledged_by` / `acknowledged_at`，不关闭 ——
 * 认领的语义是「我在看了」，而现场温度是不是真的回来了，认领的人当时并不知道。
 */
export function acknowledgeAlert(
  client: ApiClient,
  alertId: AlertId,
  options?: RequestOptions,
): Promise<TelemetryAlert> {
  return client.post<TelemetryAlert>(SERVICE, `/v1/alerts/${alertId}/acknowledge`, options);
}

/**
 * 手工关闭。规则自己不会关某些告警（比如 `shock_impact` 是一次性事件，
 * 不存在「恢复正常」的读数），所以现场处理完之后必须有人来点这个。
 */
export function closeAlert(
  client: ApiClient,
  alertId: AlertId,
  resolutionNote: string,
  options?: RequestOptions,
): Promise<TelemetryAlert> {
  return client.post<TelemetryAlert>(SERVICE, `/v1/alerts/${alertId}/close`, {
    ...options,
    body: { resolution_note: resolutionNote },
  });
}

/**
 * 时间窗读数查询，直接打到该区域的分区上。
 *
 * 跨区域是查不到的：`telemetry.telemetry_readings` 按 region_code 做 LIST 分区，
 * 一条巴西的读数不会出现在欧洲的分区里，这是数据驻留要求而不是性能优化（SPEC §7 规则 7）。
 * 所以窗口再宽，也只能看到当前区域集群里的数据。
 */
export function listReadings(
  client: ApiClient,
  containerId: ContainerId,
  window: { from: string; to: string },
  request?: PageRequest,
  options?: RequestOptions,
): Promise<Page<TelemetryReading>> {
  return fetchPage<TelemetryReading>(
    client,
    SERVICE,
    `/v1/containers/${containerId}/readings`,
    { ...request, filters: { ...request?.filters, from: window.from, to: window.to } },
    options,
  );
}

/**
 * 把读数抽稀到图表宽度，避免把七天、每分钟一条的曲线一次性塞进 canvas。
 * 保留每个桶里的极值点，因为冷链看的是越界峰值，平均值会把 excursion 抹平。
 */
export function downsamplePeaks(
  readings: ReadonlyArray<TelemetryReading>,
  buckets: number,
): TelemetryReading[] {
  if (readings.length <= buckets || buckets <= 0) return [...readings];
  const size = Math.ceil(readings.length / buckets);
  const out: TelemetryReading[] = [];

  for (let i = 0; i < readings.length; i += size) {
    const slice = readings.slice(i, i + size);
    const peak = slice.reduce((best, current) => {
      const a = Math.abs(current.temperature_c ?? 0);
      const b = Math.abs(best.temperature_c ?? 0);
      return a > b ? current : best;
    }, slice[0]);
    out.push(peak);
  }
  return out;
}
