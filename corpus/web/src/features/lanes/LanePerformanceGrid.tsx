/*
 * 航线绩效表格。数据全部来自 analytics-pipeline 的物化视图，
 * 因此这个页面不是实时的：界面顶部必须显示刷新时点，让人知道自己在看昨天的数字。
 * 表格本身只做排序、汇总与导出，不做任何跨服务的联查。
 */

import { useEffect, useMemo, useState } from 'react';

import {
  getLanePerformance,
  onTimeRate,
  type LanePerformanceRow,
} from '../../api/endpoints/analytics';
import { iteratePages } from '../../api/pagination';
import { formatDuration } from '../../lib/format';
import type { ApiClient } from '../../api/http-client';
import type { TransportMode } from '../../types/domain';

/** 可排序的列。 */
export type LaneSortKey = 'shipment_count' | 'on_time_rate' | 'avg_transit_seconds' | 'p95_transit_seconds' | 'excursion_alerts';

export interface LanePerformanceGridProps {
  client: ApiClient;
  /** 闭区间，`YYYY-MM-DD`。超过 180 天应当引导用户去导出，而不是在页面上翻。 */
  range: { from_date: string; to_date: string };
  originUnlocode?: string;
  destinationUnlocode?: string;
  /** 物化视图的刷新时点，由 `OF_ANALYTICS_MV_REFRESH_CRON` 决定，当前是每天 03:15 UTC。 */
  refreshedAt: string | null;
}

/** 一条航线的聚合行：把同一条航线在区间内的所有天并成一行。 */
interface LaneAggregate {
  readonly key: string;
  readonly origin_unlocode: string;
  readonly destination_unlocode: string;
  readonly primary_mode: TransportMode;
  readonly shipment_count: number;
  readonly on_time_count: number;
  readonly weighted_transit_seconds: number;
  readonly worst_p95_seconds: number;
  readonly excursion_alerts: number;
}

const MODE_LABELS: Record<TransportMode, string> = {
  road: '公路',
  rail: '铁路',
  sea: '海运',
  air: '空运',
  barge: '内河驳船',
};

/**
 * 按航线聚合。
 *
 * `avg_transit_seconds` 是每天各自的平均值，直接再平均会给运量小的日子过高的权重，
 * 所以这里按 `shipment_count` 加权。p95 无法这样合并，取区间内的最大值 ——
 * 这是保守的读法，正是排查延误时想要的。
 */
export function aggregateLanes(rows: ReadonlyArray<LanePerformanceRow>): LaneAggregate[] {
  const buckets = new Map<string, LaneAggregate>();

  for (const row of rows) {
    const key = `${row.origin_unlocode}>${row.destination_unlocode}#${row.primary_mode}`;
    const current = buckets.get(key);
    if (!current) {
      buckets.set(key, {
        key,
        origin_unlocode: row.origin_unlocode,
        destination_unlocode: row.destination_unlocode,
        primary_mode: row.primary_mode,
        shipment_count: row.shipment_count,
        on_time_count: row.on_time_count,
        weighted_transit_seconds: row.avg_transit_seconds * row.shipment_count,
        worst_p95_seconds: row.p95_transit_seconds,
        excursion_alerts: row.excursion_alerts,
      });
      continue;
    }
    buckets.set(key, {
      ...current,
      shipment_count: current.shipment_count + row.shipment_count,
      on_time_count: current.on_time_count + row.on_time_count,
      weighted_transit_seconds:
        current.weighted_transit_seconds + row.avg_transit_seconds * row.shipment_count,
      worst_p95_seconds: Math.max(current.worst_p95_seconds, row.p95_transit_seconds),
      excursion_alerts: current.excursion_alerts + row.excursion_alerts,
    });
  }

  return Array.from(buckets.values());
}

function sortValue(row: LaneAggregate, key: LaneSortKey): number {
  switch (key) {
    case 'on_time_rate':
      return row.shipment_count === 0 ? -1 : row.on_time_count / row.shipment_count;
    case 'avg_transit_seconds':
      return row.shipment_count === 0 ? 0 : row.weighted_transit_seconds / row.shipment_count;
    case 'p95_transit_seconds':
      return row.worst_p95_seconds;
    case 'excursion_alerts':
      return row.excursion_alerts;
    default:
      return row.shipment_count;
  }
}

/**
 * 航线绩效表格组件。
 *
 * 页面只取第一页（默认 50 条）；导出按钮才会用 iteratePages 把整个区间拉完，
 * 那是后台任务级别的开销，不能在渲染路径上做。
 */
