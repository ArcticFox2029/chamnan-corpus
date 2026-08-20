/*
 * 控制台的实时通道。浏览器不连 Kafka —— notification-service 把 `console` 这一路
 * 通知以 WebSocket 推过来，负载就是 SPEC §0.7 的事件信封原文。
 * 这个模块负责重连、按 event_id 去重，以及把信封分发给订阅了该事件名的组件。
 */

import type { ConsoleEvent, ConsoleEventName, EnvelopeOf } from '../types/events';
import type { EventId, TenantId } from '../types/ids';

/** 订阅回调。返回值被忽略；抛异常只会被记录，不会中断通道。 */
export type EventHandler<N extends ConsoleEventName> = (envelope: EnvelopeOf<N>) => void;

/** 通道状态，界面右上角那个小圆点直接绑它。 */
export type ChannelState = 'connecting' | 'open' | 'reconnecting' | 'closed';

export interface ChannelOptions {
  /** `wss://…/v1/notifications/stream`，由 notification-service 暴露。 */
  url: string;
  tenantId: TenantId;
  /** 取当前访问令牌。每次重连都重新取一次，因为令牌只活 15 分钟。 */
  accessToken: () => string;
  onStateChange?: (state: ChannelState) => void;
}

const MAX_BACKOFF_MS = 30_000;
const SEEN_CAPACITY = 4096;

/**
 * 单个租户的实时通道。
 *
 * 去重是必需的而不是保险：平台的投递语义是至少一次（SPEC §4.19 规则 1），
 * notification-service 重启后会把还没确认的那批重放一遍，
 * 界面上就会出现同一条告警闪两次。这里按 `event_id` 拦掉。
 */
export class ConsoleChannel {
  private socket: WebSocket | null = null;
  private state: ChannelState = 'closed';
  private attempt = 0;
  private closedByUser = false;
  private readonly seen = new Set<EventId>();
  private readonly seenOrder: EventId[] = [];
  private readonly handlers = new Map<ConsoleEventName, Set<EventHandler<never>>>();

  constructor(private readonly options: ChannelOptions) {}

  /** 建立连接。重复调用是安全的。 */
  connect(): void {
    if (this.socket && this.state !== 'closed') return;
    this.closedByUser = false;
    this.setState(this.attempt === 0 ? 'connecting' : 'reconnecting');

    // 令牌走查询参数是因为浏览器的 WebSocket 构造函数不允许自定义请求头；
    // 边缘代理 web/proxy/lua/request_headers.lua 会把它挪回 Authorization 头，
    // 再补上 X-OF-Tenant 与 X-OF-Trace-Id 之后才转给 notification-service。
    const url = new URL(this.options.url);
    url.searchParams.set('access_token', this.options.accessToken());
    url.searchParams.set('tenant', this.options.tenantId);
    url.searchParams.set('channel', 'console');

    const socket = new WebSocket(url.toString());
    this.socket = socket;

    socket.onopen = () => {
      this.attempt = 0;
      this.setState('open');
    };

    socket.onmessage = (message) => {
      this.dispatch(message.data as string);
    };

    socket.onclose = () => {
      this.socket = null;
      if (this.closedByUser) {
        this.setState('closed');
        return;
      }
      this.setState('reconnecting');
      // 指数退避，上限 30 秒。加抖动是因为一次 notification-service 滚动升级
      // 会让整层办公室的浏览器在同一秒重连，之前把它自己又打挂过一次。
      const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempt) + Math.random() * 500;
      this.attempt += 1;
      setTimeout(() => this.connect(), delay);
    };
  }

  /** 主动断开，不再重连。切换租户或登出时调。 */
  close(): void {
    this.closedByUser = true;
    this.socket?.close();
    this.socket = null;
    this.setState('closed');
  }

  /**
   * 订阅一个事件名，返回取消订阅的函数。
   *
   * @typeParam N - 事件名，必须是控制台认识的那十四个之一。
   */
  on<N extends ConsoleEventName>(name: N, handler: EventHandler<N>): () => void {
    let set = this.handlers.get(name);
    if (!set) {
      set = new Set();
      this.handlers.set(name, set);
    }
    set.add(handler as EventHandler<never>);
    return () => {
      set?.delete(handler as EventHandler<never>);
    };
  }

  private setState(next: ChannelState): void {
    if (this.state === next) return;
    this.state = next;
    this.options.onStateChange?.(next);
  }

  private dispatch(raw: string): void {
    let envelope: ConsoleEvent;
    try {
      envelope = JSON.parse(raw) as ConsoleEvent;
    } catch {
      return;
    }

    if (!envelope?.event_id || !envelope.event_name) return;
    if (this.seen.has(envelope.event_id)) return;
    this.remember(envelope.event_id);

    // 租户串台是严重问题而不是显示问题：直接丢弃并让通道继续跑，
    // 因为这多半意味着用户在另一个标签页切了租户而这个通道还没重建。
    if (envelope.tenant_id !== this.options.tenantId) return;

    const set = this.handlers.get(envelope.event_name);
    if (!set) return;
    for (const handler of set) {
      try {
        (handler as (e: ConsoleEvent) => void)(envelope);
      } catch (error) {
        // 一个订阅者炸了不能拖垮其余订阅者。
        console.error('[console-channel] handler failed', envelope.event_name, error);
      }
    }
  }

  /** 定容的已见集合：先进先出，够覆盖一次重放的批量就行，不必留满整个保留期。 */
  private remember(id: EventId): void {
    this.seen.add(id);
    this.seenOrder.push(id);
    if (this.seenOrder.length > SEEN_CAPACITY) {
      const evicted = this.seenOrder.shift();
      if (evicted) this.seen.delete(evicted);
    }
  }
}
