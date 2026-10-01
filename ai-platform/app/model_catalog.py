from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

import httpx

from .capabilities import normalize_capabilities


CATALOG_SCHEMA_VERSION = 3
CATALOG_PATH = Path(__file__).resolve().parents[1] / "config" / "model-catalog.json"
CATALOG_STATE_ROOT = Path("/platform/state") if Path("/platform").is_dir() else Path(__file__).resolve().parents[1] / "state"
REFRESHED_CATALOG_PATH = CATALOG_STATE_ROOT / "model-catalog.json"
CATALOG_BACKUP_PATH = REFRESHED_CATALOG_PATH.with_name("model-catalog.previous.json")
CATALOG_UPDATE_URL = (
    "https://raw.githubusercontent.com/jgordianian/"
    "LARAVEL-DOCKER-MULTI-PROJECT-SERVER-MANAGER/main/ai-platform/config/model-catalog.json"
)
MAX_CATALOG_BYTES = 1024 * 1024


class ModelCatalogError(ValueError):
    pass


def _version_key(value: Any) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", str(value)))


def _freshness_key(catalog: dict[str, Any]) -> tuple[str, tuple[int, ...]]:
    reviewed_at = str(catalog.get("capabilities_reviewed_at") or catalog.get("updated_at") or "")
    return reviewed_at, _version_key(catalog.get("catalog_version"))


def _load_catalog_file(source: Path) -> dict[str, Any]:
    try:
        catalog = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelCatalogError("the curated model catalog is unavailable or invalid") from exc
    if not isinstance(catalog, dict) or int(catalog.get("schema_version", 0)) != CATALOG_SCHEMA_VERSION:
        raise ModelCatalogError("the curated model catalog schema is unsupported")
    catalog_version = str(catalog.get("catalog_version", "")).strip()
    updated_at = str(catalog.get("updated_at", "")).strip()
    reviewed_at = str(catalog.get("capabilities_reviewed_at", "")).strip()
    runtime_sources = catalog.get("runtime_capability_sources")
    if not re.fullmatch(r"\d{4}\.\d{2}\.\d{2}(?:\.\d+)?", catalog_version):
        raise ModelCatalogError("the curated model catalog version is invalid")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated_at):
        raise ModelCatalogError("the curated model catalog update date is invalid")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", reviewed_at):
        raise ModelCatalogError("the curated model catalog capability review date is invalid")
    if not isinstance(runtime_sources, list) or not runtime_sources or any(
        not isinstance(value, str) or not value.startswith("https://") for value in runtime_sources
    ):
        raise ModelCatalogError("the curated model catalog runtime capability sources are invalid")
    models = catalog.get("models")
    if not isinstance(models, list) or not models:
        raise ModelCatalogError("the curated model catalog is empty")

    normalized_models: list[dict[str, Any]] = []
    keys: set[str] = set()
    for value in models:
        if not isinstance(value, dict):
            raise ModelCatalogError("the curated model catalog contains an invalid entry")
        item = dict(value)
        key = str(item.get("key", "")).strip().lower()
        model_id = str(item.get("model_id", "")).strip()
        revision = str(item.get("revision", "")).strip().lower()
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,95}", key) or key in keys:
            raise ModelCatalogError("the curated model catalog contains an invalid or duplicate key")
        if "/" not in model_id or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ModelCatalogError(f"catalog model {key} is not pinned to a valid repository revision")
        if item.get("release_channel") != "stable":
            raise ModelCatalogError(f"catalog model {key} is not in the stable release channel")
        try:
            model_capabilities = normalize_capabilities(item["model_capabilities"])
            runtime_capabilities = normalize_capabilities(
                item["runtime_capabilities"], tool_calling=bool(item.get("tool_calling"))
            )
            capabilities = normalize_capabilities([*model_capabilities, *runtime_capabilities])
            estimated_weight_gb = float(item["estimated_weight_gb"])
            recommended_vram_gb = float(item["recommended_vram_gb"])
            max_model_len = int(item["default_max_model_len"])
            max_num_seqs = int(item.get("max_num_seqs", 4))
            gpu_memory_utilization = float(item.get("gpu_memory_utilization", 0.82))
        except (KeyError, TypeError, ValueError) as exc:
            raise ModelCatalogError(f"catalog model {key} has invalid planning defaults") from exc
        if estimated_weight_gb <= 0 or recommended_vram_gb <= 0 or max_model_len < 256 or max_num_seqs < 1:
            raise ModelCatalogError(f"catalog model {key} has invalid resource requirements")
        if not 0.1 <= gpu_memory_utilization <= 0.95:
            raise ModelCatalogError(f"catalog model {key} has invalid GPU memory utilization")
        declared_capabilities = item.get("capabilities")
        if declared_capabilities is not None and normalize_capabilities(declared_capabilities) != capabilities:
            raise ModelCatalogError(f"catalog model {key} has inconsistent capabilities")
        capability_sources = item.get("capability_sources")
        if not isinstance(capability_sources, list) or not capability_sources or any(
            not isinstance(value, str) or not value.startswith("https://") for value in capability_sources
        ):
            raise ModelCatalogError(f"catalog model {key} has invalid capability sources")
        item_reviewed_at = str(item.get("capabilities_reviewed_at") or reviewed_at).strip()
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", item_reviewed_at):
            raise ModelCatalogError(f"catalog model {key} has an invalid capability review date")
        if set(model_capabilities).intersection(runtime_capabilities):
            raise ModelCatalogError(f"catalog model {key} duplicates model and runtime capabilities")
        if bool(item.get("tool_calling")) != ("tool_calling" in runtime_capabilities):
            raise ModelCatalogError(f"catalog model {key} has inconsistent tool-calling configuration")
        if not any(revision in value for value in capability_sources):
            raise ModelCatalogError(f"catalog model {key} capability sources are not pinned to its revision")
        item.update(
            key=key,
            model_id=model_id,
            revision=revision,
            capabilities=capabilities,
            model_capabilities=model_capabilities,
            runtime_capabilities=runtime_capabilities,
            capabilities_reviewed_at=item_reviewed_at,
            capability_sources=capability_sources,
            estimated_weight_gb=estimated_weight_gb,
            recommended_vram_gb=recommended_vram_gb,
            default_max_model_len=max_model_len,
            max_num_seqs=max_num_seqs,
            gpu_memory_utilization=gpu_memory_utilization,
            dtype=str(item.get("dtype", "auto")).strip() or "auto",
            quantization=str(item.get("quantization", "")).strip() or None,
            tool_call_parser=str(item.get("tool_call_parser", "")).strip() or None,
            reasoning_parser=str(item.get("reasoning_parser", "")).strip() or None,
            performance_profile=str(item.get("performance_profile", "AUTO")).strip().upper() or "AUTO",
        )
        keys.add(key)
        normalized_models.append(item)
    return {**catalog, "models": normalized_models}


