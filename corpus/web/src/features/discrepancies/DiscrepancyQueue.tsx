/*
 * 财务的差异队列。reconciliation-service 每晚三方核对（运单 / 报关单 / 发票）
 * 之后开出来的差异在这里被人一条条处理。界面上最需要说清的一件事是因果方向：
 * 差异一开，billing-service 就消费 reconciliation.discrepancy.opened 把发票
 * 挂起；在这里点「已解决」并不会解挂，那要财务再去发票那边动手。
 */

import { useCallback, useEffect, useMemo, useState } from 'react';

import {
  listDiscrepancies,
  resolveDiscrepancy,
  shortfallMinor,
  sortForTriage,
  type Discrepancy,
} from '../../api/endpoints/reconciliation';
import { OfApiError, isTransient } from '../../api/errors';
import { mergePage } from '../../api/pagination';
import { formatMoney, formatRelative } from '../../lib/format';
import type { ApiClient } from '../../api/http-client';
import type { DiscrepancyKind } from '../../types/domain';
import type { DiscrepancyId, InvoiceId, ShipmentId } from '../../types/ids';

/** 差异类别的中文标签，与 `analytics.reconciliation_discrepancies.kind` 一一对应。 */
const KIND_LABELS: Record<DiscrepancyKind, string> = {
  missing_declaration: '缺报关单',
  missing_invoice: '缺发票',
  duty_mismatch: '税额不符',
  weight_mismatch: '重量不符',
  orphan_payment: '孤立收款',
  unbilled_accessorial: '未计费附加费',
  cleared_without_payment: '已放行未付税',
};

/**
 * 每种差异该由谁处理。
 *
 * 不是装饰性的分组 —— 财务和报关行看的是同一个队列，
 * 但能动的条目完全不同：报关单缺失只有报关行能补，
 * 孤立收款只有财务能认领。分错了的结果是两边互相等着对方。
 */
const OWNING_DESK: Record<DiscrepancyKind, '报关' | '财务' | '运营'> = {
  missing_declaration: '报关',
  cleared_without_payment: '财务',
  missing_invoice: '财务',
  duty_mismatch: '报关',
  orphan_payment: '财务',
  weight_mismatch: '运营',
  unbilled_accessorial: '财务',
};

export interface DiscrepancyQueueProps {
  client: ApiClient;
  /** 只看某一类；不传就是全部未处理的。 */
  kind?: DiscrepancyKind;
  onOpenShipment: (shipmentId: ShipmentId) => void;
  onOpenInvoice: (invoiceId: InvoiceId) => void;
}

/**
 * 差异队列。
 *
 * 分页是游标式的（SPEC §0.5），所以「下一页」只能往前走，不能跳页 ——
 * 界面上不要画页码，那会让人以为可以跳到第 7 页。
 */
