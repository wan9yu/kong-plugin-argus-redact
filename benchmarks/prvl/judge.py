"""Score one (payload, upstream_body, client_response) triple along PRvL."""
import json
import sys


def score(payload: dict, upstream_body: str, client_response: str) -> dict:
    expected = payload["expected_pii"]
    leaked = [pii for pii in expected if pii in upstream_body]
    restored = [pii for pii in expected if pii in client_response]
    return {
        "id": payload["id"],
        "lang": payload["lang"],
        "P": 1.0 if not leaked else 0.0,
        "R": 1.0 if len(restored) == len(expected) else 0.0,
        "leaked_items": leaked,
        "restored_items": restored,
        "expected_count": len(expected),
    }


def main():
    if len(sys.argv) != 4:
        print("Usage: judge.py <payload.json> <upstream_body.txt> <client_response.txt>", file=sys.stderr)
        sys.exit(2)
    payload = json.loads(open(sys.argv[1]).read())
    upstream = open(sys.argv[2]).read()
    client = open(sys.argv[3]).read()
    result = score(payload, upstream, client)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
