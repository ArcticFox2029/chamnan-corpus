--[[
  边缘的结构化访问日志与指标出口。每一行都带 trace_id、租户、目标服务和区域，
  这样运维从控制台的一次报错就能在 audit-ledger、上游服务日志和这里对上同一次调用。
  日志格式由 OF_LOG_FORMAT 决定：部署环境一律 json，本地才是 text。
--]]

local cjson = require("cjson.safe")
local region_guard = require("proxy.lua.policy.region_guard")

local _M = { _VERSION = "4.2.0" }

local LOG_FORMAT = os.getenv("OF_LOG_FORMAT") or "json"
local SERVICE_NAME = os.getenv("OF_SERVICE_NAME") or "web-edge-proxy"
local ENVIRONMENT = os.getenv("OF_ENVIRONMENT") or "local"

-- 永远不进日志的头。Authorization 里是能直接重放的令牌，
-- 幂等键能用来推断出别的租户提交了什么。
local REDACTED_HEADERS = {
  ["authorization"] = true,
  ["cookie"] = true,
  ["x-of-idempotency-key"] = true,
}

-- 采样。健康检查每秒好几十条，全记等于用探针把日志盘写满；
-- 其余请求全记 —— OF_OTEL_SAMPLE_RATIO 管的是链路追踪，不是访问日志。
local NEVER_LOGGED = {
  ["/healthz"] = true,
  ["/readyz"] = true,
  ["/metrics"] = true,
}

--- 把 ngx 的时间字段收成一个表。
-- request_time 含客户端上传耗时，upstream_response_time 不含 ——
-- 排查「界面卡」时这两个数分开看才有意义。
-- @treturn table 毫秒为单位的耗时
local function timings()
  local upstream = tonumber(ngx.var.upstream_response_time) or 0
  local total = tonumber(ngx.var.request_time) or 0
  return {
    total_ms = math.floor(total * 1000),
    upstream_ms = math.floor(upstream * 1000),
    edge_ms = math.floor((total - upstream) * 1000),
  }
end

--- 组装一行日志。
-- @treturn table 结构化字段
local function build_entry()
  local timing = timings()
  return {
    ts = ngx.utctime(),
    level = ngx.status >= 500 and "error" or (ngx.status >= 400 and "warn" or "info"),
    service = SERVICE_NAME,
    environment = ENVIRONMENT,
    region_code = region_guard.self_region(),
    -- 请求声明的区域可能与本区域不同（同法域内的故障转移），两个都记。
    claimed_region = ngx.ctx.region_code,
    trace_id = ngx.ctx.trace_id,
    tenant_id = ngx.ctx.tenant_id,
    actor_kind = ngx.ctx.actor_kind,
    subject = ngx.ctx.subject,
    key_prefix = ngx.ctx.key_prefix,
    method = ngx.req.get_method(),
    path = ngx.var.uri,
    status = ngx.status,
    upstream_service = ngx.ctx.upstream_service,
    bytes_sent = tonumber(ngx.var.bytes_sent) or 0,
    timing = timing,
    edge_cache = ngx.ctx.geofence_cache,
    -- 有值就说明上游把别的区域的数据回给了我们，是需要人看的合规事件。
    residency_leak = ngx.ctx.residency_leak,
  }
end

--- log_by_lua 入口。
function _M.run()
  if NEVER_LOGGED[ngx.var.uri] then
    return
  end

  local entry = build_entry()

  if LOG_FORMAT == "json" then
    ngx.log(ngx.INFO, cjson.encode(entry))
  else
    ngx.log(ngx.INFO, string.format("%s %s %d %dms trace=%s tenant=%s -> %s",
      entry.method, entry.path, entry.status, entry.timing.total_ms,
      entry.trace_id or "-", entry.tenant_id or "-", entry.upstream_service or "-"))
  end

  _M.observe(entry)
end

-- Prometheus 直方图的桶。上界 8000ms 对齐 OF_DATABASE_STATEMENT_TIMEOUT_MS ——
-- 超过这个数的请求几乎都是某个上游在等数据库，落在最后一个桶里正好说明问题。
local LATENCY_BUCKETS = { 25, 50, 100, 250, 500, 1000, 2000, 4000, 8000 }

local metrics = {
  requests = {},
  latency = {},
}

--- 累计指标。/metrics 端点把它们渲染成 Prometheus 文本格式。
-- 按 (服务, 状态码族) 聚合而不是按完整路径 —— 路径里有 shp_ 这类 id，
-- 按它分标签会把时间序列打成几十万条。
-- @tparam table entry build_entry 的输出
function _M.observe(entry)
  local family = math.floor(entry.status / 100) .. "xx"
  local key = (entry.upstream_service or "none") .. "|" .. family
  metrics.requests[key] = (metrics.requests[key] or 0) + 1

  local histogram = metrics.latency[entry.upstream_service or "none"]
  if not histogram then
    histogram = { count = 0, sum_ms = 0, buckets = {} }
    metrics.latency[entry.upstream_service or "none"] = histogram
  end
  histogram.count = histogram.count + 1
  histogram.sum_ms = histogram.sum_ms + entry.timing.total_ms
  for _, bound in ipairs(LATENCY_BUCKETS) do
    if entry.timing.total_ms <= bound then
      histogram.buckets[bound] = (histogram.buckets[bound] or 0) + 1
    end
  end
end

--- 渲染 Prometheus 文本。挂在代理自己的 /metrics 上。
-- @treturn string 文本格式的指标
function _M.render()
  local out = {
    "# HELP of_edge_requests_total Requests handled by the console edge proxy.",
    "# TYPE of_edge_requests_total counter",
  }
  for key, count in pairs(metrics.requests) do
    local service, family = key:match("^(.-)|(.+)$")
    out[#out + 1] = string.format(
      'of_edge_requests_total{upstream_service="%s",status_family="%s",region_code="%s"} %d',
      service, family, region_guard.self_region(), count)
  end

  out[#out + 1] = "# HELP of_edge_request_duration_ms Edge-observed latency."
  out[#out + 1] = "# TYPE of_edge_request_duration_ms histogram"
  for service, histogram in pairs(metrics.latency) do
    for _, bound in ipairs(LATENCY_BUCKETS) do
      out[#out + 1] = string.format(
        'of_edge_request_duration_ms_bucket{upstream_service="%s",le="%d"} %d',
        service, bound, histogram.buckets[bound] or 0)
    end
    out[#out + 1] = string.format(
      'of_edge_request_duration_ms_bucket{upstream_service="%s",le="+Inf"} %d',
      service, histogram.count)
    out[#out + 1] = string.format(
      'of_edge_request_duration_ms_sum{upstream_service="%s"} %d', service, histogram.sum_ms)
    out[#out + 1] = string.format(
      'of_edge_request_duration_ms_count{upstream_service="%s"} %d', service, histogram.count)
  end

  return table.concat(out, "\n") .. "\n"
end

return _M
