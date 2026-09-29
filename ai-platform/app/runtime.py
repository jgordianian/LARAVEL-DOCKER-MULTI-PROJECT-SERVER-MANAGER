from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import docker
import httpx
from docker.errors import APIError, ImageNotFound, NotFound
from docker.types import DeviceRequest
from huggingface_hub import HfApi, snapshot_download
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .hardware import analyze_capacity, estimate_vram_gb, load_snapshot
from .models import AuditLog, ModelInstance, ModelRecord, utcnow


class RuntimeOperationError(Exception):
    pass


SAFE_ALIAS_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,158}$")
BLOCKED_EXTRA_FLAGS = {
    "--host", "--port", "--api-key", "--ssl-keyfile", "--ssl-certfile",
    "--model", "--revision", "--served-model-name", "--dtype", "--quantization",
    "--max-model-len", "--max-num-seqs", "--max-num-batched-tokens",
    "--gpu-memory-utilization", "--tensor-parallel-size", "--pipeline-parallel-size",
    "--cpu-offload-gb", "--swap-space", "--enable-prefix-caching", "--trust-remote-code",
    "--enable-auto-tool-choice", "--tool-call-parser", "--chat-template", "--generation-config",
}


def container_name_for(alias: str) -> str:
    safe = alias.strip().lower()
    if not SAFE_ALIAS_RE.fullmatch(safe):
        raise RuntimeOperationError("model alias must start with a letter or number and contain only letters, numbers, dots, underscores or hyphens")
    return f"vllm-ai-{safe}"[:120]


def read_hf_token(settings: Settings) -> str | None:
    try:
        token = settings.hf_token_file.read_text(encoding="utf-8").strip()
        return token or None
    except OSError:
        return None


def managed_model_root(settings: Settings) -> Path:
    if settings.ai_runtime_mode == "docker" and Path("/models").is_dir():
        return Path("/models")
    return settings.ai_platform_root / "models"


def model_storage_path(settings: Settings, model: ModelRecord) -> Path:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "--", model.hf_model_id)
    revision = re.sub(r"[^A-Za-z0-9._-]+", "-", model.revision)
    root = managed_model_root(settings)
    return root / f"{safe}@{revision}"


def remote_model_size(model_id: str, revision: str, token: str | None) -> int | None:
    info = HfApi(token=token).model_info(model_id, revision=revision, files_metadata=True)
    sizes = [getattr(sibling, "size", None) for sibling in info.siblings]
    known = [int(size) for size in sizes if size is not None]
    return sum(known) if known else None


def download_model(db: Session, model: ModelRecord, settings: Settings | None = None) -> Path:
    settings = settings or get_settings()
    target = model_storage_path(settings, model)
    token = read_hf_token(settings)
    model.download_status = "downloading"
    model.download_error = None
    db.commit()
    try:
        estimated = remote_model_size(model.hf_model_id, model.revision, token)
        # The controller sees the host model store at /models while retaining
        # the host root in settings for Docker bind-mount creation.
        free = shutil.disk_usage(target.parent).free
        reserve = settings.ai_disk_reserve_gb * 1024**3
        if estimated is not None and free - estimated < reserve:
            raise RuntimeOperationError(
                f"download requires approximately {estimated / 1024**3:.1f} GB and would breach the {settings.ai_disk_reserve_gb} GB disk reserve"
            )
        if estimated is None and free < reserve + 1024**3:
            raise RuntimeOperationError("model size is unavailable and free disk is below the configured safety threshold")
        target.mkdir(parents=True, exist_ok=True)
        snapshot_download(
            repo_id=model.hf_model_id,
            revision=model.revision,
            local_dir=target,
            token=token,
            resume_download=True,
        )
        size = sum(path.stat().st_size for path in target.rglob("*") if path.is_file())
        model.local_path = str(target)
        model.size_bytes = size
        model.estimated_weight_gb = model.estimated_weight_gb or round(size / 1024**3, 2)
        model.download_status = "downloaded"
        model.download_error = None
        db.add(AuditLog(actor_type="system", action="model.downloaded", target_type="model", target_id=str(model.id), after={"size_bytes": size}))
        db.commit()
        return target
    except Exception as exc:
        safe_error = sanitize_runtime_error(str(exc))
        model.download_status = "error"
        model.download_error = safe_error
        db.add(AuditLog(actor_type="system", action="model.download_failed", target_type="model", target_id=str(model.id), result="failure", details={"error": safe_error[:500]}))
        db.commit()
        raise RuntimeOperationError(safe_error) from None


def _load_profiles(settings: Settings) -> dict[str, dict[str, Any]]:
    path = Path("/app/config/performance-profiles.json")
    if not path.exists():
        path = Path(__file__).resolve().parents[1] / "config" / "performance-profiles.json"
    return json.loads(path.read_text(encoding="utf-8"))