def catalog_candidates() -> list[tuple[Path, dict[str, Any]]]:
    candidates: list[tuple[Path, dict[str, Any]]] = []
    errors: list[ModelCatalogError] = []
    for source in (CATALOG_PATH, REFRESHED_CATALOG_PATH):
        if source == REFRESHED_CATALOG_PATH and not source.is_file():
            continue
        try:
            candidates.append((source, _load_catalog_file(source)))
        except ModelCatalogError as exc:
            errors.append(exc)
    if not candidates:
        raise errors[0] if errors else ModelCatalogError("the curated model catalog is unavailable or invalid")
    return candidates


def active_model_catalog() -> tuple[Path, dict[str, Any]]:
    return max(catalog_candidates(), key=lambda value: _freshness_key(value[1]))


def load_model_catalog(path: Path | None = None) -> dict[str, Any]:
    if path is not None:
        return _load_catalog_file(path)
    return active_model_catalog()[1]


def refresh_model_catalog(
    *,
    url: str = CATALOG_UPDATE_URL,
    destination: Path | None = None,
    backup_path: Path | None = None,
) -> dict[str, Any]:
    """Atomically install a newer reviewed catalog from the canonical HTTPS source."""
    if url != CATALOG_UPDATE_URL:
        raise ModelCatalogError("the model catalog update source is not trusted")
    current_path, current = active_model_catalog()
    try:
        response = httpx.get(
            url,
            headers={"Accept": "application/json", "User-Agent": "Omnivis-AI-catalog-updater/1"},
            timeout=httpx.Timeout(15, connect=5),
            follow_redirects=False,
        )
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise ModelCatalogError("the remote stable catalog is unavailable") from exc
    body = response.content
    if not body or len(body) > MAX_CATALOG_BYTES:
        raise ModelCatalogError("the remote stable catalog has an invalid size")
    try:
        preview = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelCatalogError("the remote stable catalog is invalid") from exc
    if not isinstance(preview, dict):
        raise ModelCatalogError("the remote stable catalog is invalid")

    remote_freshness = _freshness_key(preview)
    current_freshness = _freshness_key(current)
    if remote_freshness <= current_freshness:
        return {
            "status": "current",
            "catalog_version": current.get("catalog_version"),
            "remote_version": preview.get("catalog_version"),
            "source": str(current_path),
        }
    if int(preview.get("schema_version", 0)) != CATALOG_SCHEMA_VERSION:
        raise ModelCatalogError("the newer remote catalog uses an unsupported schema")

    target = destination or REFRESHED_CATALOG_PATH
    previous = backup_path or CATALOG_BACKUP_PATH
    if target.is_symlink() or previous.is_symlink():
        raise ModelCatalogError("the model catalog update path is unsafe")
    temporary_path: Path | None = None
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(prefix=".model-catalog-", suffix=".json", dir=target.parent)
        temporary_path = Path(name)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        candidate = _load_catalog_file(temporary_path)
        if _freshness_key(candidate) <= current_freshness:
            return {
                "status": "current",
                "catalog_version": current.get("catalog_version"),
                "remote_version": candidate.get("catalog_version"),
                "source": str(current_path),
            }
        shutil.copy2(current_path, previous)
        os.chmod(previous, 0o640)
        os.chmod(temporary_path, 0o640)
        os.replace(temporary_path, target)
        temporary_path = None
        installed = _load_catalog_file(target)
    except (OSError, ModelCatalogError) as exc:
        if isinstance(exc, ModelCatalogError):
            raise
        raise ModelCatalogError("the stable catalog could not be installed safely") from exc
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return {
        "status": "updated",
        "catalog_version": installed.get("catalog_version"),
        "previous_version": current.get("catalog_version"),
        "source": str(target),
    }


def catalog_model(catalog: dict[str, Any], key: str) -> dict[str, Any]:
    normalized_key = key.strip().lower()
    for item in catalog["models"]:
        if item["key"] == normalized_key:
            return item
    raise ModelCatalogError("select a model from the curated stable catalog")
