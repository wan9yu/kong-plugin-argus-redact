#!/usr/bin/env bash
# PRvL benchmark driver -- scaffold.
# Not invoked by CI. Run manually after collecting a publishable corpus.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

run_through_stack() {
  local payload_file="$1"
  local kong_url="$2"
  local out_dir="$3"
  mkdir -p "$out_dir"
  : > "$out_dir/scores.jsonl"
  while IFS= read -r line; do
    local id text body
    id=$(echo "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])')
    text=$(echo "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["text"])')
    echo "$line" > "$out_dir/$id.payload.json"

    body=$(printf '{"model":"gpt-4","messages":[{"role":"user","content":%s}]}' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text")")

    curl -s -X POST "$kong_url/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$body" > "$out_dir/$id.client.json" || true

    docker compose -f "$REPO_ROOT/docker/docker-compose.yml" logs mock-llm 2>&1 \
      | grep MOCK_LLM_REQUEST_BODY | tail -1 > "$out_dir/$id.upstream.txt" || true

    python3 "$SCRIPT_DIR/judge.py" \
      "$out_dir/$id.payload.json" \
      "$out_dir/$id.upstream.txt" \
      "$out_dir/$id.client.json" \
      >> "$out_dir/scores.jsonl"
  done < "$payload_file"
}

# === Stack A: argus-redact-bridge ===
echo "==> Running argus-redact-bridge stack"
docker compose -f "$REPO_ROOT/docker/docker-compose.yml" down -v >/dev/null 2>&1 || true
docker compose -f "$REPO_ROOT/docker/docker-compose.yml" up -d --build
sleep 15
run_through_stack "$SCRIPT_DIR/payloads.jsonl" "http://localhost:18000" "$RESULTS_DIR/argus"
docker compose -f "$REPO_ROOT/docker/docker-compose.yml" down -v

# === Stack B: alternative PII handling baseline ===
# TODO(follow-up): wire a parallel docker-compose stack with a baseline PII
# handler (e.g., a regex-based blocking pattern, or a one-way redact-and-strip
# pattern) so the methodology can be reproduced against a concrete baseline.
# The choice of baseline is left to whoever runs the benchmark; we keep the
# methodology product-agnostic so the same harness can compare any number
# of strategies.
echo "==> Stack B (alternative baseline) not yet wired — see README.md"

echo "==> Done. See $RESULTS_DIR/argus/scores.jsonl"
