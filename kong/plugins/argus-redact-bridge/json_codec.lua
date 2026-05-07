local cjson = require "cjson.safe"

local _M = {}

local function decode(body)
  if type(body) ~= "string" or #body == 0 then
    return nil, "empty body"
  end
  local ok, decoded = pcall(cjson.decode, body)
  if not ok or decoded == nil then
    return nil, "invalid JSON"
  end
  return decoded
end

function _M.parse_request(body)
  local json, err = decode(body)
  if not json then return nil, err end
  if type(json.messages) ~= "table" then
    return nil, "messages field missing or not an array"
  end
  local texts, indices = {}, {}
  for i, msg in ipairs(json.messages) do
    if type(msg) == "table" and type(msg.content) == "string" then
      table.insert(texts, msg.content)
      table.insert(indices, i)
    end
  end
  return {
    json = json,
    texts = texts,
    indices = indices,
    is_stream = json.stream == true,
  }
end

function _M.inject_request(parsed, redacted_texts)
  for k, idx in ipairs(parsed.indices) do
    parsed.json.messages[idx].content = redacted_texts[k]
  end
  return cjson.encode(parsed.json)
end

function _M.parse_response(body)
  local json, err = decode(body)
  if not json then return nil, err end
  local texts, indices = {}, {}
  if type(json.choices) == "table" then
    for i, choice in ipairs(json.choices) do
      if type(choice) == "table"
        and type(choice.message) == "table"
        and type(choice.message.content) == "string" then
        table.insert(texts, choice.message.content)
        table.insert(indices, i)
      end
    end
  end
  return {
    json = json,
    texts = texts,
    indices = indices,
  }
end

function _M.inject_response(parsed, restored_texts)
  for k, idx in ipairs(parsed.indices) do
    parsed.json.choices[idx].message.content = restored_texts[k]
  end
  return cjson.encode(parsed.json)
end

return _M
