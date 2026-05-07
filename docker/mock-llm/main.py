"""Mock LLM service for argus-redact-bridge E2E tests.

Returns OpenAI-shape Chat Completions responses that echo the user's
message verbatim, prefixed with `echo: `. Logs every received body to
stdout with a `MOCK_LLM_REQUEST_BODY:` marker so the test runner can
assert what crossed the wire (i.e., what argus-redact-bridge actually
forwarded after redaction).
"""
import json
import sys
from fastapi import FastAPI, Request

app = FastAPI()


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    print(
        "MOCK_LLM_REQUEST_BODY: " + json.dumps(body, ensure_ascii=False),
        file=sys.stdout,
        flush=True,
    )

    user_msg = ""
    for m in body.get("messages", []):
        if m.get("role") == "user" and isinstance(m.get("content"), str):
            user_msg = m["content"]
            break

    reply = "echo: " + user_msg

    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "model": body.get("model", "mock"),
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }
        ],
    }


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
