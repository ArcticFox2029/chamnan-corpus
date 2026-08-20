/*
 * 运单详情页的时间线数据源。它把四路来源合成一条按时间排序的流：
 * container-registry 的扫描轨迹、customs-service 的报关节点、billing-service 的发票节点，
 * 再叠上实时通道推来的增量。合并逻辑放在这里，是为了让页面组件只管画。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { getShipment, listScans, type ScanRecord, type ShipmentDetail } from '../../api/endpoints/freight';
import { listShipmentDeclarations } from '../../api/endpoints/customs';
import { listTenantInvoices } from '../../api/endpoints/billing';
import { clockSkewSeconds } from '../../lib/format';
import type { ApiClient } from '../../api/http-client';
import type { ConsoleChannel } from '../../realtime/console-channel';
import type { DeclarationSummary, InvoiceSummary, ShipmentStatus } from '../../types/domain';
import type { ShipmentId, TenantId, TraceId } from '../../types/ids';

/** 时间线上一条目的种类。排序只看 `at`，种类只影响图标与颜色。 */
export type TimelineKind =
  | 'scan'
  | 'status'
  | 'assignment'
  | 'alert'
  | 'declaration'
  | 'invoice'
  | 'replan';

/** 一条时间线条目。 */
export interface TimelineEntry {
  readonly id: string;
  readonly kind: TimelineKind;
  readonly at: string;
  readonly title: string;
  readonly detail: string;
  /** 离线补录的扫描；界面上加一个「延迟上报」的角标。 */
  readonly delayed?: boolean;
}

export interface TimelineResult {
  readonly shipment: ShipmentDetail | null;
  readonly entries: ReadonlyArray<TimelineEntry>;
  readonly loading: boolean;
  readonly error: Error | null;
  readonly reload: () => void;
}

/** 生成 trace-id 的小工具，与 http-client 里的一致；这里单独有一份是为了在 hook 内复用同一个值。 */
function newTraceId(): TraceId {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('') as TraceId;
}

function scanToEntry(scan: ScanRecord, toleranceSeconds: number): TimelineEntry {
  const skew = clockSkewSeconds(scan.occurred_at, scan.recorded_at);
  return {
    id: scan.scan_id,
    kind: 'scan',
    at: scan.occurred_at,
    title: scan.scan_type,
    detail: scan.container_id ? `箱号 ${scan.container_id}` : '整单扫描',
    delayed: skew > toleranceSeconds,
  };
}

function declarationToEntry(declaration: DeclarationSummary): TimelineEntry {
  const at = declaration.cleared_at ?? declaration.filed_at ?? '';
  return {
    id: declaration.declaration_id,
    kind: 'declaration',
    at,
    title: declaration.status === 'cleared' ? '海关放行' : '报关单已报送',
    detail: declaration.mrn ? `MRN ${declaration.mrn}` : declaration.customs_office_code,
  };
}

function invoiceToEntry(invoice: InvoiceSummary): TimelineEntry {
  const at = invoice.settled_at ?? invoice.issued_at ?? '';
  return {
    id: invoice.invoice_id,
    kind: 'invoice',
    at,
    title: invoice.settled_at ? '发票已结清' : '发票已签发',
    detail: invoice.invoice_number ?? '草稿',
  };
}

/**
 * 拉取并维护一条运单的完整时间线。
 *
 * 四个初始请求共用同一个 `traceId`。这不是为了好看：fleet-service 会同时打到
 * container-registry 和 routing-service，两者又都会打 geo-service，
 * 而 geo-service 的 ResolveGeofence 结果是按 trace 缓存 30 秒的 ——
 * trace-id 一旦在中途被换掉，同一个围栏就会被解析两遍。
 *
 * @param client - 共享的 API 客户端。
 * @param channel - 实时通道；传 null 时退化成纯轮询式的静态页面。
 * @param shipmentId - 目标运单。
 * @param tenantId - 当前租户，取发票列表时需要。
 * @param skewToleranceSeconds - 与 `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` 保持一致。
 */
