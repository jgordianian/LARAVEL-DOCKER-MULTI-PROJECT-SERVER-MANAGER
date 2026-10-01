from __future__ import annotations

from collections.abc import Iterable
from typing import Any


MODEL_CAPABILITIES = frozenset(
    {
        "general",
        "chat",
        "completions",
        "responses",
        "embeddings",
        "agentic",
        "coding",
        "reasoning",
        "tool_calling",
        "structured_outputs",
        "vision",
    }
)

CAPABILITY_ALIASES = {
    "agent": "agentic",
    "tools": "tool_calling",
    "tool-calling": "tool_calling",
}

API_ENDPOINTS = frozenset(
    {
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions",
        "/v1/embeddings",
        "/v1/responses",
    }
)

SERVICE_ACCOUNT_PURPOSES = frozenset({"general_api", "omnivis_production", "coding_agent", "custom"})


def normalize_capabilities(values: Iterable[str], *, tool_calling: bool = False) -> list[str]:
    normalized = {
        CAPABILITY_ALIASES.get(value.strip().lower().replace(" ", "_"), value.strip().lower().replace(" ", "_"))
        for value in values
        if value and value.strip()
    }
    if tool_calling:
        normalized.add("tool_calling")
    unknown = sorted(normalized - MODEL_CAPABILITIES)
    if unknown:
        raise ValueError(f"unknown model capabilities: {', '.join(unknown)}")
    return sorted(normalized)


def stored_model_capabilities(model) -> set[str]:
    """Return normalized capabilities stored on a model database row."""
    return {
        CAPABILITY_ALIASES.get(value.strip().lower().replace(" ", "_"), value.strip().lower().replace(" ", "_"))
        for value in (model.capabilities or [])
        if isinstance(value, str) and value.strip()
    }


def model_capability_profile(model, catalog: dict[str, Any] | None = None) -> dict[str, Any]:
    """Resolve reviewed capabilities for the exact pinned artifact and active runtime.

    Catalog-managed records use the current reviewed catalog only while the model ID
    and pinned revision still match. Runtime endpoint probes and tool configuration
    can remove capabilities that are not actually available.
    """
    stored = stored_model_capabilities(model)
    declared = set(stored)
    config = model.config if isinstance(getattr(model, "config", None), dict) else {}
    catalog_key = str(config.get("catalog_key") or "").strip().lower()
    status = "manual"
    catalog_version = None
    reviewed_at = None
    sources: list[str] = []

    if catalog_key:
        try:
            from .model_catalog import catalog_model, load_model_catalog

            current_catalog = catalog or load_model_catalog()
            entry = catalog_model(current_catalog, catalog_key)
            catalog_version = current_catalog.get("catalog_version")
            reviewed_at = entry.get("capabilities_reviewed_at") or current_catalog.get("capabilities_reviewed_at")
            sources = [*entry.get("capability_sources", []), *current_catalog.get("runtime_capability_sources", [])]
            if entry["model_id"] == model.hf_model_id and entry["revision"] == model.revision:
                declared = set(entry["capabilities"])
                status = "reviewed"
            else:
                status = "revision_mismatch"
        except (ImportError, KeyError, TypeError, ValueError):
            status = "catalog_unavailable"

    effective = set(declared)
    unavailable: set[str] = set()
    if "tool_calling" in effective and not (
        bool(getattr(model, "tool_calling", False)) and str(getattr(model, "tool_call_parser", "") or "").strip()
    ):
        effective.discard("tool_calling")
        unavailable.add("tool_calling")

    runtime_support = config.get("runtime_api_support")
    runtime_verified = isinstance(runtime_support, dict) and runtime_support.get("verified") is True
    if runtime_verified:
        endpoints = set(runtime_support.get("endpoints") or [])
        endpoint_capabilities = {
            "chat": "/v1/chat/completions",
            "completions": "/v1/completions",
            "responses": "/v1/responses",
            "embeddings": "/v1/embeddings",
        }
        for capability, endpoint in endpoint_capabilities.items():
            if capability in effective and endpoint not in endpoints:
                effective.discard(capability)
                unavailable.add(capability)

    return {
        "status": status,
        "capabilities": sorted(effective),
        "declared_capabilities": sorted(declared),
        "unavailable_capabilities": sorted(unavailable),
        "catalog_key": catalog_key or None,
        "catalog_version": catalog_version,
        "reviewed_at": reviewed_at,
        "sources": list(dict.fromkeys(sources)),
        "runtime_verified": runtime_verified,
    }


def model_capabilities(model) -> set[str]:
    """Return the reviewed capabilities that are actually available."""
    return set(model_capability_profile(model)["capabilities"])


def normalize_endpoints(values: Iterable[str]) -> list[str]:
    normalized = set()
    for value in values:
        endpoint = value.strip()
        if not endpoint:
            continue
        if not endpoint.startswith("/"):
            endpoint = f"/v1/{endpoint.removeprefix('v1/')}"
        normalized.add(endpoint.rstrip("/") or "/")
    unknown = sorted(normalized - API_ENDPOINTS)
    if unknown:
        raise ValueError(f"unsupported API endpoints: {', '.join(unknown)}")
    return sorted(normalized)


def validate_service_account_purpose(value: str) -> str:
    purpose = value.strip().lower().replace(" ", "_") or "general_api"
    if purpose not in SERVICE_ACCOUNT_PURPOSES:
        raise ValueError("invalid service-account purpose")
    return purpose
