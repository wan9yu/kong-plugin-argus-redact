local http = require "resty.http"
local codec = require "kong.plugins.argus-redact-bridge.json_codec"
local client = require "kong.plugins.argus-redact-bridge.client"

local kong = kong
local ngx = ngx

local Plugin = {
  PRIORITY = 1100, -- higher = earlier in access phase: runs before ai-proxy (799), after request-transformer-class plugins (900+)
  VERSION = "0.1.0",
}

local function fail(conf, status, msg)
  if conf.on_error == "open" then
    kong.log.warn("argus-redact-bridge fail-open: " .. msg)
    return  -- let request continue unmodified
  end
  return kong.response.exit(status, { error = msg })
end

local function merge_keys(keys)
  local merged = {}
  for _, k in ipairs(keys) do
    if type(k) == "table" then
      for placeholder, original in pairs(k) do
        merged[placeholder] = original
      end
    end
  end
  return merged
end

-- Restore PII in text using the key dict (fake -> original) from the redact
-- phase. This is a plain string substitution performed locally — no HTTP call
-- is needed, which matters because ngx.socket.tcp() is forbidden in the
-- body_filter phase.
local function restore_with_key(text, key)
  if not key or not text then
    return text
  end
  local result = text
  for fake, original in pairs(key) do
    -- Use plain replacement (no pattern magic) so phone numbers / names with
    -- special regex chars are handled safely.
    result = result:gsub(fake:gsub("([^%w])", "%%%1"), original)
  end
  return result
end

function Plugin:access(conf)
  local body, err = kong.request.get_raw_body()
  if not body then
    if err then
      return fail(conf, 502, "failed to read request body: " .. err)
    end
    return  -- truly empty body; nothing to redact
  end
  if body == "" then
    return  -- explicit empty; nothing to redact
  end

  local parsed, perr = codec.parse_request(body)
  if not parsed then
    -- not OpenAI-shape; let it through (not our problem)
    kong.log.debug("argus-redact-bridge: skipping non-OpenAI body: " .. perr)
    return
  end

  if parsed.is_stream then
    return kong.response.exit(400, {
      error = "argus-redact-bridge v0 does not support streaming. Set stream:false.",
    })
  end

  if #parsed.texts == 0 then
    return  -- no string content to redact
  end

  local httpc = http.new()
  local redacted_list, key_list = {}, {}
  for i, text in ipairs(parsed.texts) do
    local res, rerr = client.redact(httpc, conf, text)
    if not res then
      return fail(conf, 503, "argus-redact /redact failed at message " .. i .. ": " .. rerr)
    end
    redacted_list[i] = res.redacted
    key_list[i] = res.key
  end

  local new_body = codec.inject_request(parsed, redacted_list)
  kong.service.request.set_raw_body(new_body)
  kong.ctx.plugin.argus_key = merge_keys(key_list)
  kong.ctx.plugin.argus_active = true
end

-- Clear Content-Length so nginx uses chunked transfer after body_filter
-- replaces the body with a different-length restored payload.
function Plugin:header_filter(conf)
  if not kong.ctx.plugin.argus_active then
    return
  end
  kong.response.clear_header("Content-Length")
end

function Plugin:body_filter(conf)
  if not kong.ctx.plugin.argus_active then
    return
  end
  local ctx = kong.ctx.plugin
  local chunk, eof = ngx.arg[1], ngx.arg[2]
  ctx.argus_buffer = (ctx.argus_buffer or "") .. (chunk or "")

  if not eof then
    ngx.arg[1] = nil
    return
  end

  local full_body = ctx.argus_buffer
  local parsed = codec.parse_response(full_body)
  if not parsed or #parsed.texts == 0 then
    ngx.arg[1] = full_body
    ngx.arg[2] = true
    return
  end

  -- Restore each message text using the key built during access. This is a
  -- local string-substitution pass — no outbound HTTP call — which is
  -- required because ngx.socket.tcp() is not allowed in body_filter.
  local restored_list = {}
  for i, text in ipairs(parsed.texts) do
    restored_list[i] = restore_with_key(text, ctx.argus_key)
  end

  local new_body = codec.inject_response(parsed, restored_list)
  ngx.arg[1] = new_body
  ngx.arg[2] = true
end

return Plugin