def recommend_profile(profile: str, snapshot: dict[str, Any], model: ModelRecord, instance: ModelInstance) -> dict[str, Any]:
    mode = profile.upper()
    requested = mode
    profiles = _load_profiles(get_settings())
    if requested == "AUTO":
        selected_gpus = [
            gpu
            for gpu in snapshot.get("gpus", [])
            if not instance.gpu_assignment or gpu.get("index") in instance.gpu_assignment
        ]
        assigned_vram = sum(int(gpu.get("memory_total_bytes") or 0) for gpu in selected_gpus) / 1024**3
        available_vram = sum(int(gpu.get("memory_free_bytes") or gpu.get("memory_total_bytes") or 0) for gpu in selected_gpus) / 1024**3
        ram_gib = int(snapshot.get("memory", {}).get("total_bytes") or 0) / 1024**3
        cpu_cores = int(snapshot.get("cpu", {}).get("cores") or 1)
        usable_vram = min(assigned_vram, available_vram)
        requested = "CONSERVATIVE" if usable_vram < 6 else "BALANCED" if usable_vram < 16 else "PERFORMANCE"
        if ram_gib < 16 or cpu_cores < 4:
            requested = "CONSERVATIVE"
        elif requested == "PERFORMANCE" and (ram_gib < 32 or cpu_cores < 8):
            requested = "BALANCED"
    if requested == "CUSTOM":
        return {
            "profile": "CUSTOM",
            "resolved_profile": "CUSTOM",
            "gpu_memory_utilization": instance.gpu_memory_utilization,
            "max_model_len": model.max_model_len,
            "max_num_seqs": instance.max_num_seqs,
            "max_num_batched_tokens": instance.max_num_batched_tokens,
        }
    if requested not in profiles:
        raise RuntimeOperationError("unknown performance profile")
    values = dict(profiles[requested])
    values["profile"] = mode
    values["resolved_profile"] = requested
    # Profile maxima are ceilings. Existing lower administrator values remain
    # lower unless they explicitly apply a recommendation through the manager.
    values["max_model_len"] = min(int(values["max_model_len"]), max(256, model.max_model_len))
    return values


def _conflicting_active_instances(db: Session, instance: ModelInstance) -> list[ModelInstance]:
    rows = db.scalars(
        select(ModelInstance).where(
            ModelInstance.desired_active.is_(True),
            ModelInstance.id != instance.id,
        )
    ).all()
    wanted = set(instance.gpu_assignment)
    return [
        other
        for other in rows
        if not wanted or not other.gpu_assignment or wanted.intersection(other.gpu_assignment)
    ]


def _existing_allocations(db: Session, instance: ModelInstance) -> float:
    total = 0.0
    for other in _conflicting_active_instances(db, instance):
        total += _estimated_instance_vram(other)
    return total


def _estimated_instance_vram(instance: ModelInstance) -> float:
    if instance.estimated_vram_gb is not None:
        return float(instance.estimated_vram_gb)
    model = instance.model
    size_gb = float(model.estimated_weight_gb or ((model.size_bytes or 0) / 1024**3) or 9999)
    return estimate_vram_gb(size_gb, model.max_model_len, instance.max_num_seqs, model.dtype)


def compatibility_analysis(
    db: Session,
    model: ModelRecord,
    instance: ModelInstance,
    settings: Settings | None = None,
    existing_allocations_gb: float | None = None,
) -> dict[str, Any]:
    settings = settings or get_settings()
    snapshot_file = settings.ai_platform_root / "hardware" / "current.json"
    if not snapshot_file.exists():
        snapshot_file = Path("/platform/hardware/current.json")
    if not snapshot_file.exists():
        raise RuntimeOperationError("current hardware snapshot is unavailable")
    snapshot = load_snapshot(snapshot_file)
    gpus = snapshot.get("gpus", [])
    if not instance.gpu_assignment and gpus:
        # Auto chooses the GPU with the most currently free VRAM.
        best = max(gpus, key=lambda gpu: int(gpu.get("memory_free_bytes") or gpu.get("memory_total_bytes") or 0))
        instance.gpu_assignment = [int(best["index"])]
    parallel_workers = instance.tensor_parallel_size * instance.pipeline_parallel_size
    if parallel_workers != max(1, len(instance.gpu_assignment)):
        return {"safe": False, "label": "INCOMPATIBLE", "reason": "selected GPU count must equal tensor x pipeline parallel workers"}
    size_gb = float(model.estimated_weight_gb or ((model.size_bytes or 0) / 1024**3) or 9999)
    analysis = analyze_capacity(
        snapshot,
        size_gb,
        model.max_model_len,
        instance.max_num_seqs,
        instance.gpu_assignment,
        instance.gpu_memory_utilization,
        _existing_allocations(db, instance) if existing_allocations_gb is None else existing_allocations_gb,
        model.dtype,
    )
    instance.estimated_vram_gb = analysis["estimated_vram_gb"]
    return analysis


