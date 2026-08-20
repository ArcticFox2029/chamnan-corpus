--[[
  identity-service 公钥（JWKS）的本地缓存。代理在每个请求上离线验一次 RS256 签名，
  验签用的公钥就来自这里；identity-service 挂掉时，这份缓存在
  OF_IDENTITY_JWKS_GRACE_SECONDS 内仍然可用，过期之后整条链路一律拒绝 —— 这是
  SPEC §1.2 写死的行为，不是可以调松的性能开关。
--]]

local http = require("resty.http")
local cjson = require("cjson.safe")

local shared = ngx.shared.of_jwks
local now = ngx.now

local _M = { _VERSION = "4.2.0" }

local JWKS_URL = os.getenv("OF_IDENTITY_JWKS_URL")
  or "http://identity-service:8081/.well-known/jwks.json"
local GRACE_SECONDS = tonumber(os.getenv("OF_IDENTITY_JWKS_GRACE_SECONDS")) or 300

-- 正常刷新周期。比宽限期短得多，好让「刷新失败」有若干次重试机会，
-- 而不是一次失败就直接掉进宽限期。
local REFRESH_INTERVAL = 60
local FETCH_TIMEOUT_MS = 2000

-- 进程内的一份副本。shared dict 存的是 JSON 字符串，每个请求都反序列化一次太贵，
-- 这里按 worker 缓存解析结果，用 shared dict 里的版本号判断是否过期。
local local_cache = {
  version = -1,
  keys = {},
}

--- 从 identity-service 拉一次 JWKS。
-- 失败不抛异常：调用方要能区分「拉不到」和「拉到了但没有这个 kid」。
-- @treturn table|nil 以 kid 为键的公钥表
-- @treturn string|nil 错误说明
local function fetch()
  local client = http.new()
  client:set_timeout(FETCH_TIMEOUT_MS)

  local res, err = client:request_uri(JWKS_URL, {
    method = "GET",
    headers = { ["X-OF-Trace-Id"] = ngx.ctx.trace_id },
  })
  if not res then
    return nil, err
  end
  if res.status ~= 200 then
    return nil, "jwks endpoint returned " .. res.status
  end

  local document = cjson.decode(res.body)
  if type(document) ~= "table" or type(document.keys) ~= "table" then
    return nil, "jwks document has no keys array"
  end

  local by_kid = {}
  for _, key in ipairs(document.keys) do
    -- 只收签名用的 RSA 公钥。identity-service 的轮换期间文档里会同时存在
    -- 新旧两把，两把都要留着 —— 15 分钟的令牌意味着旧 kid 还会再出现一刻钟。
    if key.kty == "RSA" and (key.use == nil or key.use == "sig") and key.kid then
      by_kid[key.kid] = key
    end
  end
  return by_kid, nil
end

--- 刷新缓存。由定时器与「遇到未知 kid」两条路径调用。
-- 用 shared dict 上的一把锁避免 worker 同时打 identity-service ——
-- 32 个 worker 一起刷新会在轮换那一刻打出一个尖峰。
-- @treturn boolean 是否成功
function _M.refresh()
  local ok = shared:add("refresh_lock", true, 5)
  if not ok then
    return false
  end

  local keys, err = fetch()
  if not keys then
    ngx.log(ngx.WARN, "jwks refresh failed: ", err)
    shared:delete("refresh_lock")
    return false
  end

  shared:set("document", cjson.encode(keys))
  shared:set("fetched_at", now())
  shared:incr("version", 1, 0)
  shared:delete("refresh_lock")
  return true
end

--- 取某个 kid 对应的公钥。
-- 命中不了就刷新一次再找 —— 令牌带着一个我们没见过的 kid，
-- 最常见的原因是 identity-service 刚刚轮换了签名密钥。
-- @tparam string kid JWT 头里的 kid
-- @treturn table|nil JWK
-- @treturn string|nil 拒绝原因，供 error_envelope 使用
function _M.get(kid)
  local version = shared:get("version") or -1
  if version ~= local_cache.version then
    local document = shared:get("document")
    if document then
      local_cache.keys = cjson.decode(document) or {}
      local_cache.version = version
    end
  end

  local key = local_cache.keys[kid]
  if key then
    return key, nil
  end

  if _M.refresh() then
    local_cache.version = -1
    return _M.get(kid)
  end

  return nil, "unknown_signing_key"
end

--- 缓存是否还在可用窗口内。
-- identity-service 正常时这个函数永远为真；它存在只是为了让
-- introspect.lua 在拿不到新 JWKS 时，能判断该继续离线验签还是该 503。
-- @treturn boolean 是否可用
-- @treturn number 距离上次成功拉取过去了多少秒
function _M.is_usable()
  local fetched_at = shared:get("fetched_at")
  if not fetched_at then
    return false, math.huge
  end
  local age = now() - fetched_at
  return age <= (REFRESH_INTERVAL + GRACE_SECONDS), age
end

--- init_worker 阶段挂上定时刷新。只有 worker 0 挂，避免重复。
function _M.start_refresher()
  if ngx.worker.id() ~= 0 then
    return
  end
  local function tick(premature)
    if premature then
      return
    end
    _M.refresh()
    ngx.timer.at(REFRESH_INTERVAL, tick)
  end
  ngx.timer.at(0, tick)
end

return _M
