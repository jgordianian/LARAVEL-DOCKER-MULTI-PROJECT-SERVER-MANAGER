from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


def fingerprint(snapshot: dict[str, Any]) -> str:
    stable = {
        "cpu": {"model": snapshot.get("cpu", {}).get("model"), "cores": snapshot.get("cpu", {}).get("cores")},
        "ram_total_bytes": snapshot.get("memory", {}).get("total_bytes"),
        "gpus": sorted([
            {
                "vendor": gpu.get("vendor"),
                "uuid": gpu.get("uuid"),
                "name": gpu.get("name"),
                "memory_total_bytes": gpu.get("memory_total_bytes"),
            }
            for gpu in snapshot.get("gpus", [])
        ], key=lambda item: str(item.get("uuid") or item.get("name") or "")),
        "driver": snapshot.get("gpu_driver", {}),
    }
    return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()


def _amount_change(old: int | float | None, new: int | float | None, label: str) -> dict[str, Any] | None:
    if old == new:
        return None
    direction = "increased" if (new or 0) > (old or 0) else "decreased"
    return {"field": label, "kind": direction, "previous": old, "current": new}


def compare_snapshots(previous: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    changes: list[dict[str, Any]] = []
    for old, new, label in (
        (previous.get("cpu", {}).get("cores"), current.get("cpu", {}).get("cores"), "cpu.cores"),
        (previous.get("memory", {}).get("total_bytes"), current.get("memory", {}).get("total_bytes"), "memory.total_bytes"),
        (previous.get("storage", {}).get("total_bytes"), current.get("storage", {}).get("total_bytes"), "storage.total_bytes"),
    ):
        change = _amount_change(old, new, label)
        if change:
            changes.append(change)

    old_gpus = {gpu.get("uuid") or f"index:{gpu.get('index')}": gpu for gpu in previous.get("gpus", [])}
    new_gpus = {gpu.get("uuid") or f"index:{gpu.get('index')}": gpu for gpu in current.get("gpus", [])}
    for key in sorted(new_gpus.keys() - old_gpus.keys()):
        changes.append({"field": "gpus", "kind": "added", "current": new_gpus[key]})
    for key in sorted(old_gpus.keys() - new_gpus.keys()):
        changes.append({"field": "gpus", "kind": "removed", "previous": old_gpus[key]})
    for key in sorted(old_gpus.keys() & new_gpus.keys()):
        old_gpu, new_gpu = old_gpus[key], new_gpus[key]
        if old_gpu.get("name") != new_gpu.get("name"):
            changes.append({"field": "gpu.name", "kind": "changed", "previous": old_gpu.get("name"), "current": new_gpu.get("name"), "uuid": key})
        change = _amount_change(old_gpu.get("memory_total_bytes"), new_gpu.get("memory_total_bytes"), "gpu.memory_total_bytes")
        if change:
            change["uuid"] = key
            changes.append(change)

    old_driver = previous.get("gpu_driver", {}).get("version")
    new_driver = current.get("gpu_driver", {}).get("version")
    if old_driver != new_driver:
        changes.append({"field": "gpu_driver.version", "kind": "changed", "previous": old_driver, "current": new_driver})

    decrease_kinds = {"decreased", "removed"}
    upgrade = any(change["kind"] in {"increased", "added"} for change in changes)
    downgrade = any(change["kind"] in decrease_kinds for change in changes)
    return {
        "changed": bool(changes),
        "upgrade_detected": upgrade,
        "downgrade_detected": downgrade,
        "requires_model_review": downgrade or any(change["field"].startswith("gpu") for change in changes),
        "changes": changes,
        "previous_fingerprint": fingerprint(previous),
        "current_fingerprint": fingerprint(current),
    }


def load_snapshot(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def total_gpu_vram_gb(snapshot: dict[str, Any], gpu_assignment: list[int] | None = None) -> float:
    selected = set(gpu_assignment or [])
    total = 0
    for gpu in snapshot.get("gpus", []):
        if selected and gpu.get("index") not in selected:
            continue
        total += int(gpu.get("memory_total_bytes") or 0)
    return total / (1024**3)


def estimate_vram_gb(model_size_gb: float, max_model_len: int, max_num_seqs: int, dtype: str = "auto") -> float:
    # Weight size plus engine overhead and a deliberately conservative KV-cache
    # estimate. It is a safety estimate, never presented as an exact value.
    dtype_factor = 0.65 if dtype in {"int8", "float8", "fp8"} else 1.0
    weight = max(0.1, model_size_gb) * dtype_factor
    kv = max_model_len * max_num_seqs * 0.000012
    return round(weight * 1.15 + kv + 0.75, 2)


def analyze_capacity(
    snapshot: dict[str, Any],
    model_size_gb: float,
    max_model_len: int,
    max_num_seqs: int,
    gpu_assignment: list[int],
    gpu_memory_utilization: float,
    existing_allocations_gb: float = 0.0,
    dtype: str = "auto",
) -> dict[str, Any]:
    gpu_indexes = {gpu.get("index") for gpu in snapshot.get("gpus", [])}
    missing = sorted(set(gpu_assignment) - gpu_indexes)
    selected = [gpu for gpu in snapshot.get("gpus", []) if not gpu_assignment or gpu.get("index") in set(gpu_assignment)]
    per_gpu = [int(gpu.get("memory_total_bytes") or 0) / (1024**3) for gpu in selected]
    total = sum(per_gpu)
    estimated = estimate_vram_gb(model_size_gb, max_model_len, max_num_seqs, dtype)
    utilization = min(max(gpu_memory_utilization, 0.1), 0.95)
    # Distributed workers need the model/KV allocation to fit every selected
    # GPU, not merely the sum of a large and a much smaller device.
    balanced_capacity = min(per_gpu, default=0.0) * len(per_gpu) * utilization
    safe_capacity = max(0.0, balanced_capacity - existing_allocations_gb)
    safe = not missing and total > 0 and estimated <= safe_capacity
    ratio = estimated / safe_capacity if safe_capacity > 0 else 999
    label = "SAFE" if safe and ratio <= 0.85 else "POSSIBLE WITH LIMITATIONS" if safe else "INCOMPATIBLE"
    return {
        "safe": safe,
        "label": label,
        "missing_gpu_indexes": missing,
        "estimated_vram_gb": estimated,
        "assigned_vram_gb": round(total, 2),
        "existing_estimated_allocations_gb": round(existing_allocations_gb, 2),
        "safe_available_vram_gb": round(safe_capacity, 2),
        "estimate_notice": "Memory values are estimates; actual use varies by model architecture, vLLM version, context and workload.",
    }

