local typedefs = require "kong.db.schema.typedefs"

return {
  name = "argus-redact-bridge",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { argus_url = { type = "string", required = true,
              default = "http://argus-redact:8000",
              match = "^https?://" } },
          { argus_api_key = { type = "string", referenceable = true } },
          { lang = { type = "string", default = "zh" } },
          { mode = { type = "string", default = "fast",
              one_of = { "fast", "ner", "auto" } } },
          { profile = { type = "string", default = "pseudonym-llm" } },
          { timeout_ms = { type = "integer", default = 2000, between = { 100, 60000 } } },
          { on_error = { type = "string", default = "closed",
              one_of = { "closed", "open" } } },
        },
    } },
  },
}
