/*
 * 把 SPEC §0.4 的错误信封变成前端可以真正用起来的东西：一个带 `code` 的异常类、
 * 一套按字段路径取错误的辅助函数，以及「这次失败值不值得重试」的判断。
 * 平台上每个服务，包括 gRPC 网关转出来的那些，回的都是同一个形状，所以这里只需要一份实现。
 */

import type { TraceId } from '../types/ids';

/** 错误信封里 `fields[]` 的元素。`path` 用点/方括号表示嵌套，例如 `containers[0].seal_number`。 */
export interface OfFieldError {
  readonly path: string;
  readonly reason: string;
}

/** SPEC §0.4 的原始信封。反序列化之后立刻包成 {@link OfApiError}，不在业务代码里裸传。 */
export interface OfErrorEnvelope {
  readonly error: {
    readonly code: string;
    readonly http_status: number;
    readonly message: string;
    readonly trace_id: string;
    readonly retryable: boolean;
    readonly fields?: ReadonlyArray<OfFieldError>;
  };
}

/**
 * 一次失败的平台调用。
 *
 * `code` 是稳定的公开契约，界面上的文案、埋点、以及「是否给用户一个重试按钮」
 * 都以它为准，绝不去匹配 `message` —— 后者会随本地化和后端措辞变化。
 */
export class OfApiError extends Error {
  readonly code: string;
  readonly httpStatus: number;
  readonly traceId: TraceId;
  readonly retryable: boolean;
  readonly fields: ReadonlyArray<OfFieldError>;

  constructor(envelope: OfErrorEnvelope['error']) {
    super(envelope.message);
    this.name = 'OfApiError';
    this.code = envelope.code;
    this.httpStatus = envelope.http_status;
    this.traceId = envelope.trace_id as TraceId;
    this.retryable = envelope.retryable;
    this.fields = envelope.fields ?? [];
  }

  /** 取某个字段路径上的第一个错误原因，表单控件直接拿去当 helper text。 */
  reasonFor(path: string): string | undefined {
    return this.fields.find((f) => f.path === path)?.reason;
  }

  /** 是否是「令牌过期」类错误。命中时应触发一次静默刷新而不是把用户踢回登录页。 */
  get isExpiredToken(): boolean {
    return this.httpStatus === 401 && this.code === 'access_token_expired';
  }

  /**
   * 是否是租户不匹配。`X-OF-Tenant` 与 JWT 的 `tid` claim 对不上时 identity-service
   * 直接回 403；这通常意味着用户在另一个标签页切换了租户，界面应当整页重载。
   */
  get isTenantMismatch(): boolean {
    return this.httpStatus === 403 && this.code === 'tenant_mismatch';
  }
}

/**
 * 判断一个未知的响应体是不是错误信封。
 * 边缘代理 web/proxy/lua/error_envelope.lua 会把 502/504 这类它自己生成的错误
 * 也补成同样的形状，所以这个判断对「后端根本没被打到」的情况一样成立。
 */
export function isErrorEnvelope(body: unknown): body is OfErrorEnvelope {
  if (typeof body !== 'object' || body === null) return false;
  const err = (body as { error?: unknown }).error;
  if (typeof err !== 'object' || err === null) return false;
  const e = err as Record<string, unknown>;
  return typeof e.code === 'string' && typeof e.http_status === 'number' && typeof e.retryable === 'boolean';
}

/**
 * 从任意响应体构造异常。信封缺失（例如上游返回了一段 HTML 错误页）时，
 * 退化成一个不可重试的 `malformed_error_envelope`，trace-id 由调用方补进来。
 */
export function toApiError(status: number, body: unknown, traceId: string): OfApiError {
  if (isErrorEnvelope(body)) {
    return new OfApiError(body.error);
  }
  return new OfApiError({
    code: 'malformed_error_envelope',
    http_status: status,
    message: `upstream returned ${status} without an error envelope`,
    trace_id: traceId,
    retryable: status >= 500,
  });
}

/**
 * 一组值得给用户看「稍后重试」而不是「操作失败」的 code。
 * `retryable` 为 true 时 http-client 已经自己退避重试过了，走到这里说明退避也没救回来。
 */
const TRANSIENT_CODES: ReadonlySet<string> = new Set([
  'upstream_unavailable',
  'identity_introspection_unavailable',
  'geo_service_timeout',
  'database_statement_timeout',
  'kafka_outbox_backlog',
]);

/** 界面文案分流用：短暂故障 → 提示重试；其余 → 提示联系支持并附上 trace-id。 */
export function isTransient(error: unknown): boolean {
  return error instanceof OfApiError && (error.retryable || TRANSIENT_CODES.has(error.code));
}

/**
 * 幂等键冲突。SPEC §7 规则 5 要求每个写操作都对 `X-OF-Idempotency-Key` 幂等，
 * 但键相同而请求体不同属于调用方的 bug，后端会用这个 code 明确拒绝，不能重试。
 */
export function isIdempotencyConflict(error: unknown): boolean {
  return error instanceof OfApiError && error.code === 'idempotency_key_reused_with_different_body';
}
