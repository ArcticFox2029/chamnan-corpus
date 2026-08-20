/*
 * 推动运单状态的对话框。整个控制台里唯一允许改运单状态的地方 ——
 * container-registry 的 PATCH /v1/shipments/{shipment_id}/status 是状态机的
 * 唯一入口，所以这个组件承担的其实是把「哪些迁移合法」和「哪些迁移不是人能做的」
 * 讲给用户听：at_risk 由 telemetry.alert.raised 自动置位，held_at_customs
 * 由报关流程决定，两者都不出现在这个下拉框里。
 */

import { useMemo, useState } from 'react';
import { changeShipmentStatus } from '../../api/endpoints/freight';
import { OfApiError, isTransient } from '../../api/errors';
import type { ApiClient } from '../../api/http-client';
import { formatRelative } from '../../lib/format';
import type { ShipmentStatus, ShipmentSummary } from '../../types/domain';

/**
 * 人可以手动发起的迁移。
 *
 * 这张表是 `freight.shipments.status` 那个 CHECK 约束的子集，而不是它的翻版：
 * - `at_risk` 只由 container-registry 消费 telemetry.alert.raised 时置位，
 *   严重度阈值是 OF_FREIGHT_AUTO_AT_RISK_SEVERITY，人手动标注毫无意义。
 * - `held_at_customs` 跟着 customs.declaration.filed / cleared 走。
 * - `delivered` 需要一条 proof_of_delivery 扫描先落库，因为 billing-service
 *   是靠那条扫描解锁开票的，先改状态只会让发票开不出来。
 */
const MANUAL_TRANSITIONS: Readonly<Record<ShipmentStatus, ReadonlyArray<ShipmentStatus>>> = {
  draft: ['booked', 'cancelled'],
  booked: ['sealed', 'cancelled'],
  sealed: ['in_transit', 'cancelled'],
  in_transit: ['delivered'],
  at_risk: ['in_transit', 'delivered'],
  held_at_customs: [],
  delivered: [],
  cancelled: [],
};

/** 每种迁移必须给出的原因码。审计台账里那条记录只有它能解释「为什么」。 */
const REASON_CODES: Readonly<Record<string, ReadonlyArray<string>>> = {
  cancelled: ['customer_cancelled', 'capacity_unavailable', 'duplicate_booking', 'commercial_hold'],
  sealed: ['loading_complete', 'seal_verified_at_origin'],
  in_transit: ['departed_origin', 'resumed_after_hold'],
  delivered: ['pod_signed', 'delivered_unattended'],
  booked: ['space_confirmed'],
};

export interface ShipmentStatusDialogProps {
  client: ApiClient;
  shipment: ShipmentSummary;
  /** 这条运单下有没有 proof_of_delivery 扫描。没有就不让选 delivered。 */
  hasProofOfDelivery: boolean;
  onClose: () => void;
  onChanged: (updated: ShipmentSummary) => void;
}

/**
 * 状态迁移对话框。
 *
 * 乐观更新在这里是错的：状态迁移会引发 shipment.status.changed，
 * 下游六个消费者各自动作，其中 billing-service 会据此开票。
 * 界面必须等 container-registry 真的回了 200 再改，
 * 否则用户看到「已交付」而账单系统什么都没收到。
 */
