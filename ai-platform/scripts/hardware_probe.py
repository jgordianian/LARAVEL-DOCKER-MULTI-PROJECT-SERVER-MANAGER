#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import re
import shutil
import subprocess
import time
from pathlib import Path


def run(command: list[str], timeout: int = 15) -> tuple[int, str]:
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
        return result.returncode, result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def int_or_none(value: str) -> int | None:
    value = value.strip()
    return int(value) if re.fullmatch(r"\d+", value) else None


def cpu_info() -> dict:
    model = platform.processor() or "unknown"
    if Path("/proc/cpuinfo").is_file():
        for line in Path("/proc/cpuinfo").read_text(errors="replace").splitlines():
            if line.lower().startswith("model name") and ":" in line:
                model = line.split(":", 1)[1].strip()
                break
    load = list(os.getloadavg()) if hasattr(os, "getloadavg") else []
    return {"model": model, "cores": os.cpu_count() or 1, "load_average": load}


def memory_info() -> dict:
    values: dict[str, int] = {}
    if Path("/proc/meminfo").is_file():
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            match = re.search(r"\d+", value)
            if match:
                values[key] = int(match.group()) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    return {"total_bytes": total, "available_bytes": available, "used_bytes": max(0, total - available)}


def storage_info(path: Path) -> dict:
    path.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(path)
    return {"path": str(path), "total_bytes": usage.total, "used_bytes": usage.used, "free_bytes": usage.free}


def nvidia_info() -> tuple[list[dict], dict]:
    query = [
        "index", "uuid", "name", "memory.total", "memory.used", "memory.free",
        "utilization.gpu", "temperature.gpu", "driver_version", "power.draw", "power.limit", "compute_cap",
    ]
    status, output = run(["nvidia-smi", f"--query-gpu={','.join(query)}", "--format=csv,noheader,nounits"])
    if status != 0 or not output:
        return [], {"vendor": "NVIDIA", "available": False, "version": None, "cuda_compatibility": None}
    gpus = []
    driver = None
    for row in csv.reader(output.splitlines(), skipinitialspace=True):
        if len(row) < len(query):
            continue
        memory_total = int_or_none(row[3])
        memory_used = int_or_none(row[4])
        memory_free = int_or_none(row[5])
        driver = row[8].strip()
        gpus.append({
            "vendor": "NVIDIA", "index": int_or_none(row[0]), "uuid": row[1].strip(), "name": row[2].strip(),
            "memory_total_bytes": (memory_total or 0) * 1024 * 1024,
            "memory_used_bytes": (memory_used or 0) * 1024 * 1024,
            "memory_free_bytes": (memory_free or 0) * 1024 * 1024,
            "utilization_percent": int_or_none(row[6]), "temperature_c": int_or_none(row[7]),
            "power_draw_w": float(row[9]) if re.fullmatch(r"\d+(\.\d+)?", row[9].strip()) else None,
            "power_limit_w": float(row[10]) if re.fullmatch(r"\d+(\.\d+)?", row[10].strip()) else None,
            "compute_capability": row[11].strip() if row[11].strip() not in {"N/A", "[N/A]"} else None,
        })
    _, smi = run(["nvidia-smi"])
    cuda_match = re.search(r"CUDA Version:\s*([0-9.]+)", smi)
    return gpus, {"vendor": "NVIDIA", "available": bool(gpus), "version": driver, "cuda_compatibility": cuda_match.group(1) if cuda_match else None}


def amd_detected() -> bool:
    status, output = run(["lspci", "-nn"])
    return status == 0 and any(
        re.search(r"AMD|Advanced Micro Devices", line, re.I) and re.search(r"VGA|Display|3D", line, re.I)
        for line in output.splitlines()
    )


def docker_info(validate_gpu: bool, image: str) -> dict:
    status, version = run(["docker", "version", "--format", "{{.Server.Version}}"])
    result = {"available": status == 0, "version": version or None, "gpu_validation": "not-run"}
    if status != 0 or not validate_gpu:
        return result
    gpu_status, _ = run(["docker", "run", "--rm", "--gpus", "all", image, "nvidia-smi", "-L"], timeout=120)
    result["gpu_validation"] = "ok" if gpu_status == 0 else "failed"
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage-path", default="/opt/vllm-ai-platform")
    parser.add_argument("--validate-docker", action="store_true")
    parser.add_argument("--cuda-image", default="nvidia/cuda:12.9.1-base-ubuntu24.04")
    parser.add_argument("--output")
    args = parser.parse_args()

    gpus, driver = nvidia_info()
    if not gpus and amd_detected():
        driver = {"vendor": "AMD", "available": True, "version": None, "cuda_compatibility": None, "rocm_status": "detected-not-configured"}
    snapshot = {
        "schema_version": 1,
        "captured_at_unix": int(time.time()),
        "os": {"name": platform.system(), "release": platform.release(), "platform": platform.platform()},
        "cpu": cpu_info(),
        "memory": memory_info(),
        "storage": storage_info(Path(args.storage_path)),
        "gpus": gpus,
        "gpu_driver": driver,
        "docker": docker_info(args.validate_docker, args.cuda_image),
    }
    body = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(body, encoding="utf-8")
        os.replace(temporary, target)
    else:
        print(body, end="")


if __name__ == "__main__":
    main()

