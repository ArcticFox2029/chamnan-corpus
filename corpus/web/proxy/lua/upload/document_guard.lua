--[[
  文档上传的前置检查。控制台的上传直接打到 document-service 的
  POST /v1/documents，代理在转发之前先按 OF_DOCUMENT_MAX_UPLOAD_BYTES 与
  OF_DOCUMENT_ALLOWED_MIME_TYPES 挡一遍，并校验 owner_type 属于
  platform.document_owner_types 的六个值 —— 让一个 200MB 的错误类型上传
  跑完整条链路再被拒，白白占住一个上游连接三十秒。
--]]

local cjson = require("cjson.safe")
local envelope = require("proxy.lua.error_envelope")

local _M = { _VERSION = "4.2.0" }

local MAX_BYTES = tonumber(os.getenv("OF_DOCUMENT_MAX_UPLOAD_BYTES")) or (64 * 1024 * 1024)

-- platform.document_owner_types 的六行。document-service 自己也会校验一遍，
-- 这里重复是为了省掉一次往返，不是为了替它做主。
local OWNER_TYPES = {
  shipment = "container-registry",
  container = "container-registry",
  scan = "container-registry",
  declaration = "customs-service",
  invoice = "billing-service",
  carrier = "fleet-service",
}

-- 每种 owner_type 常见的 kind。不匹配不拒绝，只在日志里记一笔 ——
-- 承运人保险单挂在 carrier 上是常态，但海关判决书挂在 carrier 上多半是操作失误，
-- 而判断「多半」不该由代理来做。
local TYPICAL_KINDS = {
  shipment = { bill_of_lading = true, packing_list = true, proof_of_delivery = true },
  container = { damage_photo = true },
  scan = { proof_of_delivery = true, damage_photo = true },
  declaration = { commercial_invoice = true, certificate_of_origin = true, customs_decision = true },
  invoice = { rendered_invoice = true, credit_note = true },
  carrier = { insurance_certificate = true },
}

--- 解析 OF_DOCUMENT_ALLOWED_MIME_TYPES。
-- 逗号分隔，空白无所谓；空值表示不限制，只有本地开发会这样配。
-- @treturn table|nil MIME → true
local function allowed_mime_types()
  local raw = os.getenv("OF_DOCUMENT_ALLOWED_MIME_TYPES")
  if not raw or raw == "" then
    return nil
  end
  local set = {}
  for item in raw:gmatch("[^,]+") do
    set[item:gsub("^%s*(.-)%s*$", "%1")] = true
  end
  return set
end

local ALLOWED_MIME = allowed_mime_types()

--- 从 multipart 请求头里取一段字段值。
-- 只读请求头与前几百字节的 preamble，不缓冲整个请求体 ——
-- 缓冲一份 64MB 的 PDF 只为了看一眼 owner_type，代价完全不成比例。
-- @tparam string name 字段名
-- @treturn string|nil 字段值
local function query_or_header(name)
  local args = ngx.req.get_uri_args()
  if args[name] then
    return args[name]
  end
  return ngx.req.get_headers()["x-of-" .. name:gsub("_", "-")]
end

--- access_by_lua 入口，只挂在 POST /v1/documents 这一个 location 上。
function _M.run()
  if ngx.var.uri ~= "/v1/documents" or ngx.req.get_method() ~= "POST" then
    return
  end

  local declared_length = tonumber(ngx.var.http_content_length)
  if declared_length and declared_length > MAX_BYTES then
    -- 413 不在可重试列表里：同一个文件再传一次结果一样。
    return envelope.abort(413, "document_too_large",
      string.format("upload of %d bytes exceeds OF_DOCUMENT_MAX_UPLOAD_BYTES (%d)",
        declared_length, MAX_BYTES), {
        { path = "file", reason = "too_large" },
      })
  end

  local owner_type = query_or_header("owner_type")
  if owner_type and not OWNER_TYPES[owner_type] then
    return envelope.abort(400, "document_owner_type_unknown",
      string.format("%s is not a row in platform.document_owner_types", owner_type), {
        { path = "owner_type", reason = "not_in_vocabulary" },
      })
  end

  local kind = query_or_header("kind")
  if owner_type and kind and TYPICAL_KINDS[owner_type]
      and not TYPICAL_KINDS[owner_type][kind] then
    ngx.log(ngx.INFO, "unusual document pairing: owner_type=", owner_type,
      " kind=", kind, " trace=", ngx.ctx.trace_id or "-")
  end

  local content_type = ngx.var.http_content_type or ""
  -- multipart 的 Content-Type 是外层容器类型，真正的文件类型在各分段里，
  -- 只有当调用方额外声明了 X-OF-Mime-Type 时才能在这里判。
  local declared_mime = ngx.req.get_headers()["x-of-mime-type"]
  if ALLOWED_MIME and declared_mime and not ALLOWED_MIME[declared_mime] then
    return envelope.abort(415, "document_mime_type_not_allowed",
      string.format("%s is not in OF_DOCUMENT_ALLOWED_MIME_TYPES", declared_mime), {
        { path = "mime_type", reason = "not_allowed" },
      })
  end
  if not content_type:find("^multipart/form%-data") then
    return envelope.abort(415, "document_upload_not_multipart",
      "POST /v1/documents expects multipart/form-data")
  end

  -- 上传不重试。请求体是一次性的流，proxy_next_upstream 重放会把半截文件
  -- 发给第二个 Pod。document-service 那边靠 documents.sha256 去重
  -- （SPEC §1.2 Diamond B），所以偶尔的重复上传不会变成两份 blob，
  -- 但半截文件会变成一条坏记录。
  ngx.var.of_proxy_next_upstream = "off";
  ngx.ctx.upload_owner_type = owner_type
  ngx.ctx.upload_owner_service = owner_type and OWNER_TYPES[owner_type] or nil
end

--- 上传成功之后记一条结构化日志。
-- document-service 会发 document.uploaded 事件，代理不重复发 ——
-- 只有服务能在自己的事务里写 platform.outbox_messages（SPEC §7 规则 3）。
-- @tparam string body document-service 的响应体
function _M.log_result(body)
  if ngx.status ~= 201 and ngx.status ~= 200 then
    return
  end
  local decoded = cjson.decode(body)
  if type(decoded) ~= "table" or not decoded.document_id then
    return
  end
  ngx.log(ngx.INFO, "document stored id=", decoded.document_id,
    " owner=", ngx.ctx.upload_owner_type or "?",
    " owner_service=", ngx.ctx.upload_owner_service or "?",
    " bytes=", decoded.byte_size or 0,
    " trace=", ngx.ctx.trace_id or "-")
end

return _M
