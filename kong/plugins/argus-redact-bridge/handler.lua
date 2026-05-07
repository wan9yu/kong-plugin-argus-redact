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

  local httpc = http.new()  -- separate from access-phase httpc; pool reuse handled by resty.http
  local restored_list = {}
  for i, text in ipairs(parsed.texts) do
    local res, err = client.restore(httpc, conf, text, ctx.argus_key)
    if not res then
      kong.log.err("argus-redact /restore failed at choice " .. i .. ": " .. err
        .. " — returning redacted (still safe) text to client")
      -- partial restore: return the fully-redacted body rather than a mix of
      -- restored and pseudonym text, which would be harder for callers to handle
      ngx.arg[1] = full_body
      ngx.arg[2] = true
      return
    end
    restored_list[i] = res.restored
  end

  local new_body = codec.inject_response(parsed, restored_list)
  ngx.arg[1] = new_body
  ngx.arg[2] = true
end

return Plugin
