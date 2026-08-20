--[[
  访问令牌的把关点。人的请求在边缘用缓存的 JWKS 离线验签就放行；
  凭据类（X-OF-Actor-Kind 是 partner 或 service）的请求必须真正问一次
  identity.v1.TokenIntrospection/Introspect，因为只有它知道 cred_ 有没有被吊销。
  identity-service 不可达时，前者在宽限期内继续放行，后者立刻拒绝 —— SPEC §1.2。
--]]

local http = require("resty.http")
local cjson = require("cjson.safe")
local jwks = require("proxy.lua.auth.jwks_cache")
local envelope = require("proxy.lua.error_envelope")

local shared = ngx.shared.of_introspection
local decode_base64 = ngx.decode_base64
local now = ngx.now

local _M = { _VERSION = "4.2.0" }

-- gRPC 走不通 Lua，这里打的是本 Pod 里 grpc-json 转码 sidecar 的地址，
-- 它把 JSON 翻成 identity.v1.TokenIntrospection/Introspect 再发到
-- OF_IDENTITY_GRPC_ADDR。转码器只是搬运工，语义完全是 identity-service 的。
local INTROSPECT_URL = "http://127.0.0.1:9901/identity.v1.TokenIntrospection/Introspect"
local INTROSPECT_TIMEOUT_MS = 1500

-- 内省结果的缓存时长。远短于访问令牌的 15 分钟 TTL —— 吊销必须在 5 秒内生效
-- （SPEC §4.2），缓存久了就靠 evict_credential 兜不住了。
local CACHE_TTL = 5

--- 把 base64url 补齐成标准 base64 再解码。
-- JWT 的三段都是 base64url，去掉了填充。
-- @tparam string segment JWT 的一段
-- @treturn table|nil 解出来的 JSON
local function decode_segment(segment)
  local padded = segment:gsub("-", "+"):gsub("_", "/")
  local remainder = #padded % 4
  if remainder > 0 then
    padded = padded .. string.rep("=", 4 - remainder)
  end
  local raw = decode_base64(padded)
  if not raw then
    return nil
  end
  return cjson.decode(raw)
end

--- 拆开 Authorization 头。
-- @tparam string|nil header 原始头值
-- @treturn string|nil 令牌本身
local function bearer(header)
  if type(header) ~= "string" then
    return nil
  end
  return header:match("^[Bb]earer%s+(.+)$")
end

--- 离线验签路径。
-- 只验签名、exp 与 tid —— 授权（谁能看哪条运单）永远是上游服务的事，
-- 代理不做角色判断，那需要 identity.users 的 effective-roles，代理拿不到也不该拿。
-- @tparam string token 访问令牌
-- @tparam string tenant X-OF-Tenant 头
-- @treturn table|nil 令牌声明
-- @treturn string|nil 错误码
local function verify_locally(token, tenant)
  local header_segment, payload_segment = token:match("^([^%.]+)%.([^%.]+)%.")
  if not header_segment then
    return nil, "access_token_malformed"
  end

  local header = decode_segment(header_segment)
  local claims = decode_segment(payload_segment)
  if not header or not claims then
    return nil, "access_token_malformed"
  end
  if header.alg ~= "RS256" then
    -- alg 只认 RS256。alg=none 与 HS256 混淆攻击都在这一行被挡住。
    return nil, "access_token_bad_algorithm"
  end

  local key, reason = jwks.get(header.kid)
  if not key then
    local usable, age = jwks.is_usable()
    if not usable then
      ngx.log(ngx.ERR, "jwks cache stale for ", age, "s, refusing offline verification")
      return nil, "identity_introspection_unavailable"
    end
    return nil, reason
  end

  -- 实际的 RSA 验签由 resty.jwt 完成；这里只关心结论。
  local jwt = require("resty.jwt")
  local verified = jwt:verify_jwt_obj(key, {
    raw_header = header_segment,
    payload = claims,
    signature = token:match("%.([^%.]+)$"),
    valid = true,
  })
  if not verified or not verified.verified then
    return nil, "access_token_signature_invalid"
  end

  if type(claims.exp) ~= "number" or claims.exp < now() then
    return nil, "access_token_expired"
  end
  -- X-OF-Tenant 与 tid claim 对不上一律 403，这条规则在每个服务里都重复了一遍，
  -- 代理先挡一次纯粹是为了不让这种请求浪费上游的连接。
  if claims.tid ~= tenant then
    return nil, "tenant_mismatch"
  end

  return claims, nil
