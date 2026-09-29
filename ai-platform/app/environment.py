from __future__ import annotations

import csv
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping

try:
    import pwd
except ImportError:  # pragma: no cover - only used by non-POSIX development hosts
    pwd = None  # type: ignore[assignment]


ENVIRONMENT_TYPES = {
    "FULL_VM",
    "BARE_METAL",
    "DOCKER_CONTAINER",
    "VAST_AI_CONTAINER",
    "OTHER_MARKETPLACE_CONTAINER",
}
VAST_ENV_KEYS = {
    "VASTAI_INSTANCE_ID",
    "VAST_AI_INSTANCE_ID",
    "VAST_CONTAINERLABEL",
    "VAST_CONTAINER_LABEL",
    "VAST_TCP_PORT_8080",
}
MARKETPLACE_ENV_PREFIXES = ("RUNPOD_", "PAPERSPACE_", "LAMBDA_", "FLY_", "MODAL_")
IMAGE_ENV_KEYS = ("VASTAI_IMAGE", "CONTAINER_IMAGE", "DOCKER_IMAGE", "IMAGE_NAME")
SECRET_MARKERS = ("token=", "password=", "secret=", "apikey=", "api_key=")
JUPYTER_NAMES = {"jupyter", "jupyter-lab", "jupyter-notebook", "jupyter-server", "jupyterhub"}

Runner = Callable[[list[str], int], tuple[int, str]]


def run_read_only(command: list[str], timeout: int = 10) -> tuple[int, str]:
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def _read_text(path: Path, limit: int = 131072) -> str:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return handle.read(limit)
    except OSError:
        return ""


def sanitize_image_reference(value: str | None) -> str | None:
    """Return useful image metadata without retaining URL credentials or query secrets."""
    if not value:
        return None
    cleaned = value.strip().replace("\x00", "")[:512]
    cleaned = re.sub(r"^[a-z][a-z0-9+.-]*://", "", cleaned, flags=re.I)
    cleaned = re.sub(r"^[^/@\s]+:[^/@\s]+@", "", cleaned)
    cleaned = cleaned.split("?", 1)[0].split("#", 1)[0]
    lowered = cleaned.lower()
    if any(marker in lowered for marker in SECRET_MARKERS) or any(char.isspace() for char in cleaned):
        return None
    return cleaned[:256] or None