def requires_pytorch_sampler(settings: Settings, gpu_assignment: list[int]) -> bool:
    """Use vLLM's PyTorch sampler on SM 12+ until FlashInfer supports it reliably."""
    snapshot_file = settings.ai_platform_root / "hardware" / "current.json"
    if not snapshot_file.exists():
        snapshot_file = Path("/platform/hardware/current.json")
    if not snapshot_file.exists():
        return False
    try:
        snapshot = load_snapshot(snapshot_file)
    except (OSError, json.JSONDecodeError):
        return False
    selected = set(gpu_assignment)
    for gpu in snapshot.get("gpus", []):
        if selected and gpu.get("index") not in selected:
            continue
        match = re.match(r"\s*(\d+)", str(gpu.get("compute_capability") or ""))
        if match and int(match.group(1)) >= 12:
            return True
    return False


def activation_plan(
    db: Session,
    model: ModelRecord,
    instance: ModelInstance,
    settings: Settings | None = None,
) -> dict[str, Any]:
    current = compatibility_analysis(db, model, instance, settings)
    conflicts = _conflicting_active_instances(db, instance)
    alone = current if not conflicts else compatibility_analysis(db, model, instance, settings, existing_allocations_gb=0.0)
    conflict_rows = [
        {
            "id": other.model.id,
            "alias": other.model.alias,
            "status": other.status,
            "gpus": other.gpu_assignment,
            "estimated_vram_gb": _estimated_instance_vram(other),
        }
        for other in conflicts
    ]
    requires_switch = bool(not current.get("safe") and alone.get("safe") and conflict_rows)
    return {
        **current,
        "can_activate": bool(current.get("safe") or requires_switch),
        "requires_switch": requires_switch,
        "active_conflicts": conflict_rows,
        "safe_when_conflicts_stopped": bool(alone.get("safe")),
        "safe_available_after_switch_gb": alone.get("safe_available_vram_gb"),
        "estimated_required_vram_gb": current.get("estimated_vram_gb"),
    }


