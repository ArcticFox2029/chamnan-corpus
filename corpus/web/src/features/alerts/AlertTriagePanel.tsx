/*
 * 值班台的告警分诊面板。它把 telemetry-ingest 的未关闭告警按严重度排好，
 * 并标出哪些已经把运单打成了 at_risk —— 值班的人需要一眼分清
 * 「系统已经替我升级了状态」和「还等着我处理」这两类。
 */

import { useCallback, useEffect, useMemo, useState } from 'react';

import {
  acknowledgeAlert,
  closeAlert,
  listAlerts,
  type TelemetryAlert,
} from '../../api/endpoints/telemetry';
import { isTransient, OfApiError } from '../../api/errors';
import { formatRelative } from '../../lib/format';
import { mergePage } from '../../api/pagination';
import type { ApiClient } from '../../api/http-client';
import type { ConsoleChannel } from '../../realtime/console-channel';
import type { AlertRuleCode, AlertSeverity } from '../../types/domain';
import type { AlertId } from '../../types/ids';

/** 面板属性。 */
export interface AlertTriagePanelProps {
  client: ApiClient;
  channel: ConsoleChannel | null;
  /**
   * 与 container-registry 的 `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` 保持一致。
   * 达到或超过这个严重度的告警会让 container-registry 把运单翻成 at_risk，
   * 面板据此在行首打上「已自动升级」的标记。
   */
  autoAtRiskSeverity: AlertSeverity;
  onOpenContainer: (containerId: string) => void;
}

/** 规则代码的中文短标签。文案与 telemetry-ingest 的 `OF_TELEMETRY_RULES_PATH` 一一对应。 */
const RULE_LABELS: Record<AlertRuleCode, string> = {
  temp_excursion_high: '温度超上限',
  temp_excursion_low: '温度低于下限',
  humidity_high: '湿度超标',
  shock_impact: '剧烈震动',
  door_open_in_transit: '在途开门',
  battery_critical: '电量告急',
  gateway_silent: '网关失联',
  geofence_breach: '越界',
};

/** 严重度 → 视觉等级。5 是最高。 */
function severityTone(severity: AlertSeverity): 'critical' | 'warning' | 'info' {
  if (severity >= 4) return 'critical';
  if (severity === 3) return 'warning';
  return 'info';
}

/**
 * 告警分诊面板。
 *
 * 数据来自 `GET /v1/alerts`，增量来自实时通道的 telemetry.alert.raised。
 * 认领和关闭是两个不同的动作：认领只写 `acknowledged_by`，
 * 关闭才写 `closed_at`；像 `shock_impact` 这种一次性事件不会自己关，
 * 必须现场处理完之后由人来关。
 */
