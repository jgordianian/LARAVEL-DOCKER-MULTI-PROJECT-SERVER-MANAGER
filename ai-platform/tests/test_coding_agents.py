from __future__ import annotations

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app import gateway
from app.capabilities import normalize_capabilities, normalize_endpoints
from app.config import get_settings
from app.models import APIKey, ModelInstance, ModelPermission, ModelRecord, ServiceAccount, UsageRecord, User
from app.policy import PolicyDenied, require_endpoint_access
from app.security import generate_api_key


def coding_fixture(db):
    general = ModelRecord(
        hf_model_id="org/general",
        alias="omnivis-general",
        download_status="downloaded",
        capabilities=["general", "chat"],
        estimated_weight_gb=1,
    )
    general.instance = ModelInstance(
        container_name="vllm-ai-omnivis-general",
        internal_url="http://vllm-ai-omnivis-general:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    coder = ModelRecord(
        hf_model_id="org/coder",
        alias="omnivis-coder",
        download_status="downloaded",
        capabilities=["chat", "responses", "coding", "agentic", "reasoning", "tool_calling"],
        tool_calling=True,
        tool_call_parser="hermes",
        estimated_weight_gb=1,
    )
    coder.instance = ModelInstance(
        container_name="vllm-ai-omnivis-coder",
        internal_url="http://vllm-ai-omnivis-coder:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[1],
    )
    production = ServiceAccount(
        name="Omnivis Production",
        purpose="omnivis_production",
        allowed_models=[general.alias],
        allowed_scopes=["models", "chat"],
        allowed_endpoints=["/v1/models", "/v1/chat/completions"],
    )
    development = ServiceAccount(
        name="Jonah Development",
        purpose="coding_agent",
        allowed_models=[coder.alias],
        allowed_scopes=["models", "chat", "responses", "tools", "coding"],
        allowed_endpoints=["/v1/models", "/v1/chat/completions", "/v1/responses"],
    )
    db.add_all([general, coder, production, development])
    db.flush()

    raw_keys = {}
    for name, owner, models, scopes, endpoints in (
        ("production", production, [general.alias], ["models", "chat"], production.allowed_endpoints),
        ("coding", development, [coder.alias], ["models", "chat", "responses", "tools", "coding"], development.allowed_endpoints),
    ):
        raw, key_id, prefix, secret_hash = generate_api_key(get_settings())
        db.add(
            APIKey(
                name=name,
                key_id=key_id,
                key_prefix=prefix,
                secret_hash=secret_hash,
                service_account_id=owner.id,
                allowed_models=models,
                scopes=scopes,
                allowed_endpoints=list(endpoints),
                allowed_cidrs=["198.51.100.0/24"] if name == "coding" else [],
            )
        )
        raw_keys[name] = raw
    db.commit()
    return general, coder, production, development, raw_keys


def test_coding_capability_metadata_and_endpoint_validation():
    assert normalize_capabilities(["Coding", "agent", "tools", "chat"]) == [
        "agentic", "chat", "coding", "tool_calling"
    ]
    assert normalize_endpoints(["responses", "/v1/models/"]) == ["/v1/models", "/v1/responses"]
    with pytest.raises(ValueError, match="unknown model capabilities"):
        normalize_capabilities(["pretend-capability"])
    with pytest.raises(ValueError, match="unsupported API endpoints"):
        normalize_endpoints(["/execute-shell"])


def test_super_admin_can_use_agentic_models_without_explicit_permissions(db):
    super_admin = User(
        name="Super Admin",
        email="super-admin@example.com",
        password_hash="unused-in-policy-test",
        role="super_admin",
    )
    regular_user = User(
        name="Regular User",
        email="regular-agentic@example.com",
        password_hash="unused-in-policy-test",
        role="user",
    )
    coder = ModelRecord(
        hf_model_id="org/agentic",
        alias="omnivis-agentic",
        download_status="downloaded",
        capabilities=["chat", "coding", "agentic"],
    )
    db.add_all([super_admin, regular_user, coder])
    db.flush()

    assert gateway._user_model_allowed(db, super_admin.id, coder, coding_requested=True)
    assert not gateway._user_model_allowed(db, regular_user.id, coder, coding_requested=True)

    db.add(
        ModelPermission(
            subject_type="user",
            subject_id=regular_user.id,
            model_id=coder.id,
            can_chat=True,
            can_use_tools=True,
            can_code=True,
        )
    )
    db.flush()
    assert gateway._user_model_allowed(
        db,
        regular_user.id,
        coder,
        tools_requested=True,
        coding_requested=True,
    )