export function useShipmentTimeline(
  client: ApiClient,
  channel: ConsoleChannel | null,
  shipmentId: ShipmentId,
  tenantId: TenantId,
  skewToleranceSeconds = 900,
): TimelineResult {
  const [shipment, setShipment] = useState<ShipmentDetail | null>(null);
  const [base, setBase] = useState<ReadonlyArray<TimelineEntry>>([]);
  const [live, setLive] = useState<ReadonlyArray<TimelineEntry>>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const reloadToken = useRef(0);

  const reload = useCallback(() => {
    reloadToken.current += 1;
    setLoading(true);
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    const traceId = newTraceId();
    const options = { traceId, signal: controller.signal };

    async function load(): Promise<void> {
      try {
        const [detail, scans, declarations, invoices] = await Promise.all([
          getShipment(client, shipmentId, options),
          listScans(client, shipmentId, { limit: 200 }, options),
          listShipmentDeclarations(client, shipmentId, { limit: 50 }, options),
          listTenantInvoices(client, tenantId, {}, { limit: 50, filters: { shipment_id: shipmentId } }, options),
        ]);

        const merged = [
          ...scans.items.map((s) => scanToEntry(s, skewToleranceSeconds)),
          ...declarations.items.map(declarationToEntry),
          ...invoices.items.map(invoiceToEntry),
        ].filter((entry) => entry.at !== '');

        setShipment(detail);
        setBase(merged);
        setError(null);
      } catch (cause) {
        if (!controller.signal.aborted) setError(cause as Error);
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }

    void load();
    return () => controller.abort();
  }, [client, shipmentId, tenantId, skewToleranceSeconds, reloadToken.current]);

  useEffect(() => {
    if (!channel) return undefined;

    const append = (entry: TimelineEntry) => setLive((prev) => [...prev, entry]);

    // 只接与本单相关的事件。信封的 partition_key 就是 shipment_id，
    // 但仍然按 payload 里的字段过滤，因为 telemetry.alert.raised 是按箱分区的。
    const unsubscribers = [
      channel.on('shipment.scanned', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: p.scan_id,
          kind: 'scan',
          at: p.occurred_at,
          title: p.scan_type,
          detail: p.container_id ?? '整单扫描',
          delayed: clockSkewSeconds(p.occurred_at, p.recorded_at) > skewToleranceSeconds,
        });
      }),
      channel.on('shipment.status.changed', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: `${envelope.event_id}`,
          kind: 'status',
          at: p.changed_at,
          title: `${p.from_status} → ${p.to_status}`,
          detail: p.reason_code,
        });
        setShipment((prev) => (prev ? { ...prev, status: p.to_status as ShipmentStatus } : prev));
      }),
      channel.on('telemetry.alert.raised', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: p.alert_id,
          kind: 'alert',
          at: p.opened_at,
          title: p.rule_code,
          detail: `严重度 ${p.severity}，阈值 ${p.threshold_value}`,
        });
      }),
      channel.on('route.replanned', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: `${p.route_id}#${p.version}`,
          kind: 'replan',
          at: p.computed_at,
          title: `路线已重排 v${p.previous_version} → v${p.version}`,
          detail: `${p.reason_code}，${p.legs_changed.length} 个路段变更`,
        });
      }),
      channel.on('fleet.assignment.created', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: p.assignment_id,
          kind: 'assignment',
          at: p.assigned_at,
          title: '已派车',
          detail: `${p.vehicle_id} / ${p.driver_id}`,
        });
      }),
      channel.on('billing.invoice.settled', (envelope) => {
        const p = envelope.payload;
        if (p.shipment_id !== shipmentId) return;
        append({
          id: p.invoice_id,
          kind: 'invoice',
          at: p.settled_at,
          title: '发票已结清',
          detail: p.declaration_id ? `将解锁报关单 ${p.declaration_id} 的税款状态` : '',
        });
      }),
    ];

    return () => unsubscribers.forEach((off) => off());
  }, [channel, shipmentId, skewToleranceSeconds]);

  const entries = useMemo(() => {
    // 实时条目可能与首屏拉到的重复（比如刚好在两次请求之间发生），按 id 去重后再排序。
    const index = new Map<string, TimelineEntry>();
    for (const entry of [...base, ...live]) index.set(entry.id, entry);
    return Array.from(index.values()).sort((a, b) => b.at.localeCompare(a.at));
  }, [base, live]);

  return { shipment, entries, loading, error, reload };
}
