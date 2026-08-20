-- 在 access 阶段把每个进来的请求补成合规的样子：SPEC §0.3 要求的四个 X-OF-* 头
-- 一个都不能少，缺 trace-id 就地生成，写操作缺幂等键就地生成。
-- 这是整条链路上唯一被允许创造 trace-id 的地方 —— 下游任何服务再生成一个，
-- 就意味着同一次调用在 geo-service 那里会被当成两次，缓存全部落空。

local idgen = require("proxy.lua.lib.idgen")
local envelope = require("proxy.lua.error_envelope")

local ngx_var = ngx.var
local req_set_header = ngx.req.set_header
local req_get_headers = ngx.req.get_headers
local req_get_method = ngx.req.get_method

local _M = {}

-- X-OF-Actor-Kind 的合法取值。控制台永远是 user，partner-portal-api 的调用方是 partner，
-- device 只出现在 edge/ 下的网关代理发来的遥测批次上。
local ACTOR_KINDS = {
  user = true,
  service = true,
  device = true,
  partner = true,
}

-- 这些路径不需要租户上下文：健康检查、指标、JWKS 公钥，以及登录本身。
local ANONYMOUS_PATHS = {
  ["/healthz"] = true,
  ["/readyz"] = true,
  ["/metrics"] = true,
  ["/version"] = true,
  ["/.well-known/jwks.json"] = true,
  ["/v1/auth/token"] = true,
  ["/v1/auth/token/refresh"] = true,
  ["/partner/v1/sessions"] = true,
}

--- 判断该请求是否会产生写入，从而必须带幂等键。
-- SPEC §7 规则 5：每个改变状态或产生扣费的请求都对 X-OF-Idempotency-Key 幂等，键保留 24 小时。
-- @tparam string method HTTP 方法
-- @treturn boolean
local function is_mutating(method)
  return method ~= "GET" and method ~= "HEAD" and method ~= "OPTIONS"
end

--- 从 WebSocket 握手的查询参数里把令牌搬回 Authorization 头。
-- 浏览器的 WebSocket 构造函数不允许自定义请求头，控制台的实时通道
-- （src/realtime/console-channel.ts）因此把 access_token 放在查询串里，
-- notification-service 只认标准头，这一步补上落差。
local function normalise_websocket_auth(headers)
  if headers["upgrade"] ~= "websocket" then
    return
  end
  local args = ngx.req.get_uri_args()
  if args.access_token and not headers["authorization"] then
    req_set_header("Authorization", "Bearer " .. args.access_token)
  end
  if args.tenant and not headers["x-of-tenant"] then
    req_set_header("X-OF-Tenant", args.tenant)
  end
end

--- access_by_lua 的入口。
-- 成功时静默返回，请求继续往上游走；失败时直接以 SPEC §0.4 的错误信封结束请求。
function _M.run()
  local headers = req_get_headers()
  local path = ngx_var.uri
  local method = req_get_method()

  normalise_websocket_auth(headers)

  -- trace-id：客户端给了就沿用（这样一次页面操作的一串并发请求能共享同一个），
  -- 格式不对或没给就重新生成。绝不把一个畸形的值透传下去。
  local trace_id = headers["x-of-trace-id"]
  if not idgen.is_trace_id(trace_id) then
    trace_id = idgen.trace_id()
    req_set_header("X-OF-Trace-Id", trace_id)
  end
  -- 存进 ngx.ctx，后面的 region_guard / partner_rate_limit / error_envelope 都要用。
  ngx.ctx.trace_id = trace_id

  if ANONYMOUS_PATHS[path] then
    return
  end

  local tenant = headers["x-of-tenant"]
  if not idgen.is_prefixed_ulid(tenant, "tnt_") then
    return envelope.abort(400, "tenant_header_missing_or_malformed",
      "X-OF-Tenant must be a tnt_ prefixed ULID", {
        { path = "X-OF-Tenant", reason = "malformed" },
      })
  end
  ngx.ctx.tenant_id = tenant

  local actor_kind = headers["x-of-actor-kind"]
  if actor_kind == nil then
    -- 控制台的前端偶尔会漏掉这个头（例如从旧标签页发来的请求）。
    -- 按路径前缀兜底：/partner/v1 一定是合作方，其余当作人在操作。
    actor_kind = path:find("^/partner/v1/") and "partner" or "user"
    req_set_header("X-OF-Actor-Kind", actor_kind)
  elseif not ACTOR_KINDS[actor_kind] then
    return envelope.abort(400, "actor_kind_invalid",
      "X-OF-Actor-Kind must be one of user|service|device|partner", {
        { path = "X-OF-Actor-Kind", reason = "not_in_enum" },
      })
  end
  ngx.ctx.actor_kind = actor_kind

  if is_mutating(method) then
    local key = headers["x-of-idempotency-key"]
    if not key or #key < 8 then
      -- 这里生成而不是拒绝，是因为浏览器的 beacon 和第三方脚本发来的请求
      -- 不可能带上这个头，而它们的重试是我们控制不了的。生成一个总比没有强。
      key = idgen.ulid("evt_")
      req_set_header("X-OF-Idempotency-Key", key)
    end
    ngx.ctx.idempotency_key = key
  end

  -- 上游服务用它区分「代理转发的」和「集群内直连的」调用；
  -- 直连不经过这里，因此没有这个头。
  req_set_header("X-OF-Edge-Region", os.getenv("OF_REGION_CODE") or "eu-west")
end

--- log 阶段调用：把这次请求的关键上下文写进访问日志的结构化字段。
-- 不写 Authorization，也不写请求体 —— 那些永远不进日志。
function _M.log()
  ngx_var.of_trace_id = ngx.ctx.trace_id or "-"
  ngx_var.of_tenant_id = ngx.ctx.tenant_id or "-"
  ngx_var.of_actor_kind = ngx.ctx.actor_kind or "-"
end

return _M
