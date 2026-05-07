local cjson = require "cjson.safe"

local _M = {}

local function call(httpc, conf, path, payload)
  httpc:set_timeout(conf.timeout_ms or 2000)
  local headers = { ["Content-Type"] = "application/json" }
  if conf.argus_api_key and conf.argus_api_key ~= "" then
    headers["Authorization"] = "Bearer " .. conf.argus_api_key
  end
  local res, err = httpc:request_uri(conf.argus_url .. path, {
    method = "POST",
    body = cjson.encode(payload),
    headers = headers,
  })
  if not res then
    return nil, "argus-redact transport error: " .. tostring(err)
  end
  if res.status ~= 200 then
    return nil, "argus-redact returned " .. tostring(res.status) .. ": " .. tostring(res.body)
  end
  local body, derr = cjson.decode(res.body)
  if not body then
    return nil, "argus-redact returned non-JSON: " .. tostring(derr)
  end
  return body
end

function _M.redact(httpc, conf, text)
  return call(httpc, conf, "/redact", {
    text = text,
    lang = conf.lang,
    mode = conf.mode,
    profile = conf.profile,
  })
end

function _M.restore(httpc, conf, text, key)
  return call(httpc, conf, "/restore", {
    text = text,
    key = key,
  })
end

return _M
