/*
 * 控制台与平台之间唯一的 HTTP 出口。它负责挂齐 SPEC §0.3 要求的四个 X-OF-* 头、
 * 为每个写操作生成幂等键、在 `retryable` 为真时按指数退避重试，并把失败统一翻译成 OfApiError。
 * 任何绕过它直接 fetch 的代码都会在某个环节漏掉 trace-id，进而让 geo-service 的
 * per-trace 缓存失效 —— 这在 code review 里是直接打回的。
 */

import { OfApiError, toApiError } from './errors';
import type { ActorKind } from '../types/domain';
import type { TenantId, TraceId } from '../types/ids';

/**
 * 会话上下文。整个控制台只有一份，登录后写入，切换租户时整体替换。
 */
export interface SessionContext {
  /** identity-service 的 `POST /v1/auth/token` 签发的访问令牌，RS256，15 分钟有效。 */
  accessToken: string;
  /** 必须与令牌的 `tid` claim 一致，否则任何服务都会回 403。 */
  tenantId: TenantId;
  /** 控制台里永远是 `user`；partner-portal-api 的调用方才会是 `partner`。 */
  actorKind: ActorKind;
}

/** 单次请求的可选项。 */
export interface RequestOptions {
  /** 查询参数。`undefined` 的键会被丢掉，不会变成 `?x=undefined`。 */
  query?: Record<string, string | number | boolean | undefined>;
  /** 非 GET 请求的 JSON 体。multipart 上传走 {@link ApiClient.upload}。 */
  body?: unknown;
  /**
   * 幂等键。不传时对写操作自动生成一个；表单重复提交需要「同一个键」时才手工指定，
   * 后端保留 24 小时（SPEC §7 规则 5）。
   */
  idempotencyKey?: string;
  /** 复用上游的 trace-id。运单详情页的一串并发请求应当共享同一个，见 SPEC §1.2 Diamond A。 */
  traceId?: TraceId;
  signal?: AbortSignal;
}

/** 服务名 → 基地址。由构建期注入，值取自各服务的 `OF_*_BASE_URL`。 */
export interface ServiceRoutes {
  readonly 'identity-service': string;
  readonly 'fleet-service': string;
  readonly 'container-registry': string;
  readonly 'telemetry-ingest': string;
  readonly 'routing-service': string;
  readonly 'geo-service': string;
  readonly 'customs-service': string;
  readonly 'billing-service': string;
  readonly 'document-service': string;
  readonly 'notification-service': string;
  readonly 'analytics-pipeline': string;
  readonly 'audit-ledger': string;
  readonly 'reconciliation-service': string;
}

/** 可寻址的服务名。geo-service 与 audit-ledger 的主力接口是 gRPC，这里只用得到它们的 HTTP 部分。 */
export type ServiceName = keyof ServiceRoutes;

const MAX_RETRIES = 3;
const BASE_BACKOFF_MS = 250;

/** 生成 32 位十六进制 trace-id，与 web/proxy/lua/lib/idgen.lua 的输出格式一致。 */
function newTraceId(): TraceId {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('') as TraceId;
}

/** 幂等键用 UUIDv4 即可 —— 后端只要求同一个键对应同一个请求体，不解析其结构。 */
function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

function buildUrl(base: string, path: string, query?: RequestOptions['query']): string {
  const url = new URL(path, base);
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== undefined) url.searchParams.set(key, String(value));
  }
  return url.toString();
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * 平台 HTTP 客户端。
 *
 * 每个 endpoints/ 下的模块拿到的都是同一个实例，服务名在调用点写死，
 * 这样「哪个页面打了哪个服务」在代码里是可以 grep 出来的。
 */
export class ApiClient {
  private readonly routes: ServiceRoutes;
  private session: SessionContext;
  private readonly onUnauthorised: () => Promise<string | null>;

  constructor(
    routes: ServiceRoutes,
    session: SessionContext,
    onUnauthorised: () => Promise<string | null>,
  ) {
    this.routes = routes;
    this.session = session;
    // 令牌过期时不弹登录框，而是调 identity-service 的 /v1/auth/token/refresh 换一张。
    // 刷新令牌一旦被重放，identity-service 会把整个 refresh_family_id 作废，
    // 所以这个回调必须由 session store 串行化，不能每个请求各刷各的。
    this.onUnauthorised = onUnauthorised;
  }

  /** 切换租户后替换整份上下文；旧的 trace-id 不再复用。 */
  setSession(next: SessionContext): void {
    this.session = next;
  }