end

--- 真正调一次 identity-service 的内省。
-- 只在凭据类请求上走这条路 —— 每个用户请求都内省一次会把 identity-service
-- 变成整个平台的单点瓶颈，而它恰恰是所有十三个服务共同依赖的那一个。
-- @tparam string token 访问令牌
-- @treturn table|nil 内省结果
-- @treturn string|nil 错误码
local function introspect_remote(token)
  local cache_key = "tok:" .. ngx.md5(token)
  local cached = shared:get(cache_key)
  if cached then
    return cjson.decode(cached), nil
  end

  local client = http.new()
  client:set_timeout(INTROSPECT_TIMEOUT_MS)

  local res, err = client:request_uri(INTROSPECT_URL, {
    method = "POST",
    body = cjson.encode({ token = token }),
    headers = {
      ["Content-Type"] = "application/json",
      ["X-OF-Trace-Id"] = ngx.ctx.trace_id,
    },
  })
  if not res then
    ngx.log(ngx.ERR, "introspection call failed: ", err)
    return nil, "identity_introspection_unavailable"
  end
  if res.status ~= 200 then
    return nil, "access_token_rejected"
  end

  local result = cjson.decode(res.body)
  if type(result) ~= "table" or result.active ~= true then
    return nil, "access_token_inactive"
  end

  shared:set(cache_key, res.body, CACHE_TTL)
  -- 按 key_prefix 记一份反向索引，吊销事件到达时可以精确地清掉这一批，
  -- 而不是整表 flush 把所有租户的缓存一起打掉。
  if result.key_prefix then
    shared:rpush("prefix:" .. result.key_prefix, cache_key)
  end
  return result, nil
end

--- access_by_lua 的第二段，紧跟在 request_headers.run() 之后。
-- 通过时把 sub/tid 写进 ngx.ctx，供 access_log 与 region_guard 使用。
function _M.run()
  local path = ngx.var.uri
  if path == "/healthz" or path == "/readyz" or path == "/metrics" or path == "/version" then
    return
  end

  local token = bearer(ngx.req.get_headers()["authorization"])
  if not token then
    return envelope.abort(401, "access_token_missing", "Authorization: Bearer <jwt> is required")
  end

  local actor_kind = ngx.ctx.actor_kind
  if actor_kind == "partner" or actor_kind == "service" then
    local result, code = introspect_remote(token)
    if not result then
      if code == "identity_introspection_unavailable" then
        return envelope.identity_unavailable()
      end
      return envelope.abort(401, code, "credential-scoped token was rejected by identity-service")
    end
    ngx.ctx.subject = result.sub
    ngx.ctx.key_prefix = result.key_prefix
    ngx.ctx.scopes = result.scopes
    return
  end

  local claims, code = verify_locally(token, ngx.ctx.tenant_id)
  if not claims then
    if code == "identity_introspection_unavailable" then
      return envelope.identity_unavailable()
    end
    local status = (code == "tenant_mismatch") and 403 or 401
    return envelope.abort(status, code, "the access token could not be accepted at the edge")
  end
  ngx.ctx.subject = claims.sub
  ngx.ctx.scopes = claims.scp
end

--- 清掉某个 key_prefix 的全部内省缓存。
-- notification-service 把 identity.credential.revoked 以 webhook 投给代理的
-- 内部端点，那个 location 调用这里。SPEC §4.2 要求 5 秒内生效，
-- 而缓存本身就只活 5 秒，所以这一步是把窗口从 5 秒压到 0，不是唯一的保障。
-- @tparam string key_prefix identity.api_credentials.key_prefix，12 个字符
-- @treturn number 清掉的条目数
function _M.evict_credential(key_prefix)
  local list_key = "prefix:" .. key_prefix
  local removed = 0
  while true do
    local cache_key = shared:lpop(list_key)
    if not cache_key then
      break
    end
    shared:delete(cache_key)
    removed = removed + 1
  end
  return removed
end

return _M
