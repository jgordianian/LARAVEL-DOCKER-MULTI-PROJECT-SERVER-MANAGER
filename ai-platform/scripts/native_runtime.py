#!/usr/bin/env python3
"""Configure and supervise the AI Platform in hosts without Docker/systemd."""

from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


PLATFORM_ROOT = Path(__file__).resolve().parents[1]
NATIVE_ROOT = PLATFORM_ROOT / "native"
NATIVE_CACHE_ROOT = NATIVE_ROOT / "cache"
STATE_ROOT = PLATFORM_ROOT / "state"
LOG_ROOT = PLATFORM_ROOT / "logs"
ENV_FILE = PLATFORM_ROOT / ".env"
SERVICE_SCRIPT = PLATFORM_ROOT / "scripts" / "native_service.py"
SUPERVISOR_CONFIG = NATIVE_ROOT / "supervisord.conf"
SUPERVISOR_SOCKET = STATE_ROOT / "supervisor.sock"
SUPERVISOR_PID = STATE_ROOT / "supervisord.pid"
REDIS_CONFIG = NATIVE_ROOT / "redis.conf"
MODEL_STATE_ROOT = STATE_ROOT / "native-models"
SECRETS_ROOT = PLATFORM_ROOT / "secrets"


def read_environment() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value
    return values


def require_native_environment() -> dict[str, str]:
    if not ENV_FILE.is_file():
        raise SystemExit(f"native environment file is missing: {ENV_FILE}")
    values = read_environment()
    if values.get("AI_RUNTIME_MODE", "").lower() != "native":
        raise SystemExit("AI_RUNTIME_MODE is not native")
    return values


def port(values: dict[str, str], key: str, default: int) -> int:
    value = int(values.get(key, str(default)))
    if not 1024 <= value <= 65535:
        raise SystemExit(f"{key} must be between 1024 and 65535")
    return value


