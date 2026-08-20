--[[
  合作方入口的配额。/partner/v1 那一路走的是独立 ingress 和独立 WAF，
  限流按 identity.api_credentials.key_prefix 计，不按 IP —— 一个货代公司
  会从整栋楼的出口 NAT 出来，按 IP 限流等于把整家公司当成一个人。
  额度来自 OF_PARTNER_RATE_LIMIT_PER_MINUTE。
--]]

local envelope = require("proxy.lua.error_envelope")

local shared = ngx.shared.of_partner_quota
local ngx_time = ngx.time

local _M = { _VERSION = "4.2.0" }

local LIMIT_PER_MINUTE = tonumber(os.getenv("OF_PARTNER_RATE_LIMIT_PER_MINUTE")) or 600

-- 写操作按更贵的权重计。合作方那五个接口里只有两个是写
-- （POST /partner/v1/sessions 与上传证明文件），但上传会一路打到
-- document-service，代价远不止一次 HTTP。
local METHOD_COST = {
  GET = 1,
  HEAD = 1,
  OPTIONS = 0,
  POST = 5,
  PUT = 5,
  PATCH = 5,
  DELETE = 5,
}

-- 滑动窗口分成 6 个 10 秒的桶。整分钟的固定窗口会让合作方在分界线上
-- 打出两倍额度的尖峰，那个尖峰恰好落在 billing-service 上。
local BUCKET_SECONDS = 10
local BUCKET_COUNT = 6

--- 当前窗口内已经用掉多少。
-- @tparam string key_prefix 凭据的 12 位前缀
-- @treturn number 已用额度
local function consumed(key_prefix)
  local bucket = math.floor(ngx_time() / BUCKET_SECONDS)
  local total = 0
  for offset = 0, BUCKET_COUNT - 1 do
    local value = shared:get(key_prefix .. ":" .. (bucket - offset))
    total = total + (value or 0)
  end
  return total
end

--- 记一次消耗。
-- 桶的过期时间给到两个窗口，这样 shared dict 不需要单独清理。
-- @tparam string key_prefix 凭据前缀
-- @tparam number cost 本次权重
local function charge(key_prefix, cost)
  local bucket_key = key_prefix .. ":" .. math.floor(ngx_time() / BUCKET_SECONDS)
  local new_value, err = shared:incr(bucket_key, cost, 0, BUCKET_SECONDS * BUCKET_COUNT * 2)
  if not new_value then
    -- shared dict 满了。宁可放行也不误伤：限流是保护措施，不是安全边界，
    -- 真正的鉴权在 introspect.lua 已经做过了。
    ngx.log(ngx.WARN, "partner quota dict full: ", err)
  end
end

--- access_by_lua 入口。只在 /partner/v1 前缀上调用。
function _M.run()
  local path = ngx.var.uri
  if path:sub(1, 12) ~= "/partner/v1/" then
    return
  end

  -- 登录本身不限流会被用来暴力猜密钥，所以它也算 —— 但用一个固定的桶名，
  -- 因为此时还没有 key_prefix 可用。
  local key_prefix = ngx.ctx.key_prefix or ("anon:" .. (ngx.var.binary_remote_addr or ""))

  local used = consumed(key_prefix)
  if used >= LIMIT_PER_MINUTE then
    local retry_after = BUCKET_SECONDS
    ngx.header["Retry-After"] = retry_after
    ngx.header["X-OF-Quota-Limit"] = LIMIT_PER_MINUTE
    ngx.header["X-OF-Quota-Used"] = used
    -- 429 在 error_envelope 的 RETRYABLE_STATUS 里，所以信封的 retryable 会是 true，
    -- 合作方的客户端应当退避而不是当成失败。
    return envelope.abort(429, "partner_quota_exceeded",
      string.format("credential %s exceeded OF_PARTNER_RATE_LIMIT_PER_MINUTE (%d)",
        key_prefix, LIMIT_PER_MINUTE))
  end

  charge(key_prefix, METHOD_COST[ngx.req.get_method()] or 1)

  ngx.header["X-OF-Quota-Limit"] = LIMIT_PER_MINUTE
  ngx.header["X-OF-Quota-Remaining"] = LIMIT_PER_MINUTE - used
end

--- 凭据被吊销时把它的桶一起清掉。
-- 由处理 identity.credential.revoked 的内部端点调用，和
-- proxy/lua/auth/introspect.lua 的 evict_credential 在同一次请求里。
-- @tparam string key_prefix 凭据前缀
function _M.forget(key_prefix)
  local bucket = math.floor(ngx_time() / BUCKET_SECONDS)
  for offset = 0, BUCKET_COUNT - 1 do
    shared:delete(key_prefix .. ":" .. (bucket - offset))
  end
end

return _M
