--[[
  边缘代理的装配点。nginx 的每个阶段只调用这里的一个函数，模块之间的先后顺序
  全部写在这一个文件里 —— 顺序错了后果都很安静：区域检查跑在鉴权之前，
  未认证的请求就能试探出哪些区域存在哪些租户。
--]]

local request_headers = require("proxy.lua.request_headers")
local introspect = require("proxy.lua.auth.introspect")
local jwks = require("proxy.lua.auth.jwks_cache")
local service_map = require("proxy.lua.upstream.service_map")
local region_guard = require("proxy.lua.policy.region_guard")
local partner_quota = require("proxy.lua.policy.partner_rate_limit")
local geofence_cache = require("proxy.lua.cache.geofence_geojson")
local document_guard = require("proxy.lua.upload.document_guard")
local access_log = require("proxy.lua.observability.access_log")
local envelope = require("proxy.lua.error_envelope")

local _M = { _VERSION = "4.2.0" }

--- init_by_lua_block：master 进程启动时跑一次。
-- 只做「拿不到就该起不来」的检查。缺 OF_REGION_CODE 而默认成 eu-west 的 Pod
-- 上过一次生产，结果是巴西的请求被欧洲的边缘接了 —— 宁可起不来。
function _M.init()
  local region = os.getenv("OF_REGION_CODE")
  if not region or region == "" then
    error("OF_REGION_CODE is mandatory: the edge cannot guess its own residency zone")
  end
  local service_name = os.getenv("OF_SERVICE_NAME")
  if service_name and service_name ~= "web-edge-proxy" then
    -- SPEC §5.1 要求这个值与 §1 的服务名对得上；代理不在那十四个里，
    -- 因此它用一个固定的名字，写错了会让日志归因到某个真实服务头上。
    ngx.log(ngx.WARN, "OF_SERVICE_NAME=", service_name,
      " does not match the edge proxy's own name")
  end
end

--- init_worker_by_lua_block：每个 worker 启动时跑。
function _M.init_worker()
  jwks.start_refresher()
end

--- rewrite_by_lua_block：选上游。
-- 排在鉴权之前，因为选不出上游的请求根本不值得去验令牌。
function _M.rewrite()
  service_map.run()
end

--- access_by_lua_block：这一串的顺序是这个文件存在的理由。
function _M.access()
  -- 1. 补齐 SPEC §0.3 的四个头，生成 trace-id。后面每一步都要用它。
  request_headers.run()
  -- 2. 验令牌。人的请求离线验签，凭据类的真去问 identity-service。
  introspect.run()
  -- 3. 数据驻留。必须在鉴权之后 —— 见文件头。
  region_guard.run()
  -- 4. 合作方配额。要拿到 key_prefix，所以只能排在内省之后。
  partner_quota.run()
  -- 5. 上传前置检查，只对 POST /v1/documents 生效。
  document_guard.run()
  -- 6. 围栏缓存命中就地应答，请求不进上游。放在最后是因为它会结束请求。
  geofence_cache.try_serve()
end

--- header_filter_by_lua_block。
function _M.header_filter()
  -- 把 trace-id 回给客户端。src/api/http-client.ts 优先用响应头里的这一个
  -- 来构造 OfApiError，因为上游可能换过（不该换，但发生过）。
  ngx.header["X-OF-Trace-Id"] = ngx.ctx.trace_id or ""
  -- 上游的 Content-Length 在我们可能改写响应体时必须去掉。
  if ngx.status >= 400 then
    ngx.header["Content-Length"] = nil
  end
end

--- body_filter_by_lua_block：按块累积，最后一块到齐时再处理。
-- 只对需要看完整响应体的两类请求缓冲：围栏 GeoJSON 和错误响应。
-- 遥测和列表接口一律直通 —— 在代理里缓冲一整页 200 条记录毫无意义。
function _M.body_filter()
  local chunk, eof = ngx.arg[1], ngx.arg[2]
  local interesting = ngx.status >= 400
    or ngx.ctx.geofence_cache == "miss"
    or ngx.ctx.upload_owner_type ~= nil

  if not interesting then
    return
  end

  ngx.ctx.buffer = (ngx.ctx.buffer or "") .. (chunk or "")
  if not eof then
    -- 抑制这一块的输出，等收齐再一次性发。
    ngx.arg[1] = nil
    return
  end

  local body = ngx.ctx.buffer

  if ngx.status >= 400 then
    body = envelope.coerce(ngx.status, body)
  elseif ngx.ctx.geofence_cache == "miss" then
    geofence_cache.store(body)
  elseif ngx.ctx.upload_owner_type then
    document_guard.log_result(body)
  end

  ngx.arg[1] = body
end

--- log_by_lua_block。
function _M.log()
  request_headers.log()
  access_log.run()
end

--- 代理自己的 /metrics。上游服务各有各的 /metrics（SPEC §3.15），
-- 这一个只报边缘视角的数据：谁被打得最多、边缘自己花了多少时间。
function _M.metrics()
  ngx.header["Content-Type"] = "text/plain; version=0.0.4"
  ngx.print(access_log.render())
end

--- 内部端点：凭据吊销。
-- notification-service 消费 identity.credential.revoked 之后以 webhook 打过来，
-- 五秒内必须生效（SPEC §4.2）。这个 location 只监听回环地址。
function _M.evict_credential()
  ngx.req.read_body()
  local args = ngx.req.get_post_args()
  local key_prefix = args.key_prefix
  if not key_prefix or #key_prefix ~= 12 then
    return envelope.abort(400, "key_prefix_malformed",
      "key_prefix must be the 12-character handle from identity.api_credentials")
  end

  local removed = introspect.evict_credential(key_prefix)
  partner_quota.forget(key_prefix)
  ngx.log(ngx.WARN, "credential ", key_prefix, " revoked, evicted ", removed, " cached introspections")
  ngx.status = 204
  return ngx.exit(204)
end

return _M
