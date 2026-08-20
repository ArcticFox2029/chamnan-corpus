--[[
  代理侧的错误出口。凡是请求还没走到上游就被拦下来的情况 —— 租户头缺失、
  合作方超配额、跨区域访问被拒、上游连不上 —— 都必须回一个与 SPEC §0.4
  逐字相同的信封，否则控制台的 src/api/errors.ts 认不出来，会退化成
  `malformed_error_envelope`，用户看到的是一句没有意义的报错。
--]]

local cjson = require("cjson.safe")

local ngx_say = ngx.say
local ngx_exit = ngx.exit
local ngx_header = ngx.header

local _M = { _VERSION = "4.2.0" }

-- 哪些状态码值得客户端退避重试。信封里的 `retryable` 直接驱动
-- src/api/http-client.ts 的指数退避，所以这张表比它看上去重要得多：
-- 把 409 标成可重试，界面就会自己重复提交一张已经开出去的发票。
local RETRYABLE_STATUS = {
  [429] = true,
  [502] = true,
  [503] = true,
  [504] = true,
}

--- 组装信封但不发送。
-- 单元测试与 log 阶段的取样都需要拿到这个表本身。
-- @tparam number status HTTP 状态码
-- @tparam string code snake_case 的稳定错误码，属于公开契约
-- @tparam string message 面向开发者的英文说明，永远不本地化
-- @tparam[opt] table fields 形如 { { path = "...", reason = "..." } } 的字段级错误
-- @treturn table 可直接 cjson 编码的信封
function _M.build(status, code, message, fields)
  local retryable = RETRYABLE_STATUS[status] or false
  return {
    error = {
      code = code,
      http_status = status,
      message = message,
      -- trace-id 由 request_headers.lua 在最开始写进 ngx.ctx；
      -- 万一它自己就是失败的那一步，退回一个全零值，让日志里仍然能对上这一行。
      trace_id = ngx.ctx.trace_id or string.rep("0", 32),
      retryable = retryable,
      fields = fields or nil,
    },
  }
end

--- 组装并结束请求。
-- 调用方一律写成 `return envelope.abort(...)`，因为 ngx.exit 之后的代码不再执行，
-- 但 Lua 不会因此报错 —— 漏掉 return 的话后面的逻辑仍会跑，只是写不出去。
-- @tparam number status HTTP 状态码
-- @tparam string code 错误码
-- @tparam string message 说明
-- @tparam[opt] table fields 字段级错误
function _M.abort(status, code, message, fields)
  ngx.status = status
  ngx_header["Content-Type"] = "application/json; charset=utf-8"
  -- 把 trace-id 回给客户端。界面的「联系支持」按钮会把它一起带上，
  -- 这样运维在 audit-ledger 与访问日志里能查到同一次调用。
  ngx_header["X-OF-Trace-Id"] = ngx.ctx.trace_id or ""
  ngx_say(cjson.encode(_M.build(status, code, message, fields)))
  return ngx_exit(status)
end

--- 把上游返回的非信封响应补成信封。
-- 用在 body_filter 阶段：某个服务在崩溃路径上回了 HTML 或空体时，
-- 客户端不该因为「解析不了错误」而丢掉真正的状态码。
-- @tparam number status 上游状态码
-- @tparam string body 上游响应体
-- @treturn string 一定是合法 JSON 的响应体
function _M.coerce(status, body)
  local decoded = cjson.decode(body)
  if type(decoded) == "table" and type(decoded.error) == "table"
      and type(decoded.error.code) == "string" then
    -- 上游自己回的信封原样透传，包括它的 trace_id —— 那是它记在日志里的那一个。
    return body
  end

  local service = ngx.ctx.upstream_service or "unknown"
  return cjson.encode(_M.build(
    status,
    "upstream_returned_no_envelope",
    string.format("%s returned %d without an error envelope", service, status)
  ))
end

--- 上游连不上时的统一出口。
-- proxy_next_upstream 用尽之后 nginx 会给出 502/504，我们把它翻译成
-- src/api/errors.ts 里 TRANSIENT_CODES 认得的 `upstream_unavailable`，
-- 界面才会显示「稍后重试」而不是「操作失败」。
-- @tparam string service SPEC §1 里的服务名，例如 "container-registry"
-- @tparam number status 502 或 504
function _M.upstream_unavailable(service, status)
  return _M.abort(status, "upstream_unavailable",
    string.format("%s did not answer within the edge timeout", service))
end

--- identity-service 不可达且 JWKS 宽限期已过时的出口。
-- SPEC §1.2：宽限期内可以用缓存的 JWKS 离线验签，过期之后拒绝所有请求，
-- 凭据（非用户）调用则从一开始就直接拒。
function _M.identity_unavailable()
  return _M.abort(503, "identity_introspection_unavailable",
    "identity-service is unreachable and the cached JWKS is past OF_IDENTITY_JWKS_GRACE_SECONDS")
end

return _M
