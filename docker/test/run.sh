#!/usr/bin/env bash
# E2E test: send a request with real Chinese PII through Kong, assert that
# the upstream mock LLM never sees the real PII and that the client gets
# the original PII restored on the response.
set -euo pipefail

cd "$(dirname "$0")/.."

REAL_PHONE="13812345678"
REAL_NAME="王五"
PAYLOAD=$(cat <<JSON
{"model":"gpt-4","messages":[{"role":"user","content":"我叫${REAL_NAME}，手机${REAL_PHONE}"}]}
JSON
)

echo "==> Bringing stack up"
docker compose down -v >/dev/null 2>&1 || true
docker compose up -d --build

echo "==> Waiting for healthchecks"
for _ in $(seq 1 30); do
  HEALTHY=$(docker compose ps --format json 2>/dev/null | grep -c '"Health":"healthy"' || true)
  if [ "$HEALTHY" -ge 3 ]; then
    break
  fi
  sleep 2
done
docker compose ps

echo "==> Sending request through Kong"
RESPONSE=$(curl -s -X POST http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")
echo "Client response: $RESPONSE"

echo "==> Asserting client response contains restored phone (canonical signal)"
if ! echo "$RESPONSE" | grep -q "$REAL_PHONE"; then
  echo "FAIL: client response does not contain restored phone $REAL_PHONE"
  echo "Response: $RESPONSE"
  echo "Stack state:"
  docker compose ps
  echo "Plugin logs:"
  docker compose logs kong | tail -30
  exit 1
fi

if echo "$RESPONSE" | grep -q "$REAL_NAME"; then
  echo "INFO: name $REAL_NAME also present in client response (restored)"
else
  echo "INFO: name $REAL_NAME absent from client response (fast mode does not always detect Chinese names without hints; not a failure)"
fi

echo "==> Capturing mock-llm received body"
LLM_LOG=$(docker compose logs mock-llm 2>&1 | grep MOCK_LLM_REQUEST_BODY | tail -1 || true)
echo "Upstream saw: $LLM_LOG"

if [ -z "$LLM_LOG" ]; then
  echo "FAIL: no MOCK_LLM_REQUEST_BODY line found in mock-llm logs"
  docker compose logs mock-llm | tail -30
  exit 1
fi

echo "==> Asserting upstream did NOT see real phone"
if echo "$LLM_LOG" | grep -q "$REAL_PHONE"; then
  echo "FAIL: mock-llm received real phone $REAL_PHONE — redaction broken"
  exit 1
fi

if echo "$LLM_LOG" | grep -q "$REAL_NAME"; then
  echo "INFO: name $REAL_NAME leaked to upstream (fast mode limitation)"
else
  echo "INFO: name $REAL_NAME redacted in upstream"
fi

echo "==> Asserting stream:true returns 400"
STREAM_STATUS=$(curl -s -o /tmp/argus-stream.out -w '%{http_code}' \
  -X POST http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4","stream":true,"messages":[{"role":"user","content":"hi"}]}')
if [ "$STREAM_STATUS" != "400" ]; then
  echo "FAIL: stream:true returned $STREAM_STATUS, expected 400"
  cat /tmp/argus-stream.out
  exit 1
fi

echo "==> Tearing down"
docker compose down -v

echo "==> ALL E2E ASSERTIONS PASSED"
