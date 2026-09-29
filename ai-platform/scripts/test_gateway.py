#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse


def request_json(base_url: str, api_key: str, path: str, payload: dict | None = None) -> tuple[dict, float]:
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {"Authorization": f"Bearer {api_key}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{base_url}{path}", data=body, headers=headers)
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=60) as response:
        value = json.loads(response.read())
    return value, time.perf_counter() - started


def main() -> None:
    parser = argparse.ArgumentParser(description="Test the secured AI Gateway without persisting its API key")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model")
    parser.add_argument("--api-key-stdin", action="store_true", required=True)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    parsed = urlparse(base_url)
    if parsed.scheme != "https" or parsed.query or parsed.fragment or not parsed.hostname or not parsed.path.endswith("/v1"):
        raise SystemExit("ERROR: base URL must be an HTTPS Gateway URL ending in /v1")
    if args.model and not re.fullmatch(r"[A-Za-z0-9._-]+", args.model):
        raise SystemExit("ERROR: invalid model alias")
    api_key = sys.stdin.readline().strip()
    if not re.fullmatch(r"ovai_live_[A-Za-z0-9._-]+", api_key):
        raise SystemExit("ERROR: invalid API key format")

    try:
        models, latency = request_json(base_url, api_key, "/models")
        safe_models = [
            {"id": item.get("id"), "capabilities": item.get("capabilities", [])}
            for item in models.get("data", [])
        ]
        result: dict = {"gateway_reachable": True, "models_latency_seconds": round(latency, 3), "authorized_models": safe_models}
        if args.model:
            response, chat_latency = request_json(
                base_url,
                api_key,
                "/chat/completions",
                {
                    "model": args.model,
                    "messages": [{"role": "user", "content": "Reply with one short diagnostic sentence."}],
                    "max_tokens": 64,
                },
            )
            result["vllm_api_tested"] = True
            result["chat_latency_seconds"] = round(chat_latency, 3)
            result["model"] = response.get("model", args.model)
            result["usage"] = response.get("usage")
            result["response"] = response.get("choices", [{}])[0].get("message", {}).get("content", "")
        else:
            result["vllm_api_tested"] = False
        print(json.dumps(result, indent=2))
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"ERROR: Gateway returned HTTP {exc.code}; verify key, CIDR, scopes, endpoints, model and quotas") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise SystemExit(f"ERROR: Gateway test failed ({type(exc).__name__}); no credential was logged") from None
    finally:
        api_key = ""


if __name__ == "__main__":
    main()
