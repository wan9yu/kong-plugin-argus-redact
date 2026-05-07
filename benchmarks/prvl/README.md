# PRvL benchmark — methodology

**Status:** scaffold + methodology. No numbers committed yet — see `run.sh` to execute.

## What we measure (PRvL = Privacy × Reversibility × Language)

`argus-redact-bridge` enables a *reversible* PII handling pattern: PII is replaced with realistic pseudonyms before reaching the upstream LLM, and the original PII is restored on the response. This benchmark measures three independent dimensions:

| Dimension | What it captures |
|---|---|
| **Privacy** (P) | Does any of the original PII reach the upstream LLM? Measured by inspecting the body the upstream actually receives. |
| **Reversibility** (R) | Does the client see the original PII restored on the response? Measured by string-checking the client-received body. |
| **Language** (L) | How does P × R aggregate per language pack? argus-redact ships zh/en/ja/ko/de/uk/in/br. |

The methodology is intentionally pattern-focused, not product-focused. Comparing `argus-redact-bridge` against any *blocking* PII gateway (one that rejects requests rather than transforming them) makes R undefined for the blocking baseline — those products are different by design. Reporting P alone or R alone collapses an architectural gap into a single number; we publish the full P / R / L breakdown so readers can pick the right baseline for their own use case.

## Test corpus

`payloads.jsonl` — one JSON object per line:

```json
{"id": "zh-001", "lang": "zh", "text": "我叫王五，手机13812345678", "expected_pii": ["王五", "13812345678"]}
{"id": "en-001", "lang": "en", "text": "Hi, I'm John Doe, SSN 123-45-6789", "expected_pii": ["John Doe", "123-45-6789"]}
```

The scaffold ships 5 cases as a starting point. Expand the corpus to ~50 cases per language before publishing aggregate numbers. **Do not use real PII.** All values must be synthetic but format-valid (Luhn check digits, MOD11-2 check codes, etc.).

## Methodology

For each payload, run the request through Kong with the plugin enabled. Capture:

- The body the upstream LLM actually received (from the mock LLM's request log)
- The body the client received as response

Score per case:

- **P**: `1.0` if no `expected_pii` substring appears in the upstream-received body, else `0.0`
- **R**: `1.0` if every `expected_pii` substring appears in the client-received response, else `0.0`
- **L**: aggregate P × R per language bucket

`judge.py` handles per-case scoring; `run.sh` orchestrates corpus iteration.

## Output

`results/argus/scores.jsonl` — one JSON object per case with `{id, lang, P, R, leaked_items, restored_items, expected_count}`.

A future enhancement may aggregate these into a `results.md` summary table.

## Why publish per-dimension instead of a single score

Different PII handling strategies have different scope. A blocking strategy gets P=1 by rejecting the request, but R is undefined (the user got a 400, not a redacted-then-restored message). A redact-only strategy gets P=1 and R=0 (the user gets pseudonyms back, not the original). A reversible-redact strategy aims for P=1 and R=1. Publishing the breakdown lets readers see the trade-off rather than picking the strategy that scores best on whichever single metric the publisher emphasized.
