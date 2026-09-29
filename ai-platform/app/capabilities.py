from __future__ import annotations

from collections.abc import Iterable


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


def model_capabilities(model) -> set[str]:
    """Return canonical capabilities without mutating legacy database rows."""
    return {
        CAPABILITY_ALIASES.get(value.strip().lower().replace(" ", "_"), value.strip().lower().replace(" ", "_"))
        for value in (model.capabilities or [])
        if isinstance(value, str) and value.strip()
    }


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
