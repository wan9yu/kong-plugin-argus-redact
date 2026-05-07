# kong-plugin-argus-redact

A Kong Gateway plugin that PII-redacts OpenAI-compatible Chat Completions traffic through [argus-redact](https://github.com/wan9yu/argus-redact). Real PII never reaches the upstream LLM, and the original PII is transparently restored on the response back to the client.

## Architecture

```
   ┌────────┐    POST /v1/chat/completions          ┌────────────────────────┐
   │ Client │ ─────────────────────────────────────▶│ Kong Gateway           │
   └────────┘    request body contains real PII     │  argus-redact-bridge   │
        ▲                                           │  (this plugin)         │
        │                                           └──────────┬─────────────┘
        │                                            access    │  POST /redact
        │                                            phase     │  one call per
        │                                                      ▼  messages[i]
        │                                           ┌──────────────────────┐
        │                                           │ argus-redact serve   │
        │                                           │  /redact endpoint    │
        │                                           └──────────┬───────────┘
        │                                                      │ returns
        │                                                      │ {redacted, key}
        │                                                      ▼
        │                                           ┌──────────────────────┐
        │                                           │ kong.ctx.plugin      │
        │                                           │  stash merged key    │
        │                                           └──────────┬───────────┘
        │                                                      │
        │           request body now contains                  ▼
        │           realistic pseudonymized values   ┌──────────────────────┐
        │           — never the real PII            ▶│ Upstream LLM         │
        │                                            │ (OpenAI / mock)      │
        │                                            └──────────┬───────────┘
        │                                                       │
        │                                            body_      ▼
        │                                            filter    ┌────────────────┐
        │                                            phase     │ local restore  │
        │                                                      │ via key dict   │
        │                                                      │ (gsub)         │
        │                                                      └────────┬───────┘
        │           response with original PII                          │
        └────────────────────────────────────────────────────────────────┘
```

**Request flow (access phase).** The plugin extracts each `messages[].content` string from the request body, calls `argus-redact serve` `/redact` once per message (v0.1 — see Limitations), replaces the content with the realistic-looking pseudonymized form (default profile `pseudonym-llm`), forwards the modified request upstream, and stashes the merged per-request `{placeholder → original}` key map in `kong.ctx.plugin`.

**Response flow (body_filter phase).** The plugin buffers the upstream response until EOF, parses each `choices[].message.content`, and restores the original PII via local string substitution against the key map. The substitution is performed in-process because OpenResty's `body_filter_by_lua` phase forbids cosocket creation, so an outbound HTTP `/restore` call is not possible from this phase.

## Quick start (Docker)

```bash
git clone https://github.com/wan9yu/kong-plugin-argus-redact
cd kong-plugin-argus-redact

# Bring up the demo stack: Kong Gateway + argus-redact + mock LLM
docker compose -f docker/docker-compose.yml up -d --build

# Send a request through Kong containing real PII (Chinese example here
# because argus-redact's strongest language pack is zh; the plugin is
# language-neutral and works the same way for en/ja/ko/de/uk/in/br).
curl -s -X POST http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4","messages":[
        {"role":"user","content":"我叫王五，手机13812345678"}
      ]}' | jq

# Client receives the original PII back, restored:
# {"choices":[{"message":{"content":"echo: 我叫王五，手机13812345678"}}]}

# What did the upstream LLM actually see? Pseudonymized data only:
docker compose -f docker/docker-compose.yml logs mock-llm | grep MOCK_LLM_REQUEST_BODY | tail -1
# MOCK_LLM_REQUEST_BODY: {"messages":[{"role":"user","content":"我叫傻大姐，手机19999173649"}], ...}
```

## Install (Kong Gateway + luarocks)

```bash
luarocks install argus-redact-bridge

# Tell Kong to load the plugin
export KONG_PLUGINS=bundled,argus-redact-bridge
```

Then enable the plugin on a Service or Route. DB-less example:

```yaml
# kong.yml
plugins:
  - name: argus-redact-bridge
    config:
      argus_url: http://argus-redact:8000
      argus_api_key: "{vault://env/ARGUS_API_KEY}"
      lang: zh
      mode: fast
      profile: pseudonym-llm
      on_error: closed
```

For production, run `argus-redact serve` with `ARGUS_API_KEY` set (drop the `--insecure` flag the demo stack uses), and reference the same key in the plugin config via Kong's vault syntax above. The demo `docker/docker-compose.yml` runs argus-redact with `--insecure` for self-contained reproducibility — that is not a recommended production configuration.

## Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `argus_url` | string (required) | `http://argus-redact:8000` | Base URL of the argus-redact HTTP server. |
| `argus_api_key` | string (referenceable) | — | Bearer token. Must match `ARGUS_API_KEY` on the argus-redact server. Use Kong vault references in production. |
| `lang` | string | `zh` | argus-redact language pack (`zh`, `en`, `ja`, `ko`, `de`, `uk`, `in`, `br`). |
| `mode` | enum | `fast` | argus-redact detection mode (`fast`, `ner`, `auto`). Only `fast` is suited to the request path; `ner` and `auto` are exposed for completeness but their latency profile makes them better suited to async / sidecar deployments than to inline gateway use. |
| `profile` | string | `pseudonym-llm` | argus-redact compliance profile. `pseudonym-llm` emits realistic-looking faked values that preserve LLM-reasoning quality. |
| `timeout_ms` | integer | `2000` | Per-call timeout for `/redact`. Bounded to `[100, 60000]`. |
| `on_error` | enum | `closed` | Behavior when argus-redact is unreachable during the access phase. `closed` (default): return 503; unredacted PII never reaches the LLM. `open`: log a warning and pass the original request through unmodified. |

## Known limitations (v0.1)

- **OpenAI Chat Completions JSON only.** The plugin assumes `{messages: [{role, content}], ...}` on the request and `{choices: [{message: {content}}], ...}` on the response. The Anthropic Messages API, Google Vertex, and other vendor shapes are not handled in v0.1.
- **No streaming.** Requests with `stream: true` are rejected with HTTP 400. argus-redact's streaming primitive requires complete logical units per chunk, while LLM SSE delivers token-level deltas where entities span chunk boundaries; correct streaming support is on the v1 roadmap.
- **One HTTP call per message.** v0.1 calls `/redact` once per `messages[].content`. A typical chat request has 1–5 messages and the calls run sequentially in the access phase, so the per-request latency overhead is roughly `N × (network RTT + argus-redact /redact latency)`. A batch endpoint on the argus-redact side is on the v1 wishlist to collapse that to a single call.
- **Single-form output.** The HTTP `/redact` endpoint returns one redacted text plus a key. argus-redact's Python `redact_pseudonym_llm()` API exposes three forms (`audit_text` / `downstream_text` / `display_text`) sharing one key; the gateway use case only needs the single form, so this is by design.
- **Local-only restore (no cross-language aliases).** Restore runs as a local string substitution against the key map returned by `/redact`. This is required because OpenResty's `body_filter_by_lua` phase forbids `ngx.socket.tcp()`, so the plugin cannot call `/restore` HTTP from the response path. Concretely: argus-redact's cross-language alias feature (e.g., the LLM rewrites Chinese `张三` as English `Zhang San` and `restore` recovers the alias via `result.aliases`) is **not** applied in v0.1. If the LLM produces a verbatim copy of the placeholder, restore works; if it transforms or translates the placeholder, the transformed form passes through unrestored. v1 will explore `ngx.timer.at` to schedule the `/restore` call out of the body_filter phase.

## Approach

Most PII handling at the API gateway today falls into one of three patterns:

1. **Block-and-reject** — detect sensitive content and refuse the request. Strong on privacy guarantee, no usability for the legitimate cases the regex flags.
2. **Detect-and-strip** — replace PII with placeholders before the upstream call, do not restore. Usable, but the client sees pseudonyms and has to map them back manually.
3. **Reversible redact-and-restore** — replace PII with realistic pseudonyms before the upstream call, restore the original PII on the response so the client sees a normal message. This is the pattern `argus-redact-bridge` implements.

The reversible pattern is what makes a hosted LLM useful in PII-heavy workflows (customer-support chat, medical intake, identity verification): the upstream model never sees raw PII, and the human caller never has to decode pseudonyms. See [`benchmarks/prvl/`](benchmarks/prvl/README.md) for the methodology used to measure each pattern's privacy/reversibility/language coverage.

## Performance

End-to-end latency, measured against the demo stack (`docker compose up` → curl Kong with a 25-character Chinese PII payload, `mode=fast`, single user message). Numbers are illustrative — they include the full plugin path (request body parse, `POST /redact` HTTP round-trip to the local argus-redact sidecar, body inject, upstream call, response body buffer, local restore via key dict) and will vary with payload size, message count, network distance to the argus-redact sidecar, and host hardware.

| Metric | Value (host: Apple M1 Max, Docker Desktop / N=100) |
|---|---|
| p50 latency | 6.6 ms |
| p95 latency | 10.8 ms |
| p99 latency | 17.0 ms |
| throughput  | 42.4 req/s |

Reproduce with `bash scripts/bench.sh` after `docker compose -f docker/docker-compose.yml up -d --build`.

The plugin layers HTTP round-trips and JSON re-parsing on top of argus-redact's detection engine. Any single-millisecond latency claim from the underlying detection engine does not translate to plugin-level performance — measure end-to-end before quoting numbers.

## Status

v0.1 — minimum viable. APIs may change. Not yet published to luarocks.org.

## License

[Apache 2.0](LICENSE)
