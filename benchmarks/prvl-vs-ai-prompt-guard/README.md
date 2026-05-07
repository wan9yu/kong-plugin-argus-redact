# PRvL benchmark -- argus-redact-bridge vs Kong ai-prompt-guard

**Status:** scaffold + methodology. No numbers committed yet -- see `run.sh` to execute.

## What we measure (PRvL = Privacy x Reversibility x Language)

| Dimension | argus-redact-bridge | ai-prompt-guard |
|---|---|---|
| **Privacy** -- does real PII reach the upstream LLM? | Expected: never (fail-closed if redact fails). Measured by: log capture on mock LLM | ai-prompt-guard *blocks* matching requests rather than redacting them. We measure: (a) blocked ratio, (b) leak ratio for unmatched requests |
| **Reversibility** -- does the client see original PII back? | Expected: yes via local key substitution after `/redact` | Not supported. Score 0 by design |
| **Language** -- coverage across zh/en/ja/ko/de/uk/in/br | argus-redact: 8 languages | ai-prompt-guard: regex-list, depends on user-supplied patterns |

The benchmark is therefore intentionally one-sided on R, meant to surface the architectural gap rather than score one as winner on a single number. The summary should read: *"ai-prompt-guard is a block list, argus-redact-bridge is a reversible redactor -- different products, this benchmark documents the gap."*

## Test corpus

`payloads.jsonl` -- one JSON object per line:

```json
{"id": "zh-001", "lang": "zh", "text": "我叫王五，手机13812345678", "expected_pii": ["王五", "13812345678"]}
{"id": "en-001", "lang": "en", "text": "Hi, I'm John Doe, SSN 123-45-6789", "expected_pii": ["John Doe", "123-45-6789"]}
```

Cases are drawn from argus-redact's reference test suites and curated public PII datasets. The scaffold ships 5 cases as a starting point; expand to ~50 cases per language before publishing numbers. **Do not use real PII.** All values are synthetic but format-valid (Luhn, MOD11-2, etc.).

## Methodology

For each payload, run twice:

1. **argus-redact-bridge stack** -- docker-compose with `argus-redact-bridge` enabled, point-test against `localhost:18000`.
2. **ai-prompt-guard stack** -- same Kong, swap the plugin block in `kong.yml` to `ai-prompt-guard` with a regex matching the same PII categories.

Capture per request:
- Upstream-received body (from mock-llm log)
- Client-received response
- Plugin-emitted error (if any)

Score per case:
- **P** (privacy): `1.0` if no expected_pii substring appeared in the upstream-received body, else `0.0`
- **R** (reversibility): `1.0` if every `expected_pii` substring appeared in the client response, else `0.0`. ai-prompt-guard structurally scores 0 (no restore).
- **L** (language): aggregate P x R per language bucket.

`judge.py` handles scoring; `run.sh` orchestrates.

## Output

`results/argus/scores.jsonl` -- one JSON object per case with `{id, lang, P, R, leaked_items, restored_items}`.
A future enhancement may aggregate these into a `results.md` summary table.

## Why this isn't a 100-point shootout

`ai-prompt-guard`'s design is to **reject** sensitive prompts at the gateway. If you reject, P=1 trivially but R is undefined -- the user gets a 400, not a redacted-then-restored message. The blocked-vs-redacted-vs-leaked breakdown is more honest than collapsing to one number. Pair every headline number with the full picture in the same context.
