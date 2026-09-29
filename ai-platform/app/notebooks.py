from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import pwd
except ImportError:  # pragma: no cover - non-POSIX development hosts
    pwd = None  # type: ignore[assignment]


NOTEBOOK_KINDS = {"vllm-api", "gpu-benchmark", "tool-calling", "embeddings-rag"}
KIND_DIRECTORIES = {
    "vllm-api": "diagnostics",
    "gpu-benchmark": "benchmarks",
    "tool-calling": "examples",
    "embeddings-rag": "examples",
}


def _markdown(source: str) -> dict[str, Any]:
    return {"cell_type": "markdown", "metadata": {}, "source": source.splitlines(keepends=True)}


def _code(source: str) -> dict[str, Any]:
    return {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": source.splitlines(keepends=True)}


SAFETY = """# Omnivis AI Platform diagnostic

This notebook is a development/diagnostic client of the secured **AI Gateway**. It does not start vLLM, alter Jupyter, access Omnivis production data, or receive encryption keys. Review every cell before execution. Use a dedicated diagnostic API key with minimal model, endpoint, scope, IP and quota permissions.
"""

CREDENTIALS = """import getpass
import json
import os
import time
import urllib.error
import urllib.request

BASE_URL = os.environ.get("OMNIVIS_AI_BASE_URL", "https://ai.example.com/v1").rstrip("/")
API_KEY = os.environ.get("OMNIVIS_CODING_API_KEY")
if not API_KEY:
    API_KEY = getpass.getpass("Gateway API key (kept only in kernel memory): ")
if not API_KEY:
    raise RuntimeError("A dedicated diagnostic Gateway API key is required")

def gateway_request(path, payload=None, timeout=60):
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {"Authorization": f"Bearer {API_KEY}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{BASE_URL}{path}", data=body, headers=headers)
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read())
    return result, time.perf_counter() - started
"""

SAFE_ENVIRONMENT = """import platform
import shutil
import subprocess
import sys
import time

print({"python": sys.version.split()[0], "executable": sys.executable, "platform": platform.platform()})
if shutil.which("nvidia-smi"):
    result = subprocess.run(
        ["nvidia-smi", "--query-gpu=name,memory.total,memory.free,utilization.gpu,temperature.gpu,power.draw", "--format=csv,noheader,nounits"],
        capture_output=True, text=True, timeout=15, check=False,
    )
    print(result.stdout if result.returncode == 0 else "nvidia-smi query failed")
else:
    print("nvidia-smi is not available")

try:
    import torch
    print({"torch": torch.__version__, "cuda_available": torch.cuda.is_available(), "device_count": torch.cuda.device_count()})
    if torch.cuda.is_available():
        print([torch.cuda.get_device_name(index) for index in range(torch.cuda.device_count())])
except ImportError:
    print("PyTorch is not installed; it was not installed or changed by this notebook.")
"""


def _vllm_api_cells() -> list[dict[str, Any]]:
    return [
        _markdown(SAFETY + "\nTests model visibility, one chat request and one bounded streaming request."),
        _code(SAFE_ENVIRONMENT),
        _code(CREDENTIALS),
        _code("""models, latency = gateway_request("/models")
aliases = [item.get("id") for item in models.get("data", [])]
print({"model_aliases": aliases, "latency_seconds": round(latency, 3)})
MODEL = os.environ.get("OMNIVIS_TEST_MODEL") or (aliases[0] if aliases else None)
if not MODEL:
    raise RuntimeError("No authorized active model is visible")
"""),
        _code("""response, latency = gateway_request("/chat/completions", {
    "model": MODEL,
    "messages": [{"role": "user", "content": "Reply with one short diagnostic sentence."}],
    "max_tokens": 64,
})
print({"model": MODEL, "latency_seconds": round(latency, 3), "usage": response.get("usage")})
print(response.get("choices", [{}])[0].get("message", {}).get("content", ""))
"""),
        _code("""payload = json.dumps({
    "model": MODEL,
    "messages": [{"role": "user", "content": "Count from one to three."}],
    "stream": True,
    "stream_options": {"include_usage": True},
    "max_tokens": 32,
}).encode()
request = urllib.request.Request(
    f"{BASE_URL}/chat/completions", data=payload,
    headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
)
started = time.perf_counter()
first_event = None
event_count = 0
with urllib.request.urlopen(request, timeout=60) as stream:
    for raw_line in stream:
        line = raw_line.decode("utf-8", "replace").strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        event_count += 1
        if first_event is None:
            first_event = time.perf_counter()
print({"events": event_count, "ttft_seconds": round(first_event - started, 3) if first_event else None, "total_seconds": round(time.perf_counter() - started, 3)})
"""),
    ]


def _gpu_benchmark_cells() -> list[dict[str, Any]]:
    return [
        _markdown(SAFETY + "\nRuns one short matrix operation only. It does not stress, overclock, load another model, or change GPU settings."),
        _code(SAFE_ENVIRONMENT),
        _code("""try:
    import torch
except ImportError:
    print("PyTorch benchmark unavailable; no package will be installed.")
else:
    if not torch.cuda.is_available():
        print("PyTorch cannot see a CUDA GPU.")
    else:
        free_bytes, total_bytes = torch.cuda.mem_get_info()
        print({"free_gib": round(free_bytes / 1024**3, 2), "total_gib": round(total_bytes / 1024**3, 2)})
        if free_bytes < 512 * 1024**2:
            print("Benchmark skipped: less than 512 MiB free VRAM.")
        else:
            size = 1024
            left = torch.randn((size, size), device="cuda")
            right = torch.randn((size, size), device="cuda")
            torch.cuda.synchronize()
            started = time.perf_counter()
            output = left @ right
            torch.cuda.synchronize()
            print({"matrix_size": size, "elapsed_seconds": round(time.perf_counter() - started, 4)})
            del left, right, output
            torch.cuda.empty_cache()
"""),
        _markdown("## Optional conservative Gateway benchmark\n\nRun only against a dedicated diagnostic account. Defaults are one request and no concurrency."),
        _code(CREDENTIALS),
        _code("""from concurrent.futures import ThreadPoolExecutor

models, _ = gateway_request("/models")
aliases = [item.get("id") for item in models.get("data", [])]
MODEL = os.environ.get("OMNIVIS_TEST_MODEL") or (aliases[0] if aliases else None)
REQUESTS = min(max(int(os.environ.get("OMNIVIS_BENCHMARK_REQUESTS", "1")), 1), 5)
CONCURRENCY = min(max(int(os.environ.get("OMNIVIS_BENCHMARK_CONCURRENCY", "1")), 1), 2)

def one_request(_index):
    response, elapsed = gateway_request("/chat/completions", {
        "model": MODEL,
        "messages": [{"role": "user", "content": "Return exactly five words."}],
        "max_tokens": 32,
    })
    usage = response.get("usage", {})
    output_tokens = usage.get("completion_tokens") or 0
    return {
        "latency_seconds": round(elapsed, 3),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": output_tokens,
        "total_tokens": usage.get("total_tokens"),
        "output_tokens_per_second": round(output_tokens / elapsed, 2) if elapsed and output_tokens else None,
    }

with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
    measurements = list(pool.map(one_request, range(REQUESTS)))
print({"requests": REQUESTS, "concurrency": CONCURRENCY, "measurements": measurements})
"""),
    ]


def _tool_calling_cells() -> list[dict[str, Any]]:
    return [
        _markdown(SAFETY + "\nUses mock `get_weather_test`, `calculator_test` and `echo_test` schemas. Returned calls are inspected but never executed automatically."),
        _code(CREDENTIALS),
        _code("""models, _ = gateway_request("/models")
aliases = [item.get("id") for item in models.get("data", [])]
MODEL = os.environ.get("OMNIVIS_TEST_MODEL") or (aliases[0] if aliases else None)
MOCK_TOOLS = [
    {"type": "function", "function": {"name": "get_weather_test", "description": "Return synthetic test weather", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}},
    {"type": "function", "function": {"name": "calculator_test", "description": "Evaluate a synthetic arithmetic test", "parameters": {"type": "object", "properties": {"expression": {"type": "string"}}, "required": ["expression"]}}},
    {"type": "function", "function": {"name": "echo_test", "description": "Echo synthetic text", "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}},
]
"""),
        _code("""response, latency = gateway_request("/chat/completions", {
    "model": MODEL,
    "messages": [{"role": "user", "content": "Use echo_test with the text diagnostic-ok."}],
    "tools": MOCK_TOOLS,
    "tool_choice": "auto",
    "max_tokens": 128,
})
message = response.get("choices", [{}])[0].get("message", {})
print({"latency_seconds": round(latency, 3), "tool_calls": message.get("tool_calls", []), "automatic_execution": False})
"""),
        _code("""# Optional structured-output check. Unsupported model/runtime combinations are reported, not emulated.
try:
    response, latency = gateway_request("/chat/completions", {
        "model": MODEL,
        "messages": [{"role": "user", "content": "Return diagnostic status ok as JSON."}],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "diagnostic", "schema": {"type": "object", "properties": {"status": {"type": "string"}}, "required": ["status"], "additionalProperties": False}},
        },
        "max_tokens": 64,
    })
    print({"latency_seconds": round(latency, 3), "structured_output": response.get("choices", [{}])[0].get("message", {}).get("content")})
except urllib.error.HTTPError as error:
    print({"structured_output_test": "unsupported_or_denied", "http_status": error.code})
"""),
        _code("""# Run only when diagnostics confirm /v1/responses for this model/runtime.
responses_tools = [item["function"] | {"type": "function"} for item in MOCK_TOOLS]
try:
    response, latency = gateway_request("/responses", {
        "model": MODEL,
        "input": "Use calculator_test for 2 + 2.",
        "tools": responses_tools,
        "tool_choice": "auto",
        "max_output_tokens": 128,
    })
    print({"latency_seconds": round(latency, 3), "output": response.get("output", []), "automatic_execution": False})
except urllib.error.HTTPError as error:
    print({"responses_test": "unsupported_or_denied", "http_status": error.code})
"""),
    ]


def _embeddings_cells() -> list[dict[str, Any]]:
    return [
        _markdown(SAFETY + "\nUses synthetic sentences only; it never copies Omnivis or private RAG data."),
        _code(CREDENTIALS),
        _code("""EMBEDDING_MODEL = os.environ.get("OMNIVIS_EMBEDDING_MODEL", "omnivis-embed")
documents = [
    "Synthetic document about secure API gateways.",
    "Synthetic document about GPU memory planning.",
    "Synthetic document about garden irrigation.",
]
query = "How should GPU capacity be planned?"
response, latency = gateway_request("/embeddings", {"model": EMBEDDING_MODEL, "input": documents + [query]})
vectors = [item["embedding"] for item in response.get("data", [])]
print({"model": EMBEDDING_MODEL, "vectors": len(vectors), "dimensions": len(vectors[0]) if vectors else 0, "latency_seconds": round(latency, 3)})
"""),
        _code("""import math

def cosine(left, right):
    numerator = sum(a * b for a, b in zip(left, right))
    denominator = math.sqrt(sum(a * a for a in left)) * math.sqrt(sum(b * b for b in right))
    return numerator / denominator if denominator else 0.0

if len(vectors) == len(documents) + 1:
    query_vector = vectors[-1]
    ranked = sorted(((cosine(vector, query_vector), text) for vector, text in zip(vectors[:-1], documents)), reverse=True)
    print([{"similarity": round(score, 4), "text": text} for score, text in ranked])
else:
    print("Embedding response did not contain the expected synthetic vectors.")
"""),
    ]


def notebook_document(kind: str) -> dict[str, Any]:
    if kind not in NOTEBOOK_KINDS:
        raise ValueError(f"unsupported notebook kind: {kind}")
    builders = {
        "vllm-api": _vllm_api_cells,
        "gpu-benchmark": _gpu_benchmark_cells,
        "tool-calling": _tool_calling_cells,
        "embeddings-rag": _embeddings_cells,
    }
    return {
        "cells": builders[kind](),
        "metadata": {
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python", "version": "3"},
            "omnivis": {"kind": kind, "contains_credentials": False, "gateway_only": True},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def _validate_owner(owner: str | None) -> tuple[int, int] | None:
    if not owner or not pwd or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", owner, re.I):
        return None
    try:
        record = pwd.getpwnam(owner)
    except KeyError:
        return None
    return record.pw_uid, record.pw_gid


def generate_notebook(kind: str, output_root: Path, owner: str | None = None) -> Path:
    document = notebook_document(kind)
    root = output_root.resolve()
    target_directory = (root / KIND_DIRECTORIES[kind]).resolve()
    if root != target_directory and root not in target_directory.parents:
        raise ValueError("notebook target escapes the configured workspace")
    target_directory.mkdir(parents=True, exist_ok=True)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = target_directory / f"{kind}-{stamp}.ipynb"
    suffix = 2
    while target.exists():
        target = target_directory / f"{kind}-{stamp}-{suffix}.ipynb"
        suffix += 1
    temporary = target.with_suffix(".ipynb.tmp")
    temporary.write_text(json.dumps(document, indent=1, ensure_ascii=True) + "\n", encoding="utf-8")
    os.replace(temporary, target)
    os.chmod(target, 0o660)

    ownership = _validate_owner(owner)
    if ownership and hasattr(os, "chown") and hasattr(os, "geteuid") and os.geteuid() == 0:
        os.chown(target_directory, *ownership)
        os.chmod(target_directory, 0o770)
        os.chown(target, *ownership)
    return target
