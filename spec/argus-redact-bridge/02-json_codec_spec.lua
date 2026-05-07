local codec = require "kong.plugins.argus-redact-bridge.json_codec"

describe("json_codec.parse_request", function()
  it("extracts every messages[].content string from a valid OpenAI Chat Completions request", function()
    local body = '{"model":"gpt-4","messages":[{"role":"user","content":"hi"},{"role":"system","content":"sys"}]}'
    local parsed, err = codec.parse_request(body)
    assert.is_nil(err)
    assert.equals(2, #parsed.texts)
    assert.equals("hi", parsed.texts[1])
    assert.equals("sys", parsed.texts[2])
    assert.is_table(parsed.json)
    assert.is_false(parsed.json.stream == true)
  end)

  it("flags requests where stream is true so the handler can short-circuit with 400", function()
    local body = '{"model":"gpt-4","stream":true,"messages":[{"role":"user","content":"x"}]}'
    local parsed, err = codec.parse_request(body)
    assert.is_nil(err)
    assert.is_true(parsed.is_stream)
  end)

  it("returns an error when the body is not valid JSON", function()
    local parsed, err = codec.parse_request("not json")
    assert.is_nil(parsed)
    assert.is_string(err)
  end)

  it("returns an error when the messages field is missing from the request", function()
    local parsed, err = codec.parse_request('{"model":"gpt-4"}')
    assert.is_nil(parsed)
    assert.matches("messages", err)
  end)

  it("skips messages whose content is a multimodal array instead of a plain string", function()
    local body = '{"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}'
    local parsed, err = codec.parse_request(body)
    assert.is_nil(err)
    assert.equals(0, #parsed.texts)
  end)
end)

describe("json_codec.inject_request", function()
  it("replaces each redacted text back into its original messages[] position", function()
    local body = '{"model":"gpt-4","messages":[{"role":"user","content":"hi"},{"role":"system","content":"sys"}]}'
    local parsed = codec.parse_request(body)
    local out = codec.inject_request(parsed, { "REDACTED1", "REDACTED2" })
    assert.matches('"content":"REDACTED1"', out)
    assert.matches('"content":"REDACTED2"', out)
  end)
end)

describe("json_codec.parse_response", function()
  it("extracts the content from each choice in an OpenAI Chat Completions response", function()
    local body = '{"choices":[{"message":{"role":"assistant","content":"hello"}},{"message":{"content":"world"}}]}'
    local parsed, err = codec.parse_response(body)
    assert.is_nil(err)
    assert.equals(2, #parsed.texts)
    assert.equals("hello", parsed.texts[1])
    assert.equals("world", parsed.texts[2])
  end)

  it("returns an empty texts list without error when the response has no choices field", function()
    local parsed, err = codec.parse_response('{"foo":"bar"}')
    assert.is_nil(err)
    assert.equals(0, #parsed.texts)
  end)
end)

describe("json_codec.inject_response", function()
  it("replaces each restored text back into its original choices[] position", function()
    local body = '{"choices":[{"message":{"content":"r"}}]}'
    local parsed = codec.parse_response(body)
    local out = codec.inject_response(parsed, { "RESTORED" })
    assert.matches('"content":"RESTORED"', out)
  end)
end)