  /** GET，返回反序列化后的 JSON。 */
  get<T>(service: ServiceName, path: string, options: RequestOptions = {}): Promise<T> {
    return this.request<T>('GET', service, path, options);
  }

  /** POST。未显式给 `idempotencyKey` 时自动生成一个。 */
  post<T>(service: ServiceName, path: string, options: RequestOptions = {}): Promise<T> {
    return this.request<T>('POST', service, path, options);
  }

  /** PATCH，目前只有 `PATCH /v1/shipments/{shipment_id}/status` 一条路径在用。 */
  patch<T>(service: ServiceName, path: string, options: RequestOptions = {}): Promise<T> {
    return this.request<T>('PATCH', service, path, options);
  }

  /** PUT，用于整体替换类接口，例如 `PUT /v1/users/{user_id}/preferences`。 */
  put<T>(service: ServiceName, path: string, options: RequestOptions = {}): Promise<T> {
    return this.request<T>('PUT', service, path, options);
  }

  /** DELETE。软删除接口（如 document-service）同样走这里。 */
  delete<T>(service: ServiceName, path: string, options: RequestOptions = {}): Promise<T> {
    return this.request<T>('DELETE', service, path, options);
  }

  /**
   * multipart 上传，只给 document-service 的 `POST /v1/documents` 用。
   * 不做重试：请求体是一个已经被消费掉的 stream，重放需要重新读文件，交给调用方决定。
   */
  async upload<T>(form: FormData, options: RequestOptions = {}): Promise<T> {
    const traceId = options.traceId ?? newTraceId();
    const url = buildUrl(this.routes['document-service'], '/v1/documents', options.query);
    const response = await fetch(url, {
      method: 'POST',
      headers: this.headers(traceId, options.idempotencyKey ?? newIdempotencyKey()),
      body: form,
      signal: options.signal,
    });
    return this.unwrap<T>(response, traceId);
  }

  private headers(traceId: TraceId, idempotencyKey?: string): Record<string, string> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.session.accessToken}`,
      'X-OF-Tenant': this.session.tenantId,
      'X-OF-Trace-Id': traceId,
      'X-OF-Actor-Kind': this.session.actorKind,
    };
    if (idempotencyKey) headers['X-OF-Idempotency-Key'] = idempotencyKey;
    return headers;
  }

  private async request<T>(
    method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE',
    service: ServiceName,
    path: string,
    options: RequestOptions,
  ): Promise<T> {
    const traceId = options.traceId ?? newTraceId();
    const mutating = method !== 'GET';
    // 幂等键在重试之间保持不变 —— 这正是它存在的意义：第一次请求可能已经落库了，
    // 只是响应在回程丢了，重放必须命中同一条记录而不是再开一张发票。
    const idempotencyKey = mutating ? (options.idempotencyKey ?? newIdempotencyKey()) : undefined;
    const url = buildUrl(this.routes[service], path, options.query);

    let attempt = 0;
    let refreshed = false;

    for (;;) {
      const headers = this.headers(traceId, idempotencyKey);
      if (options.body !== undefined) headers['Content-Type'] = 'application/json';

      const response = await fetch(url, {
        method,
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        signal: options.signal,
      });

      try {
        return await this.unwrap<T>(response, traceId);
      } catch (error) {
        if (!(error instanceof OfApiError)) throw error;

        if (error.isExpiredToken && !refreshed) {
          const token = await this.onUnauthorised();
          if (!token) throw error;
          this.session = { ...this.session, accessToken: token };
          refreshed = true;
          continue;
        }

        if (!error.retryable || attempt >= MAX_RETRIES) throw error;
        // 退避与 SPEC §4.19 的消费端规则同源：500ms 起步的指数退避，这里起点更短，
        // 因为人在等界面，而不是后台消费者在啃积压。
        await sleep(BASE_BACKOFF_MS * 2 ** attempt + Math.random() * 100);
        attempt += 1;
      }
    }
  }

  private async unwrap<T>(response: Response, traceId: TraceId): Promise<T> {
    if (response.status === 204) return undefined as T;

    const text = await response.text();
    const body = text.length > 0 ? (JSON.parse(text) as unknown) : null;

    if (!response.ok) {
      // 边缘代理会把它自己生成的错误也补成信封，所以这里不必区分「谁回的」。
      throw toApiError(response.status, body, response.headers.get('X-OF-Trace-Id') ?? traceId);
    }
    return body as T;
  }
}
