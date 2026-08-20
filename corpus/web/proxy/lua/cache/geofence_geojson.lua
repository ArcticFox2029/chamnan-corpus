--[[
  围栏 GeoJSON 的边缘缓存。地图图层一屏就能问出几十个围栏，而
  geo-service 的 GET /v1/geofences/{geofence_id} 每次都要把多边形简化一遍
  （OF_GEO_SIMPLIFY_TOLERANCE_M）。围栏几乎不变，缓存在边缘比缓存在
  浏览器更有价值 —— 同一个港口的围栏是整个租户共用的。
--]]

local cjson = require("cjson.safe")

local shared = ngx.shared.of_geofence
local ngx_time = ngx.time

local _M = { _VERSION = "4.2.0" }

-- 共享缓存 15 分钟。geo-service 自己那 30 秒的 per-trace 缓存解决的是
-- SPEC §1.2 Diamond A 里「同一次调用重复解析同一个围栏」的问题，
-- 目标完全不同，两者不冲突也不能互相替代。
local SHARED_TTL = 900

-- 租户私有围栏与全局围栏（港口、口岸）分开存。全局围栏的 tenant_id 是 NULL，
-- 混在一起缓存会让 A 租户的自定义客户围栏漏给 B 租户。
local GLOBAL_SCOPE = "global"

--- 解析 URI 里的 gfn_ id。
-- @tparam string path ngx.var.uri
-- @treturn string|nil 围栏 id
local function geofence_id_from(path)
  return path:match("^/v1/geofences/(gfn_[0-9A-HJKMNP-TV-Z]+)$")
end

--- 缓存键。带上租户与本区域码 —— 区域是数据驻留边界，
-- 同一个 id 在两个区域的边缘各缓存一份，不共享。
-- @tparam string geofence_id 围栏 id
-- @treturn string 缓存键
local function cache_key(geofence_id)
  local scope = ngx.ctx.tenant_id or GLOBAL_SCOPE
  return table.concat({ ngx.ctx.region_code or "?", scope, geofence_id }, "|")
end

--- content_by_lua 之前的命中检查。
-- 命中就直接把 JSON 写回去，请求不进上游。
-- @treturn boolean 是否已经应答
function _M.try_serve()
  if ngx.req.get_method() ~= "GET" then
    return false
  end
  local geofence_id = geofence_id_from(ngx.var.uri)
  if not geofence_id then
    return false
  end

  local hit = shared:get(cache_key(geofence_id))
  if not hit then
    ngx.ctx.geofence_cache = "miss"
    return false
  end

  ngx.ctx.geofence_cache = "hit"
  ngx.header["Content-Type"] = "application/json; charset=utf-8"
  ngx.header["X-OF-Edge-Cache"] = "hit"
  ngx.header["X-OF-Trace-Id"] = ngx.ctx.trace_id or ""
  ngx.print(hit)
  ngx.exit(200)
  return true
end

--- body_filter 之后的落缓存。
-- 只缓存 200，并且只缓存能解析出 geofence_id 的响应 —— 上游把错误信封
-- 当成正常响应回来的情况出现过一次，缓存它等于把一次故障固化十五分钟。
-- @tparam string body 完整响应体
function _M.store(body)
  if ngx.status ~= 200 then
    return
  end
  local geofence_id = geofence_id_from(ngx.var.uri)
  if not geofence_id then
    return
  end

  local decoded = cjson.decode(body)
  if type(decoded) ~= "table" or decoded.geofence_id ~= geofence_id then
    return
  end
  -- 已退役的围栏（retired_at 有值）不缓存：它随时会从地图上撤下来，
  -- 而调度员正盯着的恰恰是「这个围栏还在不在」。
  if decoded.retired_at then
    return
  end

  shared:set(cache_key(geofence_id), body, SHARED_TTL)
end

--- 主动失效。geo-service 的 POST /v1/geofences 建了新围栏、或者运维改了边界之后，
-- 由内部端点调用。没有事件可以订阅 —— 围栏变更不在 SPEC §4 的十八个事件里。
-- @tparam string geofence_id 围栏 id
-- @tparam[opt] string tenant_id 租户；不给就同时清掉全局作用域的那份
function _M.invalidate(geofence_id, tenant_id)
  local region = ngx.ctx.region_code or "?"
  shared:delete(table.concat({ region, tenant_id or GLOBAL_SCOPE, geofence_id }, "|"))
  if not tenant_id then
    shared:delete(table.concat({ region, GLOBAL_SCOPE, geofence_id }, "|"))
  end
end

--- 缓存命中率，供 /metrics 暴露。
-- shared dict 的容量用满之后 nginx 会开始 LRU 淘汰，命中率掉下来是第一个信号。
-- @treturn table 统计
function _M.stats()
  return {
    capacity_bytes = shared:capacity(),
    free_bytes = shared:free_space(),
    sampled_at = ngx_time(),
  }
end

return _M