export function AlertTriagePanel(props: AlertTriagePanelProps): JSX.Element {
  const { client, channel, autoAtRiskSeverity, onOpenContainer } = props;

  const [alerts, setAlerts] = useState<ReadonlyArray<TelemetryAlert>>([]);
  const [pending, setPending] = useState<ReadonlySet<AlertId>>(new Set());
  const [banner, setBanner] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const controller = new AbortController();
    listAlerts(client, { state: 'open' }, { limit: 100 }, { signal: controller.signal })
      .then((page) => setAlerts(page.items))
      .catch((error: unknown) => {
        if (!controller.signal.aborted) {
          setBanner(isTransient(error) ? '遥测服务暂时不可用，稍后自动重试' : String(error));
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });
    return () => controller.abort();
  }, [client]);

  useEffect(() => {
    if (!channel) return undefined;
    return channel.on('telemetry.alert.raised', (envelope) => {
      const p = envelope.payload;
      const incoming: TelemetryAlert = {
        alert_id: p.alert_id,
        container_id: p.container_id,
        shipment_id: p.shipment_id,
        rule_code: p.rule_code,
        severity: p.severity,
        opened_at: p.opened_at,
        closed_at: null,
        peak_value: p.peak_value,
        threshold_value: p.threshold_value,
        first_reading_id: p.first_reading_id,
        acknowledged_by: null,
        acknowledged_at: null,
      };
      // 实时推送与首屏请求会撞车，按 alert_id 合并而不是直接 unshift。
      setAlerts((prev) => mergePage(prev, [incoming], (a) => a.alert_id));
    });
  }, [channel]);

  const withPending = useCallback(
    async (alertId: AlertId, action: () => Promise<TelemetryAlert>) => {
      setPending((prev) => new Set(prev).add(alertId));
      try {
        const updated = await action();
        setAlerts((prev) => prev.map((a) => (a.alert_id === alertId ? updated : a)));
        setBanner(null);
      } catch (error) {
        // 幂等键让重复点击是安全的，所以这里只提示，不做本地状态回滚。
        setBanner(
          error instanceof OfApiError ? `${error.code}（trace ${error.traceId}）` : String(error),
        );
      } finally {
        setPending((prev) => {
          const next = new Set(prev);
          next.delete(alertId);
          return next;
        });
      }
    },
    [],
  );

  const onAcknowledge = useCallback(
    (alertId: AlertId) => withPending(alertId, () => acknowledgeAlert(client, alertId)),
    [client, withPending],
  );

  const onClose = useCallback(
    (alertId: AlertId, note: string) => withPending(alertId, () => closeAlert(client, alertId, note)),
    [client, withPending],
  );

  const rows = useMemo(() => {
    // 排序：先按严重度降序，同级再按最新在前。已认领的沉到各自分组的底部,
    // 因为它们已经有人在跟了。
    return [...alerts]
      .filter((a) => a.closed_at === null)
      .sort((a, b) => {
        if (a.severity !== b.severity) return b.severity - a.severity;
        const ackDelta = Number(Boolean(a.acknowledged_at)) - Number(Boolean(b.acknowledged_at));
        if (ackDelta !== 0) return ackDelta;
        return b.opened_at.localeCompare(a.opened_at);
      });
  }, [alerts]);

  if (loading) return <div className="alert-panel alert-panel--loading">正在载入告警…</div>;

  return (
    <section className="alert-panel" aria-label="遥测告警分诊">
      {banner && <p className="alert-panel__banner">{banner}</p>}
      <ol className="alert-panel__list">
        {rows.map((alert) => {
          const escalated = alert.severity >= autoAtRiskSeverity && alert.shipment_id !== null;
          return (
            <li key={alert.alert_id} className={`alert-row alert-row--${severityTone(alert.severity)}`}>
              <button type="button" className="alert-row__box" onClick={() => onOpenContainer(alert.container_id)}>
                {alert.container_id}
              </button>
              <span className="alert-row__rule">{RULE_LABELS[alert.rule_code]}</span>
              <span className="alert-row__value">
                {alert.peak_value ?? '—'} / 阈值 {alert.threshold_value}
              </span>
              <time className="alert-row__age" dateTime={alert.opened_at}>
                {formatRelative(alert.opened_at)}
              </time>
              {escalated && (
                <span className="alert-row__badge" title="container-registry 已把该运单置为 at_risk">
                  已自动升级
                </span>
              )}
              <span className="alert-row__actions">
                <button
                  type="button"
                  disabled={pending.has(alert.alert_id) || alert.acknowledged_at !== null}
                  onClick={() => onAcknowledge(alert.alert_id)}
                >
                  {alert.acknowledged_at ? '已认领' : '认领'}
                </button>
                <button
                  type="button"
                  disabled={pending.has(alert.alert_id)}
                  onClick={() => onClose(alert.alert_id, '现场已处理')}
                >
                  关闭
                </button>
              </span>
            </li>
          );
        })}
      </ol>
      {rows.length === 0 && <p className="alert-panel__empty">当前没有未关闭的告警。</p>}
    </section>
  );
}