def _version_tuple(image: str) -> tuple[int, int, int] | None:
    tag = image.rsplit(":", 1)[-1]
    match = re.search(r"(?:^|v)(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(int(value) for value in match.groups()) if match else None


def supported_vllm_flags(settings: Settings | None = None) -> set[str]:
    settings = settings or get_settings()
    path = Path("/app/config/vllm-compatibility.json")
    if not path.exists():
        path = Path(__file__).resolve().parents[1] / "config" / "vllm-compatibility.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    supported = set(data.get("default", []))
    version_reference = f"v{settings.native_vllm_version}" if settings.ai_runtime_mode == "native" else settings.vllm_image
    version = _version_tuple(version_reference)
    if version:
        for expression, flags in data.get("versions", {}).items():
            minimum = tuple(int(value) for value in expression.removeprefix(">=").split("."))
            if version >= minimum:
                supported.update(flags)
        for expression, flags in data.get("removed", {}).items():
            minimum = tuple(int(value) for value in expression.removeprefix(">=").split("."))
            if version >= minimum:
                supported.difference_update(flags)
    return supported


def _validate_extra_args(extra_args: list[str], supported: set[str]) -> None:
    for value in extra_args:
        if not isinstance(value, str) or "\x00" in value or "\n" in value:
            raise RuntimeOperationError("invalid extra vLLM argument")
        flag = value.split("=", 1)[0]
        if flag in BLOCKED_EXTRA_FLAGS:
            raise RuntimeOperationError(f"the managed argument {flag} cannot be overridden")
        if flag.startswith("--") and flag not in supported:
            raise RuntimeOperationError(f"the vLLM flag {flag} is not enabled for the pinned image version")


def build_vllm_args(model: ModelRecord, instance: ModelInstance, settings: Settings | None = None) -> list[str]:
    supported = supported_vllm_flags(settings)
    extra_args = instance.extra_args or []
    _validate_extra_args(extra_args, supported)
    source = model.local_path or model.hf_model_id
    args = [
        "--model", source,
        "--served-model-name", model.alias,
        "--dtype", model.dtype,
        "--max-model-len", str(model.max_model_len),
        "--max-num-seqs", str(instance.max_num_seqs),
        "--gpu-memory-utilization", str(instance.gpu_memory_utilization),
        "--tensor-parallel-size", str(instance.tensor_parallel_size),
        "--pipeline-parallel-size", str(instance.pipeline_parallel_size),
    ]
    if "--generation-config" in supported:
        args += ["--generation-config", "vllm"]
    if model.revision and not model.local_path:
        args += ["--revision", model.revision]
    if model.quantization:
        args += ["--quantization", model.quantization]
    if instance.max_num_batched_tokens:
        args += ["--max-num-batched-tokens", str(instance.max_num_batched_tokens)]
    if instance.cpu_offload_gb > 0:
        args += ["--cpu-offload-gb", str(instance.cpu_offload_gb)]
    if instance.swap_space_gb > 0 and "--swap-space" in supported:
        args += ["--swap-space", str(instance.swap_space_gb)]
    if instance.enable_prefix_caching:
        args.append("--enable-prefix-caching")
    if model.trust_remote_code:
        args.append("--trust-remote-code")
    if model.tool_calling:
        if not model.tool_call_parser:
            raise RuntimeOperationError("tool calling is enabled but no compatible tool-call parser is configured")
        args += ["--enable-auto-tool-choice", "--tool-call-parser", model.tool_call_parser]
    if model.chat_template:
        args += ["--chat-template", model.chat_template]
    args.extend(extra_args)
    return args


def probe_runtime_api_support(internal_url: str) -> dict[str, Any]:
    expected = {
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions",
        "/v1/embeddings",
        "/v1/responses",
    }
    try:
        response = httpx.get(f"{internal_url}/openapi.json", timeout=5)
        response.raise_for_status()
        body = response.json()
        paths = body.get("paths", {}) if isinstance(body, dict) else {}
        if not isinstance(paths, dict):
            raise ValueError("invalid OpenAPI paths")
        return {"verified": True, "endpoints": sorted(expected.intersection(paths))}
    except (httpx.HTTPError, AttributeError, TypeError, ValueError):
        return {"verified": False, "endpoints": [], "limitation": "runtime OpenAPI probe unavailable"}


class DockerModelRuntime:
    def __init__(self, db: Session, settings: Settings | None = None, client=None):
        self.db = db
        self.settings = settings or get_settings()
        self.client = client or docker.from_env()

    def _container(self, instance: ModelInstance):
        try:
            return self.client.containers.get(instance.container_name)
        except NotFound:
            return None

    def deactivate(self, model: ModelRecord, remove: bool = True) -> dict[str, Any]:
        instance = model.instance
        if instance is None:
            return {"status": "inactive"}
        instance.desired_active = False
        instance.status = "stopping"
        self.db.commit()
        container = self._container(instance)
        if container is not None:
            try:
                container.stop(timeout=30)
                if remove:
                    container.remove()
            except APIError as exc:
                instance.status = "error"
                instance.last_error = str(exc)[:2000]
                self.db.commit()
                raise RuntimeOperationError("failed to stop the model container") from exc
        instance.status = "inactive"
        instance.ready_at = None
        instance.last_error = None
        self.db.add(AuditLog(actor_type="system", action="model.deactivated", target_type="model", target_id=str(model.id)))
        self.db.commit()
        return {"status": "inactive"}

    def activate(self, model: ModelRecord, wait_seconds: int = 600) -> dict[str, Any]:
        if model.download_status != "downloaded" and not model.local_path:
            raise RuntimeOperationError("model weights are not downloaded")
        instance = model.instance
        if instance is None:
            name = container_name_for(model.alias)
            instance = ModelInstance(model=model, container_name=name, internal_url=f"http://{name}:8000")
            self.db.add(instance)
            self.db.flush()
        analysis = activation_plan(self.db, model, instance, self.settings)
        if not analysis.get("safe"):
            instance.desired_active = False
            instance.status = "blocked"
            instance.last_error = json.dumps(analysis)
            self.db.commit()
            raise RuntimeOperationError(f"unsafe model activation blocked: {analysis}")

        self.deactivate(model)
        instance.desired_active = True
        instance.status = "starting"
        instance.last_error = None
        self.db.commit()

        root = self.settings.ai_platform_root
        volumes = {
            str(root / "models"): {"bind": "/models", "mode": "ro"},
            str(root / "hf-cache"): {"bind": "/root/.cache/huggingface", "mode": "rw"},
        }
        try:
            container = self.client.containers.run(
                self.settings.vllm_image,
                command=build_vllm_args(model, instance, self.settings),
                name=instance.container_name,
                detach=True,
                network=self.settings.ai_internal_network,
                volumes=volumes,
                ipc_mode="host",
                device_requests=[DeviceRequest(device_ids=[str(value) for value in instance.gpu_assignment], capabilities=[["gpu"]])],
                # DeviceRequest already limits and reindexes the visible GPUs.
                # Setting CUDA_VISIBLE_DEVICES to host indexes here would hide
                # an assigned nonzero GPU inside the restricted container.
                environment={
                    "VLLM_LOGGING_LEVEL": "INFO",
                    **(
                        {"VLLM_USE_FLASHINFER_SAMPLER": "0"}
                        if requires_pytorch_sampler(self.settings, instance.gpu_assignment)
                        else {}
                    ),
                },
                restart_policy={"Name": "on-failure", "MaximumRetryCount": 3},
                labels={"com.vllm-ai-platform.managed": "true", "com.vllm-ai-platform.model-id": str(model.id)},
                security_opt=["no-new-privileges:true"],
                cap_drop=["ALL"],
                log_config={"type": "json-file", "config": {"max-size": "50m", "max-file": "5"}},
            )
            try:
                self.client.networks.get("vllm-ai-egress").connect(container)
            except (NotFound, APIError):
                pass
        except (APIError, ImageNotFound) as exc:
            instance.status = "error"
            instance.last_error = str(exc)[:2000]
            self.db.commit()
            raise RuntimeOperationError("failed to create the private vLLM container") from exc

        deadline = time.monotonic() + wait_seconds
        last_error = "model readiness timeout"
        while time.monotonic() < deadline:
            container.reload()
            if container.status == "exited":
                logs = container.logs(tail=80).decode(errors="replace")
                last_error = sanitize_runtime_error(logs)
                break
            try:
                response = httpx.get(f"{instance.internal_url}/health", timeout=3)
                if response.status_code == 200:
                    instance.status = "ready"
                    instance.ready_at = utcnow()
                    instance.last_error = None
                    model.config = dict(model.config or {}) | {
                        "runtime_api_support": probe_runtime_api_support(instance.internal_url)
                    }
                    self.db.add(AuditLog(actor_type="system", action="model.activated", target_type="model", target_id=str(model.id), after=analysis))
                    self.db.commit()
                    return {"status": "ready", "analysis": analysis}
            except httpx.HTTPError:
                pass
            time.sleep(3)

        instance.status = "error"
        instance.desired_active = False
        instance.last_error = last_error[:2000]
        try:
            container.stop(timeout=10)
        except APIError:
            pass
        self.db.add(AuditLog(actor_type="system", action="model.activation_failed", target_type="model", target_id=str(model.id), result="failure", details={"error": last_error[:500]}))
        self.db.commit()
        raise RuntimeOperationError(last_error)

    def switch(self, model: ModelRecord, wait_seconds: int = 600) -> dict[str, Any]:
        if model.instance is None:
            raise RuntimeOperationError("model instance is not configured")
        plan = activation_plan(self.db, model, model.instance, self.settings)
        if not plan.get("can_activate"):
            raise RuntimeOperationError(f"unsafe model activation blocked: {plan}")
        if not plan.get("requires_switch"):
            return self.activate(model, wait_seconds=wait_seconds)

        stopped = [other.model for other in _conflicting_active_instances(self.db, model.instance)]
        for conflict in stopped:
            self.deactivate(conflict)
        self.db.add(
            AuditLog(
                actor_type="system",
                action="model.capacity_switch_started",
                target_type="model",
                target_id=str(model.id),
                details={"stopped_aliases": [conflict.alias for conflict in stopped]},
            )
        )
        self.db.commit()
        try:
            result = self.activate(model, wait_seconds=wait_seconds)
            return result | {"switched_from": [conflict.alias for conflict in stopped]}
        except RuntimeOperationError as exc:
            rollback_errors = []
            for conflict in stopped:
                try:
                    self.activate(conflict, wait_seconds=wait_seconds)
                except RuntimeOperationError as rollback_exc:
                    rollback_errors.append({"alias": conflict.alias, "error": str(rollback_exc)[:500]})
            self.db.add(
                AuditLog(
                    actor_type="system",
                    action="model.capacity_switch_failed",
                    target_type="model",
                    target_id=str(model.id),
                    result="failure",
                    details={"error": str(exc)[:500], "rollback_errors": rollback_errors},
                )
            )
            self.db.commit()
            detail = f"; rollback errors: {rollback_errors}" if rollback_errors else "; prior models restored"
            raise RuntimeOperationError(f"coding model switch failed{detail}") from exc

    def status(self, model: ModelRecord) -> dict[str, Any]:
        if model.instance is None:
            return {"status": "inactive", "healthy": False}
        instance = model.instance
        container = self._container(instance)
        if container is None:
            return {"status": instance.status, "healthy": False}
        container.reload()
        healthy = False
        if container.status == "running":
            try:
                healthy = httpx.get(f"{instance.internal_url}/health", timeout=2).status_code == 200
            except httpx.HTTPError:
                pass
        return {"status": container.status, "healthy": healthy, "instance_status": instance.status}

    def metrics(self, model: ModelRecord) -> str:
        if model.instance is None or model.instance.status != "ready" or not model.instance.desired_active:
            raise RuntimeOperationError("model is not active and ready")
        try:
            response = httpx.get(f"{model.instance.internal_url}/metrics", timeout=5)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeOperationError("model metrics are unavailable") from exc
        return response.text[:2_000_000]

    def logs(self, model: ModelRecord, tail: int = 300) -> str:
        if model.instance is None:
            raise RuntimeOperationError("model instance is not configured")
        container = self._container(model.instance)
        if container is None:
            raise RuntimeOperationError("model container is not present")
        try:
            body = container.logs(tail=max(1, min(tail, 2000))).decode(errors="replace")
        except APIError as exc:
            raise RuntimeOperationError("model logs are unavailable") from exc
        return redact_secrets(body)[-200_000:]


class NativeModelRuntime:
    """Manage loopback-only vLLM processes without Docker or systemd."""

    def __init__(
        self,
        db: Session,
        settings: Settings | None = None,
        *,
        popen=subprocess.Popen,
        sleeper=time.sleep,
    ):
        self.db = db
        self.settings = settings or get_settings()
        self.popen = popen
        self.sleeper = sleeper
        self.state_root = self.settings.ai_platform_root / "state" / "native-models"
        self.log_root = self.settings.ai_platform_root / "logs"

    def _service_account(self):
        if os.name != "posix" or not hasattr(os, "geteuid"):
            return None
        try:
            import pwd

            account = pwd.getpwnam(self.settings.native_service_user)
        except (ImportError, KeyError) as exc:
            raise RuntimeOperationError(
                f"native service user is unavailable: {self.settings.native_service_user}"
            ) from exc
        if os.geteuid() not in {0, account.pw_uid}:
            raise RuntimeOperationError(
                f"native runtime must run as root or {self.settings.native_service_user}"
            )
        return account

    @staticmethod
    def _assign_service_owner(path: Path, account) -> None:
        if account is not None and os.geteuid() == 0:
            os.chown(path, account.pw_uid, account.pw_gid)

    def _prepare_runtime_paths(self, account) -> tuple[Path, Path]:
        cache_root = self.settings.ai_platform_root / "native" / "cache"
        torch_cache = cache_root / "torchinductor"
        for path in (self.state_root, self.log_root, cache_root, torch_cache):
            path.mkdir(parents=True, exist_ok=True)
            self._assign_service_owner(path, account)
        return cache_root, torch_cache

    def _state_path(self, model: ModelRecord) -> Path:
        if model.id is None:
            raise RuntimeOperationError("model must be persisted before native activation")
        return self.state_root / f"{model.id}.json"

    def _log_path(self, model: ModelRecord) -> Path:
        return self.log_root / f"model-{container_name_for(model.alias)}.log"

    @staticmethod
    def _start_ticks(pid: int) -> str | None:
        try:
            fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").split()
            return fields[21]
        except (OSError, IndexError):
            return None

    @staticmethod
    def _cmdline(pid: int) -> str:
        try:
            return Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
        except OSError:
            return ""

    def _read_state(self, model: ModelRecord) -> dict[str, Any] | None:
        path = self._state_path(model)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(value, dict) or value.get("model_id") != model.id:
            return None
        return value

    def _state_is_running(self, state: dict[str, Any]) -> bool:
        try:
            pid = int(state["pid"])
            expected_ticks = str(state["start_ticks"])
            expected_port = int(state["port"])
        except (KeyError, TypeError, ValueError):
            return False
        if self._start_ticks(pid) != expected_ticks:
            return False
        command = self._cmdline(pid)
        return "vllm" in command and str(expected_port) in command

    def _write_state(self, model: ModelRecord, pid: int, port: int) -> dict[str, Any]:
        self.state_root.mkdir(parents=True, exist_ok=True)
        ticks = None
        for _ in range(20):
            ticks = self._start_ticks(pid)
            if ticks is not None:
                break
            self.sleeper(0.05)
        if ticks is None:
            raise RuntimeOperationError("native vLLM process did not expose a verifiable process identity")
        state = {
            "model_id": model.id,
            "alias": model.alias,
            "pid": pid,
            "port": port,
            "start_ticks": ticks,
        }
        path = self._state_path(model)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        self._assign_service_owner(temporary, self._service_account())
        temporary.replace(path)
        return state

    def _port_for(self, model: ModelRecord) -> int:
        instance = model.instance
        if instance is not None:
            parsed = urlparse(instance.internal_url or "")
            if parsed.hostname in {"127.0.0.1", "localhost"} and parsed.port:
                if self.settings.native_vllm_port_start <= parsed.port <= self.settings.native_vllm_port_end:
                    return parsed.port
        if self.settings.native_vllm_port_end < self.settings.native_vllm_port_start:
            raise RuntimeOperationError("native vLLM port range is invalid")
        used = {
            urlparse(row.internal_url).port
            for row in self.db.scalars(select(ModelInstance)).all()
            if urlparse(row.internal_url or "").hostname in {"127.0.0.1", "localhost"}
        }
        for candidate in range(self.settings.native_vllm_port_start, self.settings.native_vllm_port_end + 1):
            if candidate not in used:
                return candidate
        raise RuntimeOperationError("no native vLLM ports remain in the configured range")

    def _verified_stop(self, model: ModelRecord) -> None:
        path = self._state_path(model)
        state = self._read_state(model)
        if state is None:
            path.unlink(missing_ok=True)
            return
        if not self._state_is_running(state):
            path.unlink(missing_ok=True)
            return
        pid = int(state["pid"])
        try:
            process_group = os.getpgid(pid)
            target = -pid if process_group == pid else pid
            os.kill(target, signal.SIGTERM)
        except ProcessLookupError:
            path.unlink(missing_ok=True)
            return
        deadline = time.monotonic() + 30
        while self._state_is_running(state) and time.monotonic() < deadline:
            self.sleeper(0.25)
        if self._state_is_running(state):
            os.kill(target, signal.SIGKILL)
        path.unlink(missing_ok=True)

    def deactivate(self, model: ModelRecord, remove: bool = True) -> dict[str, Any]:
        del remove
        instance = model.instance
        if instance is None:
            return {"status": "inactive", "runtime": "native"}
        instance.desired_active = False
        instance.status = "stopping"
        self.db.commit()
        try:
            self._verified_stop(model)
        except (OSError, RuntimeOperationError) as exc:
            instance.status = "error"
            instance.last_error = sanitize_runtime_error(str(exc))
            self.db.commit()
            raise RuntimeOperationError("failed to stop the verified native model process") from exc
        instance.status = "inactive"
        instance.ready_at = None
        instance.last_error = None
        self.db.add(AuditLog(actor_type="system", action="model.deactivated", target_type="model", target_id=str(model.id)))
        self.db.commit()
        return {"status": "inactive", "runtime": "native"}

    def _command(self, model: ModelRecord, instance: ModelInstance, port: int) -> list[str]:
        executable = self.settings.native_vllm_executable
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeOperationError(f"native vLLM executable is unavailable: {executable}")
        arguments = build_vllm_args(model, instance, self.settings)
        try:
            model_index = arguments.index("--model")
            source = arguments[model_index + 1]
        except (ValueError, IndexError) as exc:
            raise RuntimeOperationError("managed vLLM model argument is unavailable") from exc
        del arguments[model_index : model_index + 2]
        return [
            str(executable), "serve", source,
            "--host", "127.0.0.1", "--port", str(port),
            *arguments,
        ]

    def activate(self, model: ModelRecord, wait_seconds: int = 600) -> dict[str, Any]:
        if model.download_status != "downloaded" and not model.local_path:
            raise RuntimeOperationError("model weights are not downloaded")
        if model.instance is None:
            model.instance = ModelInstance(
                container_name=container_name_for(model.alias),
                internal_url="",
            )
            self.db.add(model.instance)
            self.db.flush()
        instance = model.instance
        port = self._port_for(model)
        instance.container_name = container_name_for(model.alias)
        instance.internal_url = f"http://127.0.0.1:{port}"
        analysis = activation_plan(self.db, model, instance, self.settings)
        if not analysis.get("safe"):
            instance.desired_active = False
            instance.status = "blocked"
            instance.last_error = json.dumps(analysis)
            self.db.commit()
            raise RuntimeOperationError(f"unsafe model activation blocked: {analysis}")

        self.deactivate(model)
        instance.desired_active = True
        instance.status = "starting"
        instance.last_error = None
        self.db.commit()

        command = self._command(model, instance, port)
        service_account = self._service_account()
        cache_root, torch_cache = self._prepare_runtime_paths(service_account)
        environment = os.environ.copy()
        environment.update(
            {
                "CUDA_VISIBLE_DEVICES": ",".join(str(value) for value in instance.gpu_assignment),
                "HF_HOME": str(self.settings.ai_platform_root / "hf-cache"),
                "XDG_CACHE_HOME": str(cache_root),
                "VLLM_CACHE_ROOT": str(cache_root / "vllm"),
                "TORCHINDUCTOR_CACHE_DIR": str(torch_cache),
                "VLLM_LOGGING_LEVEL": "INFO",
                "PYTHONUNBUFFERED": "1",
            }
        )
        if service_account is not None:
            environment.update(
                {
                    "HOME": service_account.pw_dir,
                    "USER": service_account.pw_name,
                    "LOGNAME": service_account.pw_name,
                }
            )
        if requires_pytorch_sampler(self.settings, instance.gpu_assignment):
            environment["VLLM_USE_FLASHINFER_SAMPLER"] = "0"
        log_path = self._log_path(model)
        try:
            log_path.touch(mode=0o640, exist_ok=True)
            log_path.chmod(0o640)
            self._assign_service_owner(log_path, service_account)
            popen_identity = {}
            if service_account is not None and os.geteuid() == 0:
                popen_identity = {
                    "user": service_account.pw_uid,
                    "group": service_account.pw_gid,
                    "extra_groups": [service_account.pw_gid],
                }
            with log_path.open("ab", buffering=0) as log_file:
                process = self.popen(
                    command,
                    cwd=self.settings.ai_platform_root,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    close_fds=True,
                    **popen_identity,
                )
            state = self._write_state(model, process.pid, port)
        except (OSError, RuntimeOperationError) as exc:
            instance.status = "error"
            instance.desired_active = False
            instance.last_error = sanitize_runtime_error(str(exc))
            self.db.commit()
            raise RuntimeOperationError("failed to start the isolated native vLLM process") from exc

        deadline = time.monotonic() + wait_seconds
        last_error = "model readiness timeout"
        while time.monotonic() < deadline:
            if not self._state_is_running(state):
                last_error = sanitize_runtime_error(self.logs(model, 80))
                break
            try:
                response = httpx.get(f"{instance.internal_url}/health", timeout=3)
                if response.status_code == 200:
                    instance.status = "ready"
                    instance.ready_at = utcnow()
                    instance.last_error = None
                    model.config = dict(model.config or {}) | {
                        "runtime_api_support": probe_runtime_api_support(instance.internal_url),
                        "runtime_mode": "native",
                    }
                    self.db.add(AuditLog(actor_type="system", action="model.activated", target_type="model", target_id=str(model.id), after=analysis | {"runtime": "native"}))
                    self.db.commit()
                    return {"status": "ready", "analysis": analysis, "runtime": "native", "port": port}
            except httpx.HTTPError:
                pass
            self.sleeper(3)

        instance.status = "error"
        instance.desired_active = False
        instance.last_error = last_error[:2000]
        try:
            self._verified_stop(model)
        except OSError:
            pass
        self.db.add(AuditLog(actor_type="system", action="model.activation_failed", target_type="model", target_id=str(model.id), result="failure", details={"error": last_error[:500], "runtime": "native"}))
        self.db.commit()
        raise RuntimeOperationError(last_error)

    def switch(self, model: ModelRecord, wait_seconds: int = 600) -> dict[str, Any]:
        if model.instance is None:
            raise RuntimeOperationError("model instance is not configured")
        plan = activation_plan(self.db, model, model.instance, self.settings)
        if not plan.get("can_activate"):
            raise RuntimeOperationError(f"unsafe model activation blocked: {plan}")
        if not plan.get("requires_switch"):
            return self.activate(model, wait_seconds=wait_seconds)
        stopped = [other.model for other in _conflicting_active_instances(self.db, model.instance)]
        for conflict in stopped:
            self.deactivate(conflict)
        try:
            result = self.activate(model, wait_seconds=wait_seconds)
            return result | {"switched_from": [conflict.alias for conflict in stopped]}
        except RuntimeOperationError as exc:
            rollback_errors = []
            for conflict in stopped:
                try:
                    self.activate(conflict, wait_seconds=wait_seconds)
                except RuntimeOperationError as rollback_exc:
                    rollback_errors.append({"alias": conflict.alias, "error": str(rollback_exc)[:500]})
            detail = f"; rollback errors: {rollback_errors}" if rollback_errors else "; prior models restored"
            raise RuntimeOperationError(f"coding model switch failed{detail}") from exc

    def status(self, model: ModelRecord) -> dict[str, Any]:
        if model.instance is None:
            return {"status": "inactive", "healthy": False, "runtime": "native"}
        state = self._read_state(model)
        running = bool(state and self._state_is_running(state))
        healthy = False
        if running:
            try:
                healthy = httpx.get(f"{model.instance.internal_url}/health", timeout=2).status_code == 200
            except httpx.HTTPError:
                pass
        return {
            "status": "running" if running else model.instance.status,
            "healthy": healthy,
            "instance_status": model.instance.status,
            "runtime": "native",
            "pid": state.get("pid") if running and state else None,
        }

    def metrics(self, model: ModelRecord) -> str:
        if model.instance is None or model.instance.status != "ready" or not model.instance.desired_active:
            raise RuntimeOperationError("model is not active and ready")
        try:
            response = httpx.get(f"{model.instance.internal_url}/metrics", timeout=5)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeOperationError("model metrics are unavailable") from exc
        return response.text[:2_000_000]

    def logs(self, model: ModelRecord, tail: int = 300) -> str:
        path = self._log_path(model)
        if not path.is_file():
            raise RuntimeOperationError("native model log is not present")
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as exc:
            raise RuntimeOperationError("model logs are unavailable") from exc
        return redact_secrets("\n".join(lines[-max(1, min(tail, 2000)) :]))[-200_000:]


def ModelRuntime(db: Session, settings: Settings | None = None, client=None):
    """Select the configured backend while preserving the historical API."""

    selected = settings or get_settings()
    if selected.ai_runtime_mode == "native" and client is None:
        return NativeModelRuntime(db, selected)
    return DockerModelRuntime(db, selected, client=client)


def redact_secrets(value: str) -> str:
    return re.sub(r"(hf_[A-Za-z0-9]{20,}|ovai_live_[A-Za-z0-9_.-]+)", "[REDACTED]", value)


def sanitize_runtime_error(logs: str) -> str:
    lines = [line.strip() for line in logs.splitlines() if line.strip()]
    relevant = [line for line in lines if re.search(r"out of memory|cuda|error|exception|failed|traceback", line, re.I)]
    body = "\n".join((relevant or lines)[-15:])
    body = redact_secrets(body)
    return body[-2000:] or "model process exited before becoming ready"