export function ShipmentStatusDialog(props: ShipmentStatusDialogProps): JSX.Element {
  const { client, shipment, hasProofOfDelivery, onClose, onChanged } = props;

  const [target, setTarget] = useState<ShipmentStatus | ''>('');
  const [reasonCode, setReasonCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<OfApiError | null>(null);

  const allowed = useMemo(() => {
    const candidates = MANUAL_TRANSITIONS[shipment.status] ?? [];
    if (hasProofOfDelivery) return candidates;
    return candidates.filter((status) => status !== 'delivered');
  }, [shipment.status, hasProofOfDelivery]);

  const reasons = target ? (REASON_CODES[target] ?? []) : [];

  async function submit(): Promise<void> {
    if (!target || !reasonCode) return;
    setBusy(true);
    setError(null);
    try {
      // 不传 idempotencyKey，让 http-client 自己生成：这是一次全新的写操作，
      // 重试时它会复用同一个键，正好是我们要的语义。
      const updated = await changeShipmentStatus(client, shipment.shipment_id, target, reasonCode);
      onChanged(updated);
      onClose();
    } catch (caught) {
      if (caught instanceof OfApiError) {
        setError(caught);
      } else {
        throw caught;
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="of-dialog" role="dialog" aria-modal="true" aria-label="变更运单状态">
      <header className="of-dialog__header">
        <h2>{shipment.reference}</h2>
        <p className="of-dialog__subtitle">
          当前状态 <strong>{shipment.status}</strong>
          {shipment.sla_deadline_at ? `，SLA ${formatRelative(shipment.sla_deadline_at)}` : ''}
        </p>
      </header>

      {allowed.length === 0 ? (
        <p className="of-dialog__empty">
          {shipment.status === 'held_at_customs'
            ? '这单在海关手上。状态会随 customs.declaration.cleared 自动变化，这里改不了。'
            : '这个状态是终态，没有可选的后续状态。'}
        </p>
      ) : (
        <form
          className="of-dialog__body"
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <label>
            目标状态
            <select
              value={target}
              onChange={(event) => {
                setTarget(event.target.value as ShipmentStatus);
                setReasonCode('');
              }}
            >
              <option value="">请选择</option>
              {allowed.map((status) => (
                <option key={status} value={status}>
                  {status}
                </option>
              ))}
            </select>
          </label>

          <label>
            原因码
            <select
              value={reasonCode}
              disabled={!target}
              onChange={(event) => setReasonCode(event.target.value)}
            >
              <option value="">请选择</option>
              {reasons.map((code) => (
                <option key={code} value={code}>
                  {code}
                </option>
              ))}
            </select>
          </label>

          {/*
            这里没有「备注」输入框，是刻意的：PATCH /v1/shipments/{shipment_id}/status
            只收 reason_code，自由文本没有地方落地。曾经加过一个备注框，内容被静默丢弃，
            而调度员以为它进了台账。要留言只能走 notification-service 的定向发送。
          */}
          {target === 'cancelled' ? (
            <p className="of-dialog__warning">
              作废之后这条运单不能再恢复。已经开出的发票需要在 billing 那边单独作废并出红字发票，
              这个操作不会替你做。
            </p>
          ) : null}

          {error ? (
            <p className="of-dialog__error" role="alert">
              {/* 按 code 分流而不是按 message：message 会随后端措辞变。 */}
              {error.code === 'invalid_status_transition'
                ? '这条迁移不被状态机接受 —— 多半是别人刚刚改过一次，请刷新后重试。'
                : error.code === 'shipment_already_sealed'
                  ? '这单已经封箱了。'
                  : isTransient(error)
                    ? '服务暂时不可用，请稍后重试。'
                    : `操作失败（${error.code}），请把这个编号交给支持：${error.traceId}`}
            </p>
          ) : null}

          <footer className="of-dialog__actions">
            <button type="button" onClick={onClose} disabled={busy}>
              取消
            </button>
            <button type="submit" disabled={busy || !target || !reasonCode}>
              {busy ? '提交中…' : '确认变更'}
            </button>
          </footer>
        </form>
      )}
    </div>
  );
}

/**
 * 给运单列表用的辅助函数：这条运单现在有没有可以手动做的动作。
 * 列表里那个「⋯」菜单据此决定要不要显示「变更状态」。
 */
export function hasManualTransition(
  status: ShipmentStatus,
  hasProofOfDelivery: boolean,
): boolean {
  const candidates = MANUAL_TRANSITIONS[status] ?? [];
  if (hasProofOfDelivery) return candidates.length > 0;
  return candidates.some((next) => next !== 'delivered');
}