def sanitize_diagnostic_path(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = value.strip().replace("\x00", "")[:4096]
    if any(marker in cleaned.lower() for marker in SECRET_MARKERS) or any(ord(char) < 32 for char in cleaned):
        return None
    return cleaned or None


def _image_from_environment(env: Mapping[str, str]) -> str | None:
    for key in IMAGE_ENV_KEYS:
        image = sanitize_image_reference(env.get(key))
        if image:
            return image
    return None


def _marketplace_from_environment(env: Mapping[str, str]) -> str | None:
    keys = {key.upper() for key, value in env.items() if value}
    if keys.intersection(VAST_ENV_KEYS):
        return "Vast.ai"
    if any(key.startswith("RUNPOD_") for key in keys):
        return "RunPod"
    if any(key.startswith("PAPERSPACE_") for key in keys):
        return "Paperspace"
    if any(key.startswith("LAMBDA_") for key in keys):
        return "Lambda"
    if any(key.startswith(MARKETPLACE_ENV_PREFIXES) for key in keys):
        return "Other marketplace"
    return None


def classify_environment(
    *,
    container_detected: bool,
    virtualization: str | None,
    image: str | None,
    provider_hint: str | None,
    hostname: str,
    vast_marker: bool,
    jupyter_detected: bool,
) -> tuple[str, str]:
    image_lower = (image or "").lower()
    host_lower = hostname.lower()
    vast = bool(
        provider_hint == "Vast.ai"
        or "vastai/" in image_lower
        or "vast.ai" in image_lower
        or vast_marker
        or (container_detected and jupyter_detected and "vast" in host_lower)
    )
    marketplace = provider_hint is not None and provider_hint != "Vast.ai"
    if container_detected:
        if vast:
            return "VAST_AI_CONTAINER", "Vast.ai"
        if marketplace:
            return "OTHER_MARKETPLACE_CONTAINER", provider_hint or "Other marketplace"
        return "DOCKER_CONTAINER", "Local / unknown container provider"
    if vast:
        # A provider may hide cgroup/container indicators. Preserve it as a
        # marketplace environment rather than enabling host-only operations.
        return "VAST_AI_CONTAINER", "Vast.ai"
    if marketplace:
        return "OTHER_MARKETPLACE_CONTAINER", provider_hint or "Other marketplace"
    if virtualization and virtualization not in {"none", "docker", "podman", "lxc", "container-other"}:
        return "FULL_VM", "Local / self-managed"
    return "BARE_METAL", "Local / self-managed"


def _process_is_jupyter(command: str, arguments: list[str]) -> tuple[bool, bool]:
    names = {Path(command).name.lower()}
    names.update(Path(item).name.lower() for item in arguments[:4] if item and not item.startswith("--"))
    joined = " ".join(arguments[:6]).lower()
    detected = bool(names.intersection(JUPYTER_NAMES) or "-m jupyter" in joined or "jupyterlab" in names)
    lab = "jupyter-lab" in names or "jupyterlab" in names or "-m jupyterlab" in joined
    return detected, lab


def _jupyter_port(arguments: list[str]) -> int | None:
    for index, item in enumerate(arguments):
        match = re.fullmatch(r"--(?:ServerApp\.)?port=(\d{1,5})", item, re.I)
        if match and 0 < int(match.group(1)) < 65536:
            return int(match.group(1))
        if item.lower() in {"--port", "--serverapp.port"} and index + 1 < len(arguments):
            if arguments[index + 1].isdigit() and 0 < int(arguments[index + 1]) < 65536:
                return int(arguments[index + 1])
    return None


def scan_jupyter_processes(proc_root: Path = Path("/proc")) -> dict[str, Any]:
    processes: list[dict[str, Any]] = []
    if not proc_root.is_dir():
        return {"running": False, "process_count": 0, "lab_running": False, "users": [], "declared_ports": []}
    try:
        entries = list(proc_root.iterdir())
    except OSError:
        entries = []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        command = _read_text(entry / "comm", 256).strip()
        try:
            raw = (entry / "cmdline").read_bytes()[:65536]
        except OSError:
            continue
        arguments = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
        detected, lab = _process_is_jupyter(command, arguments)
        if not detected:
            continue
        try:
            username = pwd.getpwuid(entry.stat().st_uid).pw_name if pwd else "unknown"
        except (KeyError, OSError):
            username = "unknown"
        # Do not retain process arguments: they may contain auth tokens.
        python_executable = arguments[0] if arguments and re.fullmatch(r"python(?:3(?:\.\d+)?)?", Path(arguments[0]).name, re.I) else None
        processes.append({"user": username, "lab": lab, "port": _jupyter_port(arguments), "python_executable": python_executable})
    return {
        "running": bool(processes),
        "process_count": len(processes),
        "lab_running": any(item["lab"] for item in processes),
        "users": sorted({item["user"] for item in processes}),
        "declared_ports": sorted({item["port"] for item in processes if item["port"]}),
        "python_executables": sorted({item["python_executable"] for item in processes if item["python_executable"]}),
    }


def _listener_rows(runner: Runner, proc_root: Path) -> list[dict[str, Any]]:
    status, output = runner(["ss", "-ltnH"], 5)
    rows: list[dict[str, Any]] = []
    if status == 0:
        for line in output.splitlines():
            fields = line.split()
            if len(fields) < 4:
                continue
            local = fields[3]
            match = re.search(r"(?:\[([^]]+)\]|([^:]+)):(\d+)$", local)
            if not match:
                continue
            address = match.group(1) or match.group(2) or "unknown"
            rows.append({"address": address, "port": int(match.group(3))})
    if rows:
        return rows
    for name, ipv6 in (("net/tcp", False), ("net/tcp6", True)):
        text = _read_text(proc_root / name)
        for line in text.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 4 or fields[3] != "0A" or ":" not in fields[1]:
                continue
            address_hex, port_hex = fields[1].rsplit(":", 1)
            try:
                port = int(port_hex, 16)
            except ValueError:
                continue
            if ipv6:
                address = "::" if set(address_hex) <= {"0"} else "ipv6"
            else:
                address = "0.0.0.0" if address_hex == "00000000" else "ipv4"
            rows.append({"address": address, "port": port})
    return rows


def _scope_for_address(address: str) -> str:
    normalized = address.strip("[]").lower()
    if normalized in {"127.0.0.1", "::1", "localhost"}:
        return "LOOPBACK"
    if normalized in {"0.0.0.0", "::", "*"}:
        return "ALL_INTERFACES"
    return "LOCAL_OR_MAPPED"


def _runtime_file_count(homes: list[Path]) -> int:
    count = 0
    for home in homes:
        directory = home / ".local" / "share" / "jupyter" / "runtime"
        try:
            count += sum(1 for item in directory.iterdir() if item.name.startswith(("jpserver-", "nbserver-")) and item.suffix == ".json")
        except OSError:
            continue
    return count


def _cap_sys_admin(proc_root: Path) -> bool:
    status = _read_text(proc_root / "self" / "status")
    match = re.search(r"^CapEff:\s*([0-9a-f]+)$", status, re.M | re.I)
    if not match:
        return False
    return bool(int(match.group(1), 16) & (1 << 21))


def _nvidia_snapshot(runner: Runner) -> dict[str, Any]:
    status, output = runner(
        ["nvidia-smi", "--query-gpu=name,memory.total,memory.free", "--format=csv,noheader,nounits"],
        10,
    )
    devices = []
    if status == 0:
        for row in csv.reader(output.splitlines(), skipinitialspace=True):
            if len(row) < 3:
                continue
            try:
                total_mib, free_mib = int(float(row[1])), int(float(row[2]))
            except ValueError:
                total_mib, free_mib = 0, 0
            devices.append({"name": row[0].strip(), "memory_total_mib": total_mib, "memory_free_mib": free_mib})
    _, summary = runner(["nvidia-smi"], 10)
    match = re.search(r"CUDA Version:\s*([0-9.]+)", summary)
    return {
        "visible": bool(devices),
        "version": match.group(1) if match else None,
        "device_count": len(devices),
        "devices": devices,
    }


def probe_pytorch_gpu(python_executable: str, runner: Runner = run_read_only) -> dict[str, Any]:
    script = (
        "import json, torch; "
        "ok=bool(torch.cuda.is_available()); "
        "count=int(torch.cuda.device_count()) if ok else 0; "
        "print(json.dumps({'available': True, 'cuda_available': ok, 'device_count': count, "
        "'devices': [torch.cuda.get_device_name(i) for i in range(count)], "
        "'torch_version': str(torch.__version__), 'torch_cuda_version': torch.version.cuda}))"
    )
    status, output = runner([python_executable, "-c", script], 30)
    if status != 0:
        return {"available": False, "gpu_status": "NOT_AVAILABLE", "cuda_available": False, "device_count": 0}
    try:
        result = json.loads(output)
    except json.JSONDecodeError:
        return {"available": True, "gpu_status": "ERROR", "cuda_available": False, "device_count": 0}
    result["gpu_status"] = "YES" if result.get("cuda_available") else "NO"
    return result


def _container_runtime(filesystem_root: Path, cgroup: str) -> str | None:
    if (filesystem_root / "run" / ".containerenv").exists() or "podman" in cgroup.lower():
        return "podman"
    if (filesystem_root / ".dockerenv").exists() or "docker" in cgroup.lower():
        return "docker"
    if "containerd" in cgroup.lower() or "kubepods" in cgroup.lower():
        return "containerd"
    if "lxc" in cgroup.lower():
        return "lxc"
    return "unknown" if cgroup else None


def _jupyter_python(process: dict[str, Any], managed_venv: Path, which: Callable[[str], str | None]) -> tuple[str, str]:
    if process.get("python_executables"):
        candidate = sanitize_diagnostic_path(str(process["python_executables"][0]))
        resolved = candidate if candidate and Path(candidate).is_absolute() and Path(candidate).is_file() else which(candidate or "")
        resolved = sanitize_diagnostic_path(resolved)
        if resolved:
            return resolved, "jupyter_process"
    managed_python = managed_venv / "python"
    if managed_python.is_file():
        return str(managed_python), "ai_platform_jupyter_venv"
    return sys.executable, "environment_probe"


def _pytorch_available(python_executable: str, runner: Runner) -> bool:
    status, output = runner(
        [python_executable, "-c", "import importlib.util; print('yes' if importlib.util.find_spec('torch') else 'no')"],
        10,
    )
    return status == 0 and output.strip() == "yes"


def probe_environment(
    *,
    platform_root: Path = Path("/opt/vllm-ai-platform"),
    filesystem_root: Path = Path("/"),
    proc_root: Path = Path("/proc"),
    env: Mapping[str, str] | None = None,
    runner: Runner = run_read_only,
    which: Callable[[str], str | None] = shutil.which,
    test_pytorch: bool = False,
) -> dict[str, Any]:
    env = env if env is not None else os.environ
    process = scan_jupyter_processes(proc_root)
    managed_venv = platform_root / "jupyter-venv" / "bin"
    jupyter_executable = sanitize_diagnostic_path(which("jupyter") or (str(managed_venv / "jupyter") if (managed_venv / "jupyter").is_file() else None))
    lab_executable = sanitize_diagnostic_path(which("jupyter-lab") or (str(managed_venv / "jupyter-lab") if (managed_venv / "jupyter-lab").is_file() else None))
    jupyter_detected = bool(jupyter_executable or lab_executable or process["running"])

    cgroup = _read_text(proc_root / "1" / "cgroup")
    pid1 = _read_text(proc_root / "1" / "comm", 256).strip()
    container_detected = bool(
        (filesystem_root / ".dockerenv").exists()
        or (filesystem_root / "run" / ".containerenv").exists()
        or re.search(r"docker|containerd|kubepods|podman|lxc", cgroup, re.I)
    )
    virt_status, virtualization = runner(["systemd-detect-virt"], 5)
    virtualization = virtualization.splitlines()[0].strip().lower() if virt_status == 0 and virtualization else None
    image = _image_from_environment(env)
    provider_hint = _marketplace_from_environment(env)
    hostname = socket.gethostname()
    vast_marker = any(
        path.exists()
        for path in (
            filesystem_root / "etc" / "vastai",
            filesystem_root / "opt" / "vastai",
            filesystem_root / "root" / ".vastai",
        )
    )
    environment_type, provider = classify_environment(
        container_detected=container_detected,
        virtualization=virtualization,
        image=image,
        provider_hint=provider_hint,
        hostname=hostname,
        vast_marker=vast_marker,
        jupyter_detected=jupyter_detected,
    )

    marker = platform_root / "state" / "jupyter-managed.json"
    if marker.is_file() and (managed_venv / "jupyter-lab").is_file():
        management = "AI_PLATFORM_MANAGED"
    elif jupyter_detected and environment_type in {"VAST_AI_CONTAINER", "OTHER_MARKETPLACE_CONTAINER"}:
        management = "PROVIDER_MANAGED"
    elif jupyter_detected:
        management = "EXTERNAL_MANAGED"
    else:
        management = "NONE"
    action = "PRESERVE_AND_REUSE" if management in {"PROVIDER_MANAGED", "EXTERNAL_MANAGED"} else "MANAGE_ISOLATED_ENVIRONMENT" if management == "AI_PLATFORM_MANAGED" else "OPTIONAL_NOT_INSTALLED"

    homes = []
    for username in process["users"]:
        try:
            if pwd:
                homes.append(Path(pwd.getpwnam(username).pw_dir))
        except KeyError:
            pass
    if not homes:
        homes.append(Path.home())

    listeners = _listener_rows(runner, proc_root)
    declared_ports = set(process["declared_ports"])
    jupyter_listeners = [
        {**row, "scope": _scope_for_address(str(row["address"]))}
        for row in listeners
        if row["port"] in declared_ports
    ]

    docker_cli = bool(which("docker"))
    docker_status, docker_version = runner(["docker", "version", "--format", "{{.Server.Version}}"], 5) if docker_cli else (127, "")
    cap_sys_admin = _cap_sys_admin(proc_root)
    systemd_available = pid1 == "systemd" and (filesystem_root / "run" / "systemd" / "system").exists() and bool(which("systemctl"))
    root_privileges = bool(hasattr(os, "geteuid") and os.geteuid() == 0)
    jupyter_python, python_source = _jupyter_python(process, managed_venv, which)
    torch_installed = _pytorch_available(jupyter_python, runner)
    pytorch = (
        probe_pytorch_gpu(jupyter_python, runner)
        if test_pytorch and torch_installed
        else {"available": torch_installed, "gpu_status": "NOT_TESTED", "cuda_available": None, "device_count": None}
    )
    cuda = _nvidia_snapshot(runner)
    python_status, python_version = runner([jupyter_python, "--version"], 5)
    if python_status != 0:
        python_version = platform.python_version()
    version_match = re.match(r"^(\d+)\.(\d+)", python_version.removeprefix("Python ").strip())
    python_tuple = tuple(int(value) for value in version_match.groups()) if version_match else (0, 0)
    native_python_compatible = (3, 10) <= python_tuple < (3, 15)
    native_vllm_executable = platform_root / "native" / "vllm-venv" / "bin" / "vllm"

    provider_access = (
        "Use the Vast.ai provider UI / Open button; external URL and credentials are not inferred."
        if provider == "Vast.ai"
        else "Use the provider-managed access method; no external URL is inferred."
        if management == "PROVIDER_MANAGED"
        else "No provider-managed access method detected."
    )
    host_features_allowed = environment_type in {"FULL_VM", "BARE_METAL"} and root_privileges
    snapshot = {
        "schema_version": 1,
        "captured_at_unix": int(time.time()),
        "environment_type": environment_type,
        "provider": provider,
        "runtime": {
            "kind": "container" if environment_type.endswith("CONTAINER") else "host",
            "container_runtime": _container_runtime(filesystem_root, cgroup),
            "virtualization": virtualization,
            "container_detected": container_detected,
            "image": image,
            "pid1": pid1 or None,
        },
        "jupyter": {
            "detected": jupyter_detected,
            "installed": bool(jupyter_executable or lab_executable),
            "lab_available": bool(lab_executable or process["lab_running"]),
            "running": process["running"],
            "management": management,
            "action": action,
            "executable": jupyter_executable,
            "lab_executable": lab_executable,
            "process_count": process["process_count"],
            "effective_user": process["users"][0] if len(process["users"]) == 1 else None,
            "runtime_files_detected": _runtime_file_count(homes),
            "internal_listeners": jupyter_listeners,
            "provider_access": provider_access,
        },
        "python": {"executable": jupyter_python, "version": python_version.removeprefix("Python ").strip(), "source": python_source},
        "cuda": cuda,
        "gpu": {"visible": cuda["visible"], "device_count": cuda["device_count"], "devices": cuda["devices"]},
        "pytorch": pytorch,
        "network": {"listening_ports": sorted({row["port"] for row in listeners})[:256]},
        "capabilities": {
            "root_privileges": root_privileges,
            "systemd_available": systemd_available,
            "docker_cli_available": docker_cli,
            "docker_daemon_available": docker_status == 0,
            "docker_version": docker_version or None,
            "cap_sys_admin": cap_sys_admin,
            "privileged_container": bool(container_detected and cap_sys_admin),
            "host_firewall_management": host_features_allowed and bool(which("ufw") or which("nft") or which("iptables")),
            "luks_block_devices": host_features_allowed and cap_sys_admin and bool(which("cryptsetup")) and (filesystem_root / "dev" / "mapper" / "control").exists(),
        },
        "feature_compatibility": {
            "jupyter_integration": True,
            "provider_jupyter_management": management == "PROVIDER_MANAGED",
            "optional_isolated_jupyter_install": environment_type in {"FULL_VM", "BARE_METAL"} and not jupyter_detected,
            "docker_ai_platform": docker_status == 0,
            "native_ai_platform": bool(cuda["visible"] and native_python_compatible),
            "native_ai_platform_installed": native_vllm_executable.is_file(),
            "native_redis_available": bool(which("redis-server")),
            "host_systemd_actions": systemd_available and host_features_allowed,
            "host_firewall_actions": host_features_allowed and bool(which("ufw") or which("nft") or which("iptables")),
            "host_luks_actions": host_features_allowed and cap_sys_admin and bool(which("cryptsetup")),
        },
        "security": {
            "probe_mode": "READ_ONLY",
            "secrets_included": False,
            "process_arguments_included": False,
            "runtime_file_contents_read": False,
            "provider_configuration_modified": False,
            "provider_startup_modified": False,
            "platform_public_jupyter_listener_created": False,
            "provider_authentication_modified": False,
        },
    }
    return snapshot


def write_snapshot(snapshot: dict[str, Any], target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, target)


def load_environment_snapshot(path: str | Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}
