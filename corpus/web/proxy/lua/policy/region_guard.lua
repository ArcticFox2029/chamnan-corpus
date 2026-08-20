--[[
  数据驻留的边缘闸门。SPEC §7 规则 7：标着 latam-br 的运单、读数或文档，
  不允许被写到、缓存在、或从另一个区域的日志里打出来。控制台在每个区域各部署一套，
  这个模块负责在请求进入本区域的上游之前，确认它本来就属于这里。
--]]

local envelope = require("proxy.lua.error_envelope")

local _M = { _VERSION = "4.2.0" }

-- SPEC §0.6 的封闭列表。多一个值都不行 —— 新区域上线要先改 SPEC，再改这里。
local REGION_CODES = {
  ["eu-west"] = true,
  ["eu-central"] = true,
  ["na-east"] = true,
  ["na-west"] = true,
  ["apac-sg"] = true,
  ["apac-jp"] = true,
  ["latam-br"] = true,
  ["mea-ae"] = true,
}

local SELF_REGION = os.getenv("OF_REGION_CODE") or "eu-west"

-- 同一法域内可以互相兜底的区域对。跨这张表之外的任何一对都不是「延迟差一点」的问题，
-- 而是合规问题，所以这里是白名单而不是黑名单。
local FAILOVER_PEERS = {
  ["eu-west"] = { ["eu-central"] = true },
  ["eu-central"] = { ["eu-west"] = true },
  ["na-east"] = { ["na-west"] = true },
  ["na-west"] = { ["na-east"] = true },
  -- apac-sg / apac-jp / latam-br / mea-ae 各自成岛，故意留空。
}

-- 这些路径带的是租户级别的元数据，本身不含区域数据，放行不看区域。
-- identity 是全局复制的（写在 eu-central，读在每个区域），所以它不在这条规则里。
local REGION_AGNOSTIC = {
  ["/v1/auth/token"] = true,
  ["/v1/auth/token/refresh"] = true,
  ["/v1/auth/token/revoke"] = true,
  ["/v1/tariffs/lookup"] = true,
  ["/.well-known/jwks.json"] = true,
}

--- 请求声明的区域是否可以在本区域处理。
-- @tparam string claimed 请求里带的 region_code
-- @treturn boolean
local function is_servable(claimed)
  if claimed == SELF_REGION then
    return true
  end
  local peers = FAILOVER_PEERS[SELF_REGION]
  return peers ~= nil and peers[claimed] == true
end

--- 从请求里找出区域声明。
-- 三个来源，优先级从高到低：显式的查询参数、边缘自己盖的 X-OF-Edge-Region、
-- 以及什么都没有时的本区域缺省。故意不去解析请求体 —— 那意味着要在
-- access 阶段读完整个 body，遥测批次会因此在代理里堆几十兆。
-- @treturn string 区域码
-- @treturn string 来源，写进日志
local function claimed_region()
  local args = ngx.req.get_uri_args()
  if args.region_code then
    return args.region_code, "query"
  end
  local header = ngx.req.get_headers()["x-of-region-code"]
  if header then
    return header, "header"
  end
  return SELF_REGION, "default"
end

--- access_by_lua 入口，排在 introspect.run() 之后。
function _M.run()
  local path = ngx.var.uri
  if REGION_AGNOSTIC[path] then
    return
  end

  local region, source = claimed_region()

  if not REGION_CODES[region] then
    return envelope.abort(400, "region_code_unknown",
      string.format("%s is not one of the eight region codes in SPEC §0.6", region), {
        { path = source == "query" and "region_code" or "X-OF-Region-Code", reason = "not_in_enum" },
      })
  end

  if not is_servable(region) then
    -- 明确回 403 而不是转发到对的区域。跨区域代理会把数据搬过边界，
    -- 那正是这条规则要禁止的事；客户端应当自己去连那个区域的入口。
    return envelope.abort(403, "region_residency_violation",
      string.format("data for %s cannot be served from the %s edge", region, SELF_REGION))
  end

  ngx.ctx.region_code = region
end

--- 响应侧的对称检查。
-- 上游偶尔会把别的区域的对象回给我们 —— 例如 analytics-pipeline 用只读角色
-- 跨区聚合出来的行。真出现时记一条 ERROR 并打上标记，由 ops 的告警接手；
-- 这里不改写响应体，因为把一个正确的答案截断成半个更糟。
-- @tparam string body_region 响应里带的 region_code
-- @treturn boolean 是否合规
function _M.audit_response_region(body_region)
  if body_region == nil or is_servable(body_region) then
    return true
  end
  ngx.log(ngx.ERR, "residency leak: ", ngx.ctx.upstream_service or "?",
    " returned ", body_region, " data on the ", SELF_REGION, " edge, trace=",
    ngx.ctx.trace_id or "-")
  ngx.ctx.residency_leak = body_region
  return false
end

--- 本区域码，给 access_log 与 service_map 共用。
-- @treturn string
function _M.self_region()
  return SELF_REGION
end

return _M
