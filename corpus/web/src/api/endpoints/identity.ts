/*
 * identity-service 的调用封装：登录、令牌轮换、组织树维护、API 凭据管理。
 * 这里有一条整个控制台都绕不开的约束 —— 刷新令牌一旦被重放，identity-service
 * 会作废整个 refresh_family_id，所以 refreshToken 必须由 session store 串行化调用，
 * 绝不能让两个并发请求各刷各的。
 */

import { fetchPage, type Page, type PageRequest } from '../pagination';
import type { ApiClient, RequestOptions } from '../http-client';
import type { ActorKind, CountryCode, RegionCode } from '../../types/domain';
import type {
  CredentialId,
  OrgUnitId,
  SessionId,
  TenantId,
  UserId,
} from '../../types/ids';

const SERVICE = 'identity-service' as const;

/** 令牌对。`access_token` 活 15 分钟（OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS）。 */
export interface TokenPair {
  readonly access_token: string;
  readonly refresh_token: string;
  readonly expires_in: number;
  readonly session_id: SessionId;
  readonly tenant_id: TenantId;
  readonly user_id: UserId;
  readonly actor_kind: ActorKind;
}

/** 密码 + MFA 登录。合作方走的是 partner-portal-api 的 `POST /partner/v1/sessions`，不是这里。 */
export interface PasswordGrant {
  grant_type: 'password';
  email: string;
  password: string;
  /** TOTP 六位码。用户尚未绑定 MFA 时可以不带，后端按租户策略决定拒不拒。 */
  mfa_code?: string;
  tenant_id: TenantId;
}

/** 机器对机器的凭据登录，控制台里只有「凭据自测」那个按钮会用。 */
export interface ClientCredentialsGrant {
  grant_type: 'client_credentials';
  key_prefix: string;
  secret: string;
}

/** 一条被展平之后的授权。`inherited_from` 有值说明这条权限来自某个祖先组织单元。 */
export interface EffectiveRole {
  readonly role_id: string;
  readonly code: string;
  readonly scope_level: 'tenant' | 'org_unit' | 'shipment';
  readonly org_unit_id: OrgUnitId;
  readonly inherited_from: OrgUnitId | null;
  readonly expires_at: string | null;
}

/** 组织单元。`materialised_path` 是后端反规范化出来的，前端只读不算。 */
export interface OrgUnit {
  readonly org_unit_id: OrgUnitId;
  readonly tenant_id: TenantId;
  readonly parent_org_unit_id: OrgUnitId | null;
  readonly name: string;
  readonly materialised_path: string;
  readonly depth: number;
  readonly cost_centre: string | null;
  readonly archived_at: string | null;
}

/** 用户档案。`locale` 决定通知模板的语言，不决定控制台界面的语言。 */
export interface UserProfile {
  readonly user_id: UserId;
  readonly tenant_id: TenantId;
  readonly primary_org_unit_id: OrgUnitId;
  readonly email: string;
  readonly display_name: string;
  readonly locale: string;
  readonly status: 'invited' | 'active' | 'locked' | 'disabled';
  readonly mfa_enrolled_at: string | null;
  readonly last_login_at: string | null;
}

/** 新建凭据的响应。`secret` 只在这一次出现，之后后端只留 argon2id 散列。 */
export interface MintedCredential {
  readonly credential_id: CredentialId;
  readonly key_prefix: string;
  readonly secret: string;
  readonly scopes: ReadonlyArray<string>;
  readonly created_at: string;
}

/** 租户元信息，切换租户的下拉框用。 */
export interface TenantRef {
  readonly tenant_id: TenantId;
  readonly legal_name: string;
  readonly country_code: CountryCode;
  readonly home_region_code: RegionCode;
  readonly tier: 'trial' | 'standard' | 'enterprise' | 'internal';
  readonly status: 'active' | 'suspended' | 'closed';
}

/**
 * 登录。
 *
 * 这个调用不带 `Authorization` 头 —— 边缘代理的 request_headers.lua 把
 * `/v1/auth/token` 列在匿名路径里，所以这里传一个空会话上下文的 client 也能过。
 */
export function requestToken(
  client: ApiClient,
  grant: PasswordGrant | ClientCredentialsGrant,
  options?: RequestOptions,
): Promise<TokenPair> {
  return client.post<TokenPair>(SERVICE, '/v1/auth/token', { ...options, body: grant });
}

/**
 * 轮换刷新令牌。
 *
 * 必须串行：identity-service 把重复使用同一张刷新令牌当作被盗用的信号，
 * 会连坐作废整个 `refresh_family_id`，用户所有标签页一起掉线。
 * http-client 的 `onUnauthorised` 回调就是为了把这件事收在一个地方。
 */
export function refreshToken(
  client: ApiClient,
  refreshTokenValue: string,
  options?: RequestOptions,
): Promise<TokenPair> {
  return client.post<TokenPair>(SERVICE, '/v1/auth/token/refresh', {
    ...options,
    body: { refresh_token: refreshTokenValue },
  });
}