def test_developer_and_production_models_are_logically_separated(db):
    _, _, production, development, keys = coding_fixture(db)
    prod = TestClient(gateway.app).get(
        "/v1/models", headers={"Authorization": f"Bearer {keys['production']}"}
    )
    coding = TestClient(gateway.app, client=("198.51.100.7", 50000)).get(
        "/v1/models", headers={"Authorization": f"Bearer {keys['coding']}"}
    )
    assert [item["id"] for item in prod.json()["data"]] == ["omnivis-general"]
    assert [item["id"] for item in coding.json()["data"]] == ["omnivis-coder"]
    assert "coding" in coding.json()["data"][0]["capabilities"]

    prod_to_coder = TestClient(gateway.app).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['production']}"},
        json={"model": "omnivis-coder", "messages": [{"role": "user", "content": "hi"}]},
    )
    coding_to_prod = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={"model": "omnivis-general", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert prod_to_coder.json()["error"]["type"] == "model_access_denied"
    assert coding_to_prod.json()["error"]["type"] == "model_access_denied"

    production.allowed_models = ["omnivis-coder"]
    prod_key = db.query(APIKey).filter(APIKey.service_account_id == production.id).one()
    prod_key.allowed_models = ["omnivis-coder"]
    db.commit()
    missing_coding_scope = TestClient(gateway.app).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['production']}"},
        json={"model": "omnivis-coder", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert missing_coding_scope.json()["error"]["type"] == "scope_denied"

    coding_key = db.query(APIKey).filter(APIKey.service_account_id == development.id).one()
    coding_key.scopes = [scope for scope in coding_key.scopes if scope != "tools"]
    db.commit()
    missing_tools_scope = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={
            "model": "omnivis-coder",
            "messages": [{"role": "user", "content": "hi"}],
            "tools": [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}}],
        },
    )
    assert missing_tools_scope.json()["error"]["type"] == "scope_denied"


def test_coding_ip_endpoint_tools_and_responses_passthrough(db, monkeypatch):
    _, _, _, development, keys = coding_fixture(db)
    blocked_ip = TestClient(gateway.app, client=("203.0.113.9", 50000)).get(
        "/v1/models", headers={"Authorization": f"Bearer {keys['coding']}"}
    )
    assert blocked_ip.status_code == 403
    assert blocked_ip.json()["error"]["type"] == "ip_access_denied"

    key = db.query(APIKey).filter(APIKey.service_account_id == development.id).one()
    key.allowed_endpoints = ["/v1/models"]
    db.commit()
    with pytest.raises(PolicyDenied) as denied:
        require_endpoint_access(key, "/v1/responses")
    assert denied.value.error_type == "endpoint_access_denied"
    key.allowed_endpoints = list(development.allowed_endpoints)
    db.commit()

    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["path"] = request.url.path
        captured["payload"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "id": "resp_test",
                "object": "response",
                "status": "completed",
                "output": [{"type": "function_call", "name": "read_file", "arguments": "{\"path\":\"README.md\"}"}],
                "usage": {"input_tokens": 10, "output_tokens": 3, "total_tokens": 13},
            },
        )

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    payload = {
        "model": "omnivis-coder",
        "input": "Inspect the repository",
        "tools": [{"type": "function", "name": "read_file", "description": "Read one file", "parameters": {"type": "object"}}],
        "tool_choice": "auto",
        "text": {"format": {"type": "json_schema", "name": "result", "schema": {"type": "object"}}},
        "max_output_tokens": 100,
    }
    response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/responses",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json=payload,
    )
    assert response.status_code == 200
    assert captured["path"] == "/v1/responses"
    assert captured["payload"]["tools"] == payload["tools"]
    assert captured["payload"]["tool_choice"] == "auto"
    assert captured["payload"]["text"] == payload["text"]
    assert "stream_options" not in captured["payload"]
    usage = db.query(UsageRecord).one()
    assert usage.service_account_id == development.id
    assert usage.endpoint == "/v1/responses"
    assert usage.total_tokens == 13