export function LanePerformanceGrid(props: LanePerformanceGridProps): JSX.Element {
  const { client, range, originUnlocode, destinationUnlocode, refreshedAt } = props;

  const [rows, setRows] = useState<ReadonlyArray<LanePerformanceRow>>([]);
  const [sortKey, setSortKey] = useState<LaneSortKey>('shipment_count');
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    getLanePerformance(
      client,
      { ...range, origin_unlocode: originUnlocode, destination_unlocode: destinationUnlocode },
      { limit: 200 },
      { signal: controller.signal },
    )
      .then((page) => setRows(page.items))
      .catch(() => {
        if (!controller.signal.aborted) setRows([]);
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });
    return () => controller.abort();
  }, [client, range.from_date, range.to_date, originUnlocode, destinationUnlocode]);

  const lanes = useMemo(() => {
    return aggregateLanes(rows).sort((a, b) => sortValue(b, sortKey) - sortValue(a, sortKey));
  }, [rows, sortKey]);

  async function exportAll(): Promise<void> {
    setExporting(true);
    const collected: LanePerformanceRow[] = [];
    try {
      for await (const row of iteratePages<LanePerformanceRow>(
        client,
        'analytics-pipeline',
        '/v1/metrics/lane-performance',
        { limit: 200, filters: { ...range } },
      )) {
        collected.push(row);
      }
      downloadCsv(collected);
    } finally {
      setExporting(false);
    }
  }

  return (
    <section className="lane-grid" aria-label="航线绩效">
      <header className="lane-grid__header">
        <h2>航线绩效</h2>
        <p className="lane-grid__freshness">
          {refreshedAt ? `数据截至 ${refreshedAt}（每日 03:15 UTC 刷新）` : '刷新时点未知'}
        </p>
        <button type="button" onClick={() => void exportAll()} disabled={exporting}>
          {exporting ? '导出中…' : '导出 CSV'}
        </button>
      </header>

      {loading ? (
        <p>正在载入…</p>
      ) : (
        <table className="lane-grid__table">
          <thead>
            <tr>
              <th scope="col">起运地</th>
              <th scope="col">目的地</th>
              <th scope="col">主运输方式</th>
              <th scope="col">
                <button type="button" onClick={() => setSortKey('shipment_count')}>票数</button>
              </th>
              <th scope="col">
                <button type="button" onClick={() => setSortKey('on_time_rate')}>准点率</button>
              </th>
              <th scope="col">
                <button type="button" onClick={() => setSortKey('avg_transit_seconds')}>平均时长</button>
              </th>
              <th scope="col">
                <button type="button" onClick={() => setSortKey('p95_transit_seconds')}>P95</button>
              </th>
              <th scope="col">
                <button type="button" onClick={() => setSortKey('excursion_alerts')}>告警数</button>
              </th>
            </tr>
          </thead>
          <tbody>
            {lanes.map((lane) => {
              const rate = lane.shipment_count === 0 ? null : lane.on_time_count / lane.shipment_count;
              const avg = lane.shipment_count === 0 ? 0 : lane.weighted_transit_seconds / lane.shipment_count;
              return (
                <tr key={lane.key}>
                  <td>{lane.origin_unlocode}</td>
                  <td>{lane.destination_unlocode}</td>
                  <td>{MODE_LABELS[lane.primary_mode]}</td>
                  <td className="numeric">{lane.shipment_count}</td>
                  <td className="numeric">{rate === null ? '—' : `${(rate * 100).toFixed(1)}%`}</td>
                  <td className="numeric">{formatDuration(avg)}</td>
                  <td className="numeric">{formatDuration(lane.worst_p95_seconds)}</td>
                  <td className="numeric">{lane.excursion_alerts}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
}

/** 导出原始日粒度数据，不是聚合结果 —— 拿去做二次分析的人要的是明细。 */
function downloadCsv(rows: ReadonlyArray<LanePerformanceRow>): void {
  const header = [
    'business_date',
    'origin_unlocode',
    'destination_unlocode',
    'primary_mode',
    'shipment_count',
    'on_time_count',
    'on_time_rate',
    'avg_transit_seconds',
    'p95_transit_seconds',
    'excursion_alerts',
  ].join(',');

  const body = rows.map((row) =>
    [
      row.business_date,
      row.origin_unlocode,
      row.destination_unlocode,
      row.primary_mode,
      row.shipment_count,
      row.on_time_count,
      onTimeRate(row)?.toFixed(4) ?? '',
      row.avg_transit_seconds,
      row.p95_transit_seconds,
      row.excursion_alerts,
    ].join(','),
  );

  const blob = new Blob([[header, ...body].join('\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = 'lane-performance.csv';
  anchor.click();
  URL.revokeObjectURL(url);
}
