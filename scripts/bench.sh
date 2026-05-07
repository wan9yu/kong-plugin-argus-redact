#!/usr/bin/env bash
# End-to-end latency benchmark: send N requests through Kong + argus-redact
# and report p50, p95, p99, and throughput. Run after `docker compose up`.
set -euo pipefail

KONG_URL="${KONG_URL:-http://localhost:18000}"
N="${N:-100}"
PAYLOAD='{"model":"gpt-4","messages":[{"role":"user","content":"我叫王五，手机13812345678"}]}'

echo "Warming up (5 requests)..."
for _ in $(seq 1 5); do
  curl -s -o /dev/null "$KONG_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$PAYLOAD" || true
done

echo "Running $N timed requests..."
TMPFILE=$(mktemp)
START=$(python3 -c 'import time; print(time.time())')
for i in $(seq 1 "$N"); do
  T=$(curl -s -o /dev/null -w '%{time_total}' \
    "$KONG_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$PAYLOAD")
  echo "$T" >> "$TMPFILE"
done
END=$(python3 -c 'import time; print(time.time())')

python3 <<PY
import statistics
with open("$TMPFILE") as f:
    times = sorted(float(x) * 1000 for x in f if x.strip())
n = len(times)
elapsed = $END - $START
print(f"Requests:     {n}")
print(f"Total time:   {elapsed:.2f}s")
print(f"Throughput:   {n/elapsed:.1f} req/s")
print(f"p50 latency:  {times[n//2]:.1f} ms")
print(f"p95 latency:  {times[int(n*0.95)]:.1f} ms")
print(f"p99 latency:  {times[int(n*0.99)]:.1f} ms")
print(f"min:          {min(times):.1f} ms")
print(f"max:          {max(times):.1f} ms")
PY

rm -f "$TMPFILE"