@pytest.mark.parametrize(
    ("effort", "budget"),
    [("low", 2_048), ("medium", 4_096), ("high", 8_192)],
)
def test_responses_reasoning_effort_maps_to_vllm_budget(db, monkeypatch, effort, budget):
    _, _, _, _, keys = coding_fixture(db)
    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["payload"] = json.loads(request.content)
        return httpx.Response(200, json={"id": "resp_reasoning", "output": [], "usage": {}})

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/responses",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={"model": "omnivis-coder", "input": "think", "reasoning": {"effort": effort}},
    )
    assert response.status_code == 200
    assert captured["payload"]["reasoning"]["effort"] == effort
    assert captured["payload"]["thinking_token_budget"] == budget


def test_reasoning_none_disables_thinking_without_budget(db, monkeypatch):
    _, _, _, _, keys = coding_fixture(db)
    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["payload"] = json.loads(request.content)
        return httpx.Response(200, json={"id": "resp_direct", "output": [], "usage": {}})

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/responses",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={
            "model": "omnivis-coder",
            "input": "answer directly",
            "reasoning": {"effort": "none"},
            "thinking_token_budget": 99_999,
        },
    )
    assert response.status_code == 200
    assert captured["payload"]["reasoning"]["effort"] == "none"
    assert "thinking_token_budget" not in captured["payload"]


def test_unknown_reasoning_effort_is_rejected(db):
    _, _, _, _, keys = coding_fixture(db)
    response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/responses",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={"model": "omnivis-coder", "input": "think", "reasoning": {"effort": "ultra"}},
    )
    assert response.status_code == 400
    assert response.json()["error"]["type"] == "invalid_reasoning_effort"


def test_coding_chat_streaming_and_tool_calls_are_preserved(db, monkeypatch):
    _, _, _, development, keys = coding_fixture(db)
    original_async_client = httpx.AsyncClient
    tool_call = {"id": "call_1", "type": "function", "function": {"name": "git_status", "arguments": "{}"}}
    event = {
        "choices": [{"delta": {"tool_calls": [tool_call]}}],
        "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7},
    }

    async def upstream(_request):
        return httpx.Response(
            200,
            content=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode(),
            headers={"content-type": "text/event-stream"},
        )

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={
            "model": "omnivis-coder",
            "stream": True,
            "messages": [{"role": "user", "content": "Show status"}],
            "tools": [{"type": "function", "function": {"name": "git_status", "parameters": {"type": "object"}}}],
        },
    )
    assert response.status_code == 200
    assert "git_status" in response.text
    usage = db.query(UsageRecord).one()
    assert usage.service_account_id == development.id
    assert usage.streaming is True


def test_usage_accounting_distinguishes_production_and_coding(db, monkeypatch):
    _, _, production, development, keys = coding_fixture(db)
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        if request.url.path.endswith("/responses"):
            return httpx.Response(200, json={"id": "resp_1", "output": [], "usage": {"input_tokens": 4, "output_tokens": 2, "total_tokens": 6}})
        return httpx.Response(200, json={"id": "chat_1", "choices": [], "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4}})

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    prod_response = TestClient(gateway.app).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {keys['production']}"},
        json={"model": "omnivis-general", "messages": [{"role": "user", "content": "hello"}]},
    )
    coding_response = TestClient(gateway.app, client=("198.51.100.7", 50000)).post(
        "/v1/responses",
        headers={"Authorization": f"Bearer {keys['coding']}"},
        json={"model": "omnivis-coder", "input": "hello"},
    )
    assert prod_response.status_code == 200
    assert coding_response.status_code == 200
    rows = db.query(UsageRecord).order_by(UsageRecord.model_alias).all()
    by_model = {row.model_alias: row for row in rows}
    assert by_model["omnivis-general"].service_account_id == production.id
    assert by_model["omnivis-coder"].service_account_id == development.id
    assert by_model["omnivis-general"].endpoint == "/v1/chat/completions"
    assert by_model["omnivis-coder"].endpoint == "/v1/responses"