export function DiscrepancyQueue(props: DiscrepancyQueueProps): JSX.Element {
  const { client, kind, onOpenShipment, onOpenInvoice } = props;

  const [rows, setRows] = useState<ReadonlyArray<Discrepancy>>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<ReadonlySet<DiscrepancyId>>(new Set());
  const [banner, setBanner] = useState<string | null>(null);

  const load = useCallback(
    async (from: string | null) => {
      setLoading(true);
      try {
        const page = await listDiscrepancies(
          client,
          { state: 'open', kind },
          { cursor: from, limit: 100 },
        );
        setRows((current) =>
          mergePage(from ? current : [], page.items, (row) => row.discrepancy_id),
        );
        setCursor(page.next_cursor);
        setBanner(null);
      } catch (error) {
        if (error instanceof OfApiError) {
          setBanner(
            isTransient(error)
              ? '对账服务暂时不可用，正在重试。'
              : `无法加载差异列表（${error.code}），trace ${error.traceId}`,
          );
        } else {
          throw error;
        }
      } finally {
        setLoading(false);
      }
    },
    [client, kind],
  );

  useEffect(() => {
    void load(null);
  }, [load]);

  /**
   * 处理一条。
   *
   * 处理完之后不重新拉整页 —— 只把这一行从本地列表里摘掉。
   * 重新拉会让队列在人正在读的时候整体跳动，而夜里的核对每天只跑一次，
   * 中途不会有新条目进来。
   */
  const handle = useCallback(
    async (row: Discrepancy, state: 'resolved' | 'waived', note: string) => {
      setBusy((current) => new Set(current).add(row.discrepancy_id));
      try {
        await resolveDiscrepancy(client, row.discrepancy_id, { state, note });
        setRows((current) => current.filter((r) => r.discrepancy_id !== row.discrepancy_id));
      } catch (error) {
        if (error instanceof OfApiError) {
          setBanner(`处理失败（${error.code}），trace ${error.traceId}`);
        } else {
          throw error;
        }
      } finally {
        setBusy((current) => {
          const next = new Set(current);
          next.delete(row.discrepancy_id);
          return next;
        });
      }
    },
    [client],
  );

  const ordered = useMemo(() => sortForTriage(rows), [rows]);

  const exposure = useMemo(() => {
    // 只把币种相同的加在一起。跨币种求和需要 billing-service 冻结的那份汇率，
    // 前端手里没有，估算出来的数字会被当成真数字去对账。
    const byCurrency = new Map<string, number>();
    for (const row of rows) {
      const gap = shortfallMinor(row);
      if (gap === null || !row.currency) continue;
      byCurrency.set(row.currency, (byCurrency.get(row.currency) ?? 0) + Math.abs(gap));
    }
    return Array.from(byCurrency.entries());
  }, [rows]);

  return (
    <section className="of-queue" aria-label="对账差异队列">
      <header className="of-queue__header">
        <h2>未处理差异（{rows.length}）</h2>
        <ul className="of-queue__exposure">
          {exposure.map(([currency, amount]) => (
            <li key={currency}>{formatMoney(amount, currency)}</li>
          ))}
        </ul>
      </header>

      {banner ? (
        <p className="of-queue__banner" role="status">
          {banner}
        </p>
      ) : null}

      <table className="of-queue__table">
        <thead>
          <tr>
            <th scope="col">类别</th>
            <th scope="col">归属</th>
            <th scope="col">运单</th>
            <th scope="col">发票</th>
            <th scope="col">差额</th>
            <th scope="col">开出</th>
            <th scope="col" aria-label="操作" />
          </tr>
        </thead>
        <tbody>
          {ordered.map((row) => {
            const gap = shortfallMinor(row);
            const pending = busy.has(row.discrepancy_id);
            return (
              <tr key={row.discrepancy_id} data-kind={row.kind}>
                <td>{KIND_LABELS[row.kind]}</td>
                <td>{OWNING_DESK[row.kind]}</td>
                <td>
                  <button type="button" onClick={() => onOpenShipment(row.shipment_id)}>
                    {row.shipment_id}
                  </button>
                </td>
                <td>
                  {row.invoice_id ? (
                    <button type="button" onClick={() => onOpenInvoice(row.invoice_id!)}>
                      {row.invoice_id}
                    </button>
                  ) : (
                    // 发票不存在正是差异本身，这里显示横杠而不是空白。
                    <span aria-label="没有对应发票">—</span>
                  )}
                </td>
                <td className="of-queue__amount">
                  {gap === null || !row.currency ? '—' : formatMoney(gap, row.currency)}
                </td>
                <td>{formatRelative(row.opened_at)}</td>
                <td>
                  <button
                    type="button"
                    disabled={pending}
                    onClick={() => void handle(row, 'resolved', '已在源系统修正')}
                  >
                    已解决
                  </button>
                  <button
                    type="button"
                    disabled={pending}
                    onClick={() => void handle(row, 'waived', '金额在可接受范围内，不再追')}
                  >
                    豁免
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {cursor ? (
        <button type="button" disabled={loading} onClick={() => void load(cursor)}>
          {loading ? '加载中…' : '再取一页'}
        </button>
      ) : (
        <p className="of-queue__end">{loading ? '加载中…' : '没有更多了'}</p>
      )}
    </section>
  );
}
