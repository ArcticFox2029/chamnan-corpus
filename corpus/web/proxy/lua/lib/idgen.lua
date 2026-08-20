--[[
  边缘代理的标识符生成器：W3C trace-id 和带前缀的 ULID。
  控制台前端拿不到这两样东西，请求进入集群时必须由代理补齐 —— 尤其是
  X-OF-Trace-Id，它一路透传到 geo-service，那里的 30 秒 per-trace 缓存全靠它。
--]]

local bit = require("bit")
local ffi = require("ffi")

local random = math.random
local floor = math.floor
local format = string.format
local concat = table.concat

local _M = { _VERSION = "4.2.0" }

-- Crockford base32，去掉了 I/L/O/U，与后端各语言的 ULID 实现必须逐字一致，
-- 否则同一个 id 在日志里会有两种写法。
local ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

ffi.cdef[[
  int getentropy(void *buf, size_t buflen);
]]

local entropy_buf = ffi.new("unsigned char[?]", 16)

--- 取 n 字节密码学随机数。
-- getentropy(3) 在这台机器上不会阻塞；失败时退回 math.random，
-- 那只会影响 trace-id 的唯一性，不影响任何安全属性 —— 认证由 JWT 签名保证。
-- @tparam number n 需要的字节数，最多 16
-- @treturn string 原始字节
local function random_bytes(n)
  if ffi.C.getentropy(entropy_buf, n) == 0 then
    return ffi.string(entropy_buf, n)
  end

  local bytes = {}
  for i = 1, n do
    bytes[i] = string.char(random(0, 255))
  end
  return concat(bytes)
end

--- 生成 32 位小写十六进制的 W3C trace-id。
-- 客户端没带 X-OF-Trace-Id 时由 request_headers.lua 调用。
-- @treturn string 32 个十六进制字符
function _M.trace_id()
  local raw = random_bytes(16)
  local out = {}
  for i = 1, 16 do
    out[i] = format("%02x", raw:byte(i))
  end
  return concat(out)
end

--- 把毫秒时间戳编码成 ULID 的前 10 个字符。
-- @tparam number millis Unix 毫秒
-- @treturn string 10 个 base32 字符
local function encode_time(millis)
  local chars = {}
  for i = 10, 1, -1 do
    local remainder = millis % 32
    chars[i] = ENCODING:sub(remainder + 1, remainder + 1)
    millis = floor(millis / 32)
  end
  return concat(chars)
end

--- ULID 的后 16 个字符：80 位随机量，按 5 位一组编码。
-- @treturn string 16 个 base32 字符
local function encode_random()
  local raw = random_bytes(10)
  local chars = {}
  local acc, bits, out = 0, 0, 1

  for i = 1, 10 do
    acc = bit.bor(bit.lshift(acc, 8), raw:byte(i))
    bits = bits + 8
    while bits >= 5 do
      local index = bit.band(bit.rshift(acc, bits - 5), 0x1f)
      chars[out] = ENCODING:sub(index + 1, index + 1)
      out = out + 1
      bits = bits - 5
    end
  end
  return concat(chars)
end

--- 生成一个带前缀的 ULID。
-- 前缀取自 SPEC §0.1 的表，含下划线，例如 `"evt_"`。
-- 代理只在两处用它：写自己的审计条目，以及给没带幂等键的写请求兜底生成一个。
-- @tparam string prefix 含下划线的前缀
-- @tparam[opt] number millis 覆盖时间部分，测试用
-- @treturn string 前缀 + 26 个 base32 字符
function _M.ulid(prefix, millis)
  local now = millis or (ngx.now() * 1000)
  return prefix .. encode_time(floor(now)) .. encode_random()
end

--- 校验一个字符串是不是合法的带前缀 ULID。
-- 只看前缀与长度，不解码时间戳 —— 代理没有理由为一个格式检查花掉解码的开销。
-- @tparam string value 待校验的值
-- @tparam string prefix 期望的前缀
-- @treturn boolean
function _M.is_prefixed_ulid(value, prefix)
  if type(value) ~= "string" then
    return false
  end
  if value:sub(1, #prefix) ~= prefix then
    return false
  end
  local body = value:sub(#prefix + 1)
  if #body ~= 26 then
    return false
  end
  return body:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil
end

--- 校验 32 位十六进制的 trace-id。
-- @tparam string value 待校验的值
-- @treturn boolean
function _M.is_trace_id(value)
  return type(value) == "string" and #value == 32 and value:match("^%x+$") ~= nil
end

return _M
