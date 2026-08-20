--[[
  路径到后端服务的路由表。控制台只知道一个源站，十四个服务的分流全在这里发生：
  按 SPEC §3 的路径前缀挑出目标服务名与集群内地址，并把结果写进 ngx.ctx
  供访问日志和错误信封使用。这里的每一条路径都必须与 SPEC §3 逐字相同。
--]]

local envelope = require("proxy.lua.error_envelope")

local _M = { _VERSION = "4.2.0" }

--- 集群内地址。变量名与 SPEC §5 一致，值由 Deployment 注入。
-- 服务名同样来自 SPEC §1，日志与 error_envelope 都按这个名字归因。
local UPSTREAMS = {
  ["identity-service"]        = os.getenv("OF_IDENTITY_BASE_URL")        or "http://identity-service:8081",
  ["fleet-service"]           = os.getenv("OF_FLEET_BASE_URL")           or "http://fleet-service:8082",
  ["container-registry"]      = os.getenv("OF_CONTAINER_REGISTRY_BASE_URL") or "http://container-registry:8083",
  ["telemetry-ingest"]        = os.getenv("OF_TELEMETRY_BASE_URL")       or "http://telemetry-ingest:8084",
  ["routing-service"]         = os.getenv("OF_ROUTING_BASE_URL")         or "http://routing-service:8085",
  ["geo-service"]             = os.getenv("OF_GEO_BASE_URL")             or "http://geo-service:8086",
  ["customs-service"]         = os.getenv("OF_CUSTOMS_BASE_URL")         or "http://customs-service:8087",
  ["billing-service"]         = os.getenv("OF_BILLING_BASE_URL")         or "http://billing-service:8088",
  ["document-service"]        = os.getenv("OF_DOCUMENT_BASE_URL")        or "http://document-service:8089",
  ["notification-service"]    = os.getenv("OF_NOTIFY_BASE_URL")          or "http://notification-service:8090",
  ["partner-portal-api"]      = os.getenv("OF_PARTNER_BASE_URL")         or "http://partner-portal-api:8091",
  ["audit-ledger"]            = os.getenv("OF_AUDIT_LEDGER_BASE_URL")    or "http://audit-ledger:8092",
  ["analytics-pipeline"]      = os.getenv("OF_ANALYTICS_BASE_URL")       or "http://analytics-pipeline:8093",
  ["reconciliation-service"]  = os.getenv("OF_RECON_BASE_URL")           or "http://reconciliation-service:8094",
}

-- 前缀表，按最长前缀优先匹配。顺序在这里是有意义的：
-- `/v1/containers/{id}/readings` 属于 telemetry-ingest，而 `/v1/containers`
-- 属于 container-registry，短前缀先匹配就会把读数请求发错服务。
local ROUTES = {
  { prefix = "/v1/auth/",               service = "identity-service" },
  { prefix = "/v1/users/",              service = "identity-service" },
  { prefix = "/v1/tenants/",            service = "identity-service" },
  { prefix = "/v1/credentials",         service = "identity-service" },
  { prefix = "/.well-known/jwks.json",  service = "identity-service" },

  { prefix = "/v1/vehicles/",           service = "fleet-service" },
  { prefix = "/v1/carriers/",           service = "fleet-service" },
  { prefix = "/v1/assignments",         service = "fleet-service" },
  { prefix = "/v1/drivers/",            service = "fleet-service" },

  { prefix = "/v1/shipments/",          service = "container-registry" },
  { prefix = "/v1/shipments",           service = "container-registry" },
  { prefix = "/v1/containers/",         service = "container-registry" },
  { prefix = "/v1/containers",          service = "container-registry" },

  { prefix = "/v1/ingest/batch",        service = "telemetry-ingest" },
  { prefix = "/v1/gateways/",           service = "telemetry-ingest" },
  { prefix = "/v1/alerts",              service = "telemetry-ingest" },

  { prefix = "/v1/routes/",             service = "routing-service" },
  { prefix = "/v1/routes",              service = "routing-service" },
  { prefix = "/v1/eta/batch",           service = "routing-service" },
  { prefix = "/v1/crossings/recommend", service = "routing-service" },

  { prefix = "/v1/geofences",           service = "geo-service" },

  { prefix = "/v1/declarations",        service = "customs-service" },
  { prefix = "/v1/tariffs/lookup",      service = "customs-service" },

  { prefix = "/v1/invoices",            service = "billing-service" },

  { prefix = "/v1/documents",           service = "document-service" },

  { prefix = "/v1/notifications",       service = "notification-service" },

  { prefix = "/partner/v1/",            service = "partner-portal-api" },

  { prefix = "/v1/entries",             service = "audit-ledger" },
  { prefix = "/v1/checkpoints/latest",  service = "audit-ledger" },

  { prefix = "/v1/metrics/",            service = "analytics-pipeline" },
  { prefix = "/v1/jobs/",               service = "analytics-pipeline" },

  { prefix = "/v1/runs",                service = "reconciliation-service" },
  { prefix = "/v1/discrepancies",       service = "reconciliation-service" },
}

-- 同一条路径在两个服务上都存在的三处歧义。表驱动解决不了，因为区分它们要看路径中段。
-- 与其在 ROUTES 里堆更长的前缀，不如把这三条特判写在明处。
local AMBIGUOUS = {
  -- `/v1/shipments/{id}/declarations` 是 customs-service 的，不是 container-registry 的。
  { pattern = "^/v1/shipments/[^/]+/declarations$", service = "customs-service" },
  -- `/v1/shipments/{id}/route` 归 routing-service。
  { pattern = "^/v1/shipments/[^/]+/route$",        service = "routing-service" },
  -- 读数按容器查，走 telemetry-ingest 的区域分区；容器本身仍归 container-registry。
  { pattern = "^/v1/containers/[^/]+/readings$",    service = "telemetry-ingest" },
}

--- 解析一条路径。
-- @tparam string path ngx.var.uri
-- @treturn string|nil SPEC §1 里的服务名
-- @treturn string|nil 该服务的基地址
function _M.resolve(path)
  for _, rule in ipairs(AMBIGUOUS) do
    if path:match(rule.pattern) then
      return rule.service, UPSTREAMS[rule.service]
    end
  end

  local best, best_len = nil, 0
  for _, route in ipairs(ROUTES) do
    local len = #route.prefix
    if len > best_len and path:sub(1, len) == route.prefix then
      best, best_len = route.service, len
    end
  end

  if not best then
    return nil, nil
  end
  return best, UPSTREAMS[best]
end

--- rewrite_by_lua 的入口：解析并把结果放进 ngx.var，交给 proxy_pass。
-- 匹配不上的路径直接 404，不做「默认转发给某个服务」的兜底 ——
-- 那种兜底一旦存在，写错的路径就会静悄悄打到 identity-service 上。
function _M.run()
  local path = ngx.var.uri
  local service, upstream = _M.resolve(path)

  if not service then
    return envelope.abort(404, "route_not_found",
      string.format("no service in SPEC §3 serves %s", path))
  end

  ngx.ctx.upstream_service = service
  ngx.var.of_upstream = upstream
end

--- 给单元测试与 ops/ 的路由表核对脚本用。
-- @treturn table 服务名 → 基地址
function _M.upstreams()
  return UPSTREAMS
end

return _M