/**
 * 登出。`scope: 'family'` 把这个用户在所有设备上的会话一起吊销，
 * 「我怀疑账号被盗」那个按钮用的就是它。
 */
export function revokeToken(
  client: ApiClient,
  input: { session_id?: SessionId; refresh_token?: string; scope: 'session' | 'family' },
  options?: RequestOptions,
): Promise<void> {
  return client.post<void>(SERVICE, '/v1/auth/token/revoke', { ...options, body: input });
}

/** 读一个用户。时间线上的操作人头像会批量调它，结果在会话内缓存。 */
export function getUser(
  client: ApiClient,
  userId: UserId,
  options?: RequestOptions,
): Promise<UserProfile> {
  return client.get<UserProfile>(SERVICE, `/v1/users/${userId}`, options);
}

/**
 * 取展平之后的有效权限。
 *
 * 后端会把 identity.org_units 的整条祖先链走完再返回，前端不要自己按
 * `materialised_path` 推算 —— 那等于把授权逻辑抄一份到浏览器里，
 * 而浏览器里的那一份永远是可以被绕过的。
 */
export function getEffectiveRoles(
  client: ApiClient,
  userId: UserId,
  options?: RequestOptions,
): Promise<{ items: ReadonlyArray<EffectiveRole> }> {
  return client.get<{ items: ReadonlyArray<EffectiveRole> }>(
    SERVICE,
    `/v1/users/${userId}/effective-roles`,
    options,
  );
}

/** 建一个组织单元。深度受 OF_IDENTITY_MAX_ORG_DEPTH 限制，超了回 422。 */
export function createOrgUnit(
  client: ApiClient,
  tenantId: TenantId,
  input: { name: string; parent_org_unit_id: OrgUnitId | null; cost_centre?: string },
  options?: RequestOptions,
): Promise<OrgUnit> {
  return client.post<OrgUnit>(SERVICE, `/v1/tenants/${tenantId}/org-units`, {
    ...options,
    body: input,
  });
}

/**
 * 改名或换父节点。
 *
 * 换父节点会让 identity-service 重写整棵子树的 `materialised_path`，
 * 组织树很深的租户上这个调用会明显变慢；界面上必须给出确认框，
 * 不能做成拖拽即生效。
 */
export function updateOrgUnit(
  client: ApiClient,
  tenantId: TenantId,
  orgUnitId: OrgUnitId,
  patch: { name?: string; parent_org_unit_id?: OrgUnitId; cost_centre?: string | null },
  options?: RequestOptions,
): Promise<OrgUnit> {
  return client.patch<OrgUnit>(SERVICE, `/v1/tenants/${tenantId}/org-units/${orgUnitId}`, {
    ...options,
    body: patch,
  });
}

/**
 * 铸一把 API 凭据。
 *
 * 响应里的 `secret` 是它这辈子唯一一次出现，界面必须当场让用户复制走，
 * 并且不许写进任何持久化的状态（localStorage、URL、埋点）。
 */
export function mintCredential(
  client: ApiClient,
  input: { label: string; scopes: ReadonlyArray<string> },
  options?: RequestOptions,
): Promise<MintedCredential> {
  return client.post<MintedCredential>(SERVICE, '/v1/credentials', { ...options, body: input });
}

/**
 * 吊销凭据。
 *
 * identity-service 会发 `identity.credential.revoked`；notification-service 把它
 * 转成 webhook 打给边缘代理，代理清掉 introspect.lua 里缓存的内省结果。
 * SPEC §4.2 要求 5 秒内生效，所以界面上「已吊销」可以立刻显示，不必轮询确认。
 */
export function revokeCredential(
  client: ApiClient,
  credentialId: CredentialId,
  reason: string,
  options?: RequestOptions,
): Promise<void> {
  return client.delete<void>(SERVICE, `/v1/credentials/${credentialId}`, {
    ...options,
    query: { reason },
  });
}

/** 凭据列表，游标分页。 */
export function listCredentials(
  client: ApiClient,
  request: PageRequest = {},
  options?: RequestOptions,
): Promise<Page<MintedCredential>> {
  return fetchPage<MintedCredential>(client, SERVICE, '/v1/credentials', request, options);
}

/**
 * 组织树的展开顺序。
 *
 * 按 `materialised_path` 排序，天然就是先序遍历的结果 —— 这也是后端
 * 反规范化这一列的原因之一，前端不需要递归就能画出缩进。
 */
export function sortOrgUnits(units: ReadonlyArray<OrgUnit>): OrgUnit[] {
  return [...units].sort((a, b) => a.materialised_path.localeCompare(b.materialised_path));
}

/** 用户是否持有某个角色 code，用来决定按钮显不显示。真正的拦截在后端。 */
export function hasRole(roles: ReadonlyArray<EffectiveRole>, code: string): boolean {
  const now = Date.now();
  return roles.some(
    (role) => role.code === code && (!role.expires_at || Date.parse(role.expires_at) > now),
  );
}
