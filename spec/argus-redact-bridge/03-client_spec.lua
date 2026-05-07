local client = require "kong.plugins.argus-redact-bridge.client"

local function make_stub(responses)
  local calls = {}
  local stub = {
    set_timeout = function(self, ms) self._timeout = ms end,
    request_uri = function(self, url, opts)
      table.insert(calls, { url = url, opts = opts, timeout = self._timeout })
      local r = table.remove(responses, 1)
      if r.err then return nil, r.err end
      return { status = r.status, body = r.body }, nil
    end,
  }
  return stub, calls
end

describe("client.redact", function()
  it("posts the request body as JSON with bearer auth and returns redacted text plus key on a 200 response", function()
    local stub, calls = make_stub({
      { status = 200, body = '{"redacted":"X","key":{"X":"original"}}' },
    })
    local conf = {
      argus_url = "http://argus:8000",
      argus_api_key = "secret",
      lang = "zh",
      mode = "fast",
      profile = "pseudonym-llm",
      timeout_ms = 1500,
    }
    local res, err = client.redact(stub, conf, "hello PII")
    assert.is_nil(err)
    assert.equals("X", res.redacted)
    assert.same({ X = "original" }, res.key)
    assert.equals(1, #calls)
    assert.equals("http://argus:8000/redact", calls[1].url)
    assert.equals("POST", calls[1].opts.method)
    assert.equals("Bearer secret", calls[1].opts.headers["Authorization"])
    assert.equals("application/json", calls[1].opts.headers["Content-Type"])
    assert.equals(1500, calls[1].timeout)
    local cjson = require "cjson.safe"
    local sent = cjson.decode(calls[1].opts.body)
    assert.equals("hello PII", sent.text)
    assert.equals("zh", sent.lang)
    assert.equals("fast", sent.mode)
    assert.equals("pseudonym-llm", sent.profile)
  end)

  it("returns an error string mentioning the status code when argus-redact responds with non-200", function()
    local stub = make_stub({ { status = 401, body = '{"error":"unauth"}' } })
    local conf = { argus_url = "http://x", argus_api_key = "" }
    local res, err = client.redact(stub, conf, "t")
    assert.is_nil(res)
    assert.matches("401", err)
  end)

  it("returns an error string mentioning the transport failure when the HTTP layer fails", function()
    local stub = make_stub({ { err = "connection refused" } })
    local conf = { argus_url = "http://x" }
    local res, err = client.redact(stub, conf, "t")
    assert.is_nil(res)
    assert.matches("connection refused", err)
  end)

  it("omits the Authorization header when argus_api_key is empty so the server can opt-in to no-auth mode", function()
    local stub, calls = make_stub({ { status = 200, body = '{"redacted":"x","key":{}}' } })
    local conf = { argus_url = "http://x", argus_api_key = "" }
    client.redact(stub, conf, "t")
    assert.is_nil(calls[1].opts.headers["Authorization"])
  end)
end)

describe("client.restore", function()
  it("posts the redacted text plus key dict and returns the restored original text on a 200 response", function()
    local stub, calls = make_stub({
      { status = 200, body = '{"restored":"original PII"}' },
    })
    local conf = { argus_url = "http://x", argus_api_key = "k", timeout_ms = 1000 }
    local res, err = client.restore(stub, conf, "Y", { Y = "original PII" })
    assert.is_nil(err)
    assert.equals("original PII", res.restored)
    assert.equals("http://x/restore", calls[1].url)
    local cjson = require "cjson.safe"
    local sent = cjson.decode(calls[1].opts.body)
    assert.equals("Y", sent.text)
    assert.same({ Y = "original PII" }, sent.key)
  end)
end)
