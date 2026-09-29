#!/usr/bin/env python3
"""Exec one native AI Platform service without sourcing the secrets file."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path


PLATFORM_ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = PLATFORM_ROOT / ".env"


def read_environment(path: Path = ENV_FILE) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or not key.replace("_", "").isalnum():
            raise SystemExit(f"invalid environment key in {path}")
        values[key] = value
    return values


def load_environment() -> dict[str, str]:
    if not ENV_FILE.is_file():
        raise SystemExit(f"native environment file is missing: {ENV_FILE}")
    values = read_environment()
    if values.get("AI_RUNTIME_MODE", "").lower() != "native":
        raise SystemExit("AI_RUNTIME_MODE is not native")
    os.environ.update(values)
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return values


def integer_port(values: dict[str, str], key: str, default: int) -> str:
    try:
        port = int(values.get(key, str(default)))
    except ValueError as exc:
        raise SystemExit(f"{key} is not a valid port") from exc
    if not 1024 <= port <= 65535:
        raise SystemExit(f"{key} must be between 1024 and 65535")
    return str(port)


def exec_python_module(module: str, *arguments: str) -> None:
    command = [sys.executable, "-m", module, *arguments]
    os.chdir(PLATFORM_ROOT)
    os.execve(sys.executable, command, os.environ.copy())


def run_service(name: str) -> None:
    values = load_environment()
    if name == "gateway":
        port = integer_port(values, "NATIVE_GATEWAY_PORT", 8000)
        exec_python_module(
            "uvicorn", "app.gateway:app", "--host", "127.0.0.1", "--port", port,
            "--no-proxy-headers", "--no-server-header",
        )
    if name == "web":
        port = integer_port(values, "NATIVE_WEB_PORT", 18080)
        exec_python_module(
            "uvicorn", "app.web:app", "--host", "127.0.0.1", "--port", port,
            "--no-proxy-headers", "--no-server-header",
        )
    if name == "controller":
        port = integer_port(values, "NATIVE_CONTROLLER_PORT", 8090)
        exec_python_module(
            "uvicorn", "app.controller:app", "--host", "127.0.0.1", "--port", port,
            "--no-proxy-headers", "--no-server-header",
        )
    if name == "redis":
        binary = shutil.which("redis-server")
        if not binary:
            raise SystemExit("redis-server is required for native mode")
        config = PLATFORM_ROOT / "native" / "redis.conf"
        if not config.is_file():
            raise SystemExit(f"native Redis configuration is missing: {config}")
        os.execve(binary, [binary, str(config)], os.environ.copy())
    if name == "migrate":
        exec_python_module("alembic", "upgrade", "head")
    raise SystemExit(f"unsupported native service: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run one isolated native AI Platform service")
    parser.add_argument("service", choices=["gateway", "web", "controller", "redis", "migrate"])
    args = parser.parse_args()
    run_service(args.service)


if __name__ == "__main__":
    main()
