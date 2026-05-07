-- Structural assertions on the schema declaration. We don't run Kong's
-- validator here (that lives only in Kong's source tree); we verify that
-- the schema declares what we say it declares. Kong-validator integration
-- is exercised by the docker-compose E2E test.

local schema = require "kong.plugins.argus-redact-bridge.schema"

local function find_field(name)
  for _, top in ipairs(schema.fields) do
    local _, top_def = next(top)
    if top_def and top_def.type == "record" and top_def.fields then
      for _, f in ipairs(top_def.fields) do
        local k, v = next(f)
        if k == name then return v end
      end
    end
  end
  return nil
end

describe("argus-redact-bridge schema", function()
  it("declares the plugin name as argus-redact-bridge", function()
    assert.equals("argus-redact-bridge", schema.name)
  end)

  it("requires argus_url and gives it a sensible http(s) default", function()
    local f = find_field("argus_url")
    assert.is_table(f)
    assert.is_true(f.required)
    assert.matches("^https?://", f.default)
  end)

  it("marks argus_api_key as referenceable so vault references resolve at runtime", function()
    local f = find_field("argus_api_key")
    assert.is_table(f)
    assert.is_true(f.referenceable)
  end)

  it("constrains mode to fast, ner, or auto with fast as the default for inline use", function()
    local f = find_field("mode")
    assert.is_table(f)
    assert.same({ "fast", "ner", "auto" }, f.one_of)
    assert.equals("fast", f.default)
  end)

  it("constrains on_error to closed or open with closed as the safe default", function()
    local f = find_field("on_error")
    assert.is_table(f)
    assert.same({ "closed", "open" }, f.one_of)
    assert.equals("closed", f.default)
  end)

  it("defaults lang to zh, profile to pseudonym-llm, and timeout_ms to 2000", function()
    assert.equals("zh", find_field("lang").default)
    assert.equals("pseudonym-llm", find_field("profile").default)
    assert.equals(2000, find_field("timeout_ms").default)
  end)

  it("constrains timeout_ms to a sane range so misconfigured values cannot stall a request indefinitely", function()
    local f = find_field("timeout_ms")
    assert.is_table(f.between)
    assert.equals(100, f.between[1])
    assert.equals(60000, f.between[2])
  end)
end)