def atomic_private_write(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(body, encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def cloudflared_supervisor_program(values: dict[str, str], service_user: str) -> str:
    mode = values.get("EXTERNAL_EXPOSURE_MODE", "none").strip().lower()
    if mode in {"", "none"}:
        return ""
    if mode != "cloudflare":
        raise SystemExit("EXTERNAL_EXPOSURE_MODE must be none or cloudflare in native mode")

    binary = Path(values.get("CLOUDFLARED_EXECUTABLE", "/opt/instance-tools/bin/cloudflared"))
    token_file = Path(values.get("CLOUDFLARED_TOKEN_FILE", str(SECRETS_ROOT / "cloudflare_tunnel_token")))
    if not binary.is_absolute() or any(character.isspace() for character in str(binary)):
        raise SystemExit("CLOUDFLARED_EXECUTABLE must be an absolute path without whitespace")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SystemExit(f"cloudflared executable is unavailable: {binary}")
    if not token_file.is_absolute() or any(character.isspace() for character in str(token_file)):
        raise SystemExit("CLOUDFLARED_TOKEN_FILE must be an absolute path without whitespace")
    try:
        token_file.resolve().relative_to(SECRETS_ROOT.resolve())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"cloudflared token file must remain inside {SECRETS_ROOT}") from exc
    if not token_file.is_file():
        raise SystemExit(f"cloudflared token file is unavailable: {token_file}")
    token = token_file.read_text(encoding="utf-8").strip()
    if len(token) < 40 or len(token) > 4096 or any(character.isspace() for character in token):
        raise SystemExit("cloudflared token file does not contain one valid connector token")
    account = pwd.getpwnam(service_user)
    os.chown(SECRETS_ROOT, 0, account.pw_gid)
    SECRETS_ROOT.chmod(0o710)
    os.chown(token_file, 0, account.pw_gid)
    token_file.chmod(0o640)
    return f"""
[program:cloudflared]
command={binary} tunnel --no-autoupdate --loglevel info run --token-file {token_file}
directory={PLATFORM_ROOT}
user={service_user}
priority=40
autostart=true
autorestart=unexpected
startsecs=5
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile={LOG_ROOT / 'cloudflared.log'}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5
"""


def configure() -> None:
    values = require_native_environment()
    redis_binary = shutil.which("redis-server")
    if not redis_binary:
        raise SystemExit("redis-server is required; install it before configuring native mode")
    for path in (NATIVE_ROOT, NATIVE_CACHE_ROOT, STATE_ROOT, LOG_ROOT, MODEL_STATE_ROOT, PLATFORM_ROOT / "redis"):
        path.mkdir(parents=True, exist_ok=True)
    redis_password = values.get("REDIS_PASSWORD", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", redis_password):
        raise SystemExit("REDIS_PASSWORD must be a 16-256 character token safe for redis.conf")
    redis_body = "\n".join(
        [
            "bind 127.0.0.1 ::1",
            "protected-mode yes",
            f"port {port(values, 'NATIVE_REDIS_PORT', 16379)}",
            "daemonize no",
            "supervised no",
            f"dir {PLATFORM_ROOT / 'redis'}",
            "appendonly yes",
            "appendfsync everysec",
            "save 900 1",
            "save 300 10",
            f"requirepass {redis_password}",
            "rename-command CONFIG \"\"",
            "rename-command FLUSHALL \"\"",
            "rename-command FLUSHDB \"\"",
            "",
        ]
    )
    atomic_private_write(REDIS_CONFIG, redis_body)

    service_user = values.get("NATIVE_SERVICE_USER", "vllmai")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", service_user):
        raise SystemExit("NATIVE_SERVICE_USER is invalid")
    try:
        service_account = pwd.getpwnam(service_user)
    except KeyError as exc:
        raise SystemExit(f"native service user does not exist: {service_user}") from exc
    os.chown(NATIVE_CACHE_ROOT, service_account.pw_uid, service_account.pw_gid)
    os.chown(REDIS_CONFIG, service_account.pw_uid, service_account.pw_gid)
    # Preserve the virtual-environment interpreter path.  Resolving the
    # symlink would turn <venv>/bin/python into /usr/bin/python and make the
    # supervised services lose all packages installed in the venv.
    python = Path(sys.executable).absolute()
    cloudflared_program = cloudflared_supervisor_program(values, service_user)
    supervisor_body = f"""[unix_http_server]
file={SUPERVISOR_SOCKET}
chmod=0700

[supervisord]
logfile={LOG_ROOT / 'supervisord.log'}
pidfile={SUPERVISOR_PID}
childlogdir={LOG_ROOT}
nodaemon=false
minfds=4096

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://{SUPERVISOR_SOCKET}

[program:redis]
command={python} {SERVICE_SCRIPT} redis
directory={PLATFORM_ROOT}
user={service_user}
priority=10
autostart=true
autorestart=unexpected
startsecs=2
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile={LOG_ROOT / 'redis.log'}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5

[program:gateway]
command={python} {SERVICE_SCRIPT} gateway
directory={PLATFORM_ROOT}
user={service_user}
priority=20
autostart=true
autorestart=unexpected
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile={LOG_ROOT / 'gateway.log'}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5

[program:controller]
command={python} {SERVICE_SCRIPT} controller
directory={PLATFORM_ROOT}
user={service_user}
priority=20
autostart=true
autorestart=unexpected
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile={LOG_ROOT / 'controller.log'}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5

[program:web]
command={python} {SERVICE_SCRIPT} web
directory={PLATFORM_ROOT}
user={service_user}
priority=30
autostart=true
autorestart=unexpected
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile={LOG_ROOT / 'web.log'}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5
{cloudflared_program}
"""
    atomic_private_write(SUPERVISOR_CONFIG, supervisor_body)
    print(f"native_configuration={SUPERVISOR_CONFIG}")


def supervisor_binary(name: str) -> str:
    candidate = Path(sys.executable).absolute().parent / name
    if candidate.is_file():
        return str(candidate)
    found = shutil.which(name)
    if not found:
        raise SystemExit(f"{name} is not installed in the native platform environment")
    return found


def supervisorctl(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [supervisor_binary("supervisorctl"), "-c", str(SUPERVISOR_CONFIG), *arguments],
        check=check,
        text=True,
    )


def drop_privileges(user: str):
    if os.geteuid() != 0:
        return None
    record = pwd.getpwnam(user)

    def apply() -> None:
        os.initgroups(record.pw_name, record.pw_gid)
        os.setgid(record.pw_gid)
        os.setuid(record.pw_uid)

    return apply


def run_migrations(values: dict[str, str]) -> None:
    environment = os.environ.copy()
    environment.update(values)
    service_user = values.get("NATIVE_SERVICE_USER", "vllmai")
    subprocess.run(
        [sys.executable, str(SERVICE_SCRIPT), "migrate"],
        cwd=PLATFORM_ROOT,
        env=environment,
        preexec_fn=drop_privileges(service_user),
        check=True,
    )


def pid_running(path: Path) -> bool:
    try:
        pid = int(path.read_text(encoding="ascii").strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def url_health(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def wait_for_health(values: dict[str, str], timeout: int = 45) -> None:
    urls = {
        "gateway": f"http://127.0.0.1:{port(values, 'NATIVE_GATEWAY_PORT', 8000)}/health",
        "web": f"http://127.0.0.1:{port(values, 'NATIVE_WEB_PORT', 18080)}/health",
        "controller": f"http://127.0.0.1:{port(values, 'NATIVE_CONTROLLER_PORT', 8090)}/health",
    }
    deadline = time.monotonic() + timeout
    pending = dict(urls)
    while pending and time.monotonic() < deadline:
        pending = {name: url for name, url in pending.items() if not url_health(url)}
        if pending:
            time.sleep(1)
    if pending:
        raise SystemExit("native services failed health checks: " + ", ".join(sorted(pending)))


def start() -> None:
    values = require_native_environment()
    configure()
    run_migrations(values)
    if pid_running(SUPERVISOR_PID):
        supervisorctl("reread")
        supervisorctl("update")
        supervisorctl("start", "all", check=False)
    else:
        subprocess.run(
            [supervisor_binary("supervisord"), "-c", str(SUPERVISOR_CONFIG)],
            check=True,
        )
    wait_for_health(values)
    supervisorctl("status")


def process_start_ticks(pid: int) -> str | None:
    try:
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").split()
        return fields[21]
    except (OSError, IndexError):
        return None


def stop_native_models() -> None:
    if not MODEL_STATE_ROOT.is_dir():
        return
    for state_path in MODEL_STATE_ROOT.glob("*.json"):
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
            pid = int(state["pid"])
            start_ticks = str(state["start_ticks"])
            port_value = int(state["port"])
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            state_path.unlink(missing_ok=True)
            continue
        if process_start_ticks(pid) != start_ticks or "vllm" not in cmdline or str(port_value) not in cmdline:
            raise SystemExit(f"refusing to signal an unverified process from {state_path}")
        target = -pid if os.getpgid(pid) == pid else pid
        os.kill(target, signal.SIGTERM)
        deadline = time.monotonic() + 30
        while process_start_ticks(pid) == start_ticks and time.monotonic() < deadline:
            time.sleep(0.25)
        if process_start_ticks(pid) == start_ticks:
            os.kill(target, signal.SIGKILL)
        state_path.unlink(missing_ok=True)


def stop() -> None:
    if pid_running(SUPERVISOR_PID):
        supervisorctl("shutdown", check=False)
        deadline = time.monotonic() + 20
        while pid_running(SUPERVISOR_PID) and time.monotonic() < deadline:
            time.sleep(0.25)
    stop_native_models()
    print("native_platform=stopped")


def status() -> None:
    values = require_native_environment()
    print("runtime_mode=native")
    print(f"supervisor={'running' if pid_running(SUPERVISOR_PID) else 'stopped'}")
    if pid_running(SUPERVISOR_PID):
        supervisorctl("status", check=False)
    for name, selected_port in (
        ("gateway", port(values, "NATIVE_GATEWAY_PORT", 8000)),
        ("web", port(values, "NATIVE_WEB_PORT", 18080)),
        ("controller", port(values, "NATIVE_CONTROLLER_PORT", 8090)),
    ):
        healthy = url_health(f"http://127.0.0.1:{selected_port}/health")
        print(f"{name}={'healthy' if healthy else 'unhealthy'} listener=127.0.0.1:{selected_port}")
    redis_port = port(values, "NATIVE_REDIS_PORT", 16379)
    with socket.socket() as client:
        client.settimeout(1)
        redis_reachable = client.connect_ex(("127.0.0.1", redis_port)) == 0
    print(f"redis={'reachable' if redis_reachable else 'unreachable'} listener=127.0.0.1:{redis_port}")
    exposure = values.get("EXTERNAL_EXPOSURE_MODE", "none").strip().lower() or "none"
    print(f"external_exposure={exposure}")
    if exposure == "cloudflare":
        print(f"external_panel=https://{values.get('CLOUDFLARE_PANEL_HOSTNAME', '')}")
        api_hostname = values.get("CLOUDFLARE_API_HOSTNAME", "")
        if api_hostname:
            print(f"external_api=https://{api_hostname}/v1")


def logs(service: str, lines: int) -> None:
    allowed = {"gateway", "web", "controller", "redis", "supervisord", "cloudflared"}
    if service not in allowed:
        raise SystemExit("unknown native service log")
    path = LOG_ROOT / f"{service}.log"
    if not path.is_file():
        print(f"No log exists yet: {path}")
        return
    body = path.read_text(encoding="utf-8", errors="replace").splitlines()
    print("\n".join(body[-max(1, min(lines, 2000)) :]))


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage the native AI Platform runtime")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("configure")
    subparsers.add_parser("start")
    subparsers.add_parser("stop")
    subparsers.add_parser("restart")
    subparsers.add_parser("status")
    log_parser = subparsers.add_parser("logs")
    log_parser.add_argument("service", choices=["gateway", "web", "controller", "redis", "supervisord", "cloudflared"])
    log_parser.add_argument("--lines", type=int, default=150)
    args = parser.parse_args()
    if args.command == "configure":
        configure()
    elif args.command == "start":
        start()
    elif args.command == "stop":
        stop()
    elif args.command == "restart":
        stop()
        start()
    elif args.command == "status":
        status()
    elif args.command == "logs":
        logs(args.service, args.lines)


if __name__ == "__main__":
    main()
