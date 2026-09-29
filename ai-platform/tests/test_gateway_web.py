from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient

from app import gateway, web
from app.config import get_settings
from app.models import APIKey, Conversation, IPRule, ModelInstance, ModelRecord, SystemSetting, UsageRecord, User
from app.security import create_web_session, generate_api_key, hash_password


def api_fixture(db):
    user = User(name="API User", email="api@example.com", password_hash=hash_password("GoodPassword!123"))
    model = ModelRecord(
        hf_model_id="org/model",
        alias="alpha",
        download_status="downloaded",
        capabilities=["chat", "completions"],
        estimated_weight_gb=1,
        is_default=True,
    )
    model.instance = ModelInstance(
        container_name="vllm-model-alpha",
        internal_url="http://vllm-model-alpha:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    raw, key_id, prefix, secret_hash = generate_api_key(get_settings())
    db.add_all([user, model])
    db.flush()
    key = APIKey(
        name="client",
        key_id=key_id,
        key_prefix=prefix,
        secret_hash=secret_hash,
        user_id=user.id,
        scopes=["models", "chat", "completions"],
    )
    db.add(key)
    db.commit()
    return user, model, raw


def test_models_requires_auth_and_returns_only_ready_models(db):
    _, _, raw = api_fixture(db)
    client = TestClient(gateway.app)
    missing = client.get("/v1/models")
    assert missing.status_code == 401
    assert missing.json()["error"]["type"] == "missing_api_key"
    response = client.get("/v1/models", headers={"Authorization": f"Bearer {raw}"})
    assert response.status_code == 200
    assert response.json()["data"][0]["id"] == "alpha"
    assert response.headers["x-request-id"].startswith("req_")


def test_gateway_ip_allowlist_denial(db):
    _, _, raw = api_fixture(db)
    db.add(IPRule(subject_type="global", cidr="10.0.0.0/8", description="private"))
    db.commit()
    response = TestClient(gateway.app).get("/v1/models", headers={"Authorization": f"Bearer {raw}"})
    assert response.status_code == 403
    assert response.json()["error"]["type"] == "ip_access_denied"


def test_gateway_allows_signed_forwarded_ip(db):
    _, _, raw = api_fixture(db)
    db.add(IPRule(subject_type="global", cidr="198.51.100.0/24", description="partner"))
    db.commit()
    client = TestClient(gateway.app, client=("127.0.0.1", 50000))
    response = client.get(
        "/v1/models",
        headers={
            "Authorization": f"Bearer {raw}",
            "X-AI-Proxy-Token": get_settings().proxy_shared_token,
            "X-Forwarded-For": "198.51.100.7, 127.0.0.1",
        },
    )
    assert response.status_code == 200


def test_gateway_invalid_revoked_and_expired_keys(db):
    _, _, raw = api_fixture(db)
    client = TestClient(gateway.app)
    invalid = client.get("/v1/models", headers={"Authorization": "Bearer ovai_live_invalidinvalid.invalidinvalidinvalidinvalidinvalidinvalid"})
    assert invalid.status_code == 401
    key = db.query(APIKey).one()
    key.revoked_at = datetime.now(timezone.utc)
    db.commit()
    assert client.get("/v1/models", headers={"Authorization": f"Bearer {raw}"}).json()["error"]["type"] == "revoked_api_key"
    key.revoked_at = None
    key.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    db.commit()
    assert client.get("/v1/models", headers={"Authorization": f"Bearer {raw}"}).json()["error"]["type"] == "expired_api_key"


def test_model_permission_and_unavailable_errors(db):
    _, model, raw = api_fixture(db)
    key = db.query(APIKey).one()
    key.allowed_models = ["different-model"]
    db.commit()
    denied = TestClient(gateway.app).post(
        "/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"},
        json={"model": "alpha", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert denied.status_code == 403
    assert denied.json()["error"]["type"] == "model_access_denied"
    key.allowed_models = []
    model.instance.status = "inactive"
    db.commit()
    unavailable = TestClient(gateway.app).post(
        "/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"},
        json={"model": "alpha", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["type"] == "model_unavailable"


def test_unavailable_configured_api_default_is_not_silently_substituted(db):
    _, _, raw = api_fixture(db)
    db.add(SystemSetting(key="api_default_model", value="offline-alias", secret=False))
    db.commit()
    response = TestClient(gateway.app).post(
        "/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"},
        json={"messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 503
    assert response.json()["error"]["type"] == "model_unavailable"


def test_non_streaming_chat_proxy_and_usage(db, monkeypatch):
    _, _, raw = api_fixture(db)
    original_async_client = httpx.AsyncClient

    async def upstream(_request):
        return httpx.Response(
            200,
            json={
                "id": "chatcmpl_test",
                "choices": [{"message": {"role": "assistant", "content": "hello"}}],
                "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6},
            },
        )

    transport = httpx.MockTransport(upstream)
    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=transport, timeout=kwargs.get("timeout")),
    )
    response = TestClient(gateway.app).post(
        "/v1/chat/completions",
        headers={"Authorization": f"Bearer {raw}"},
        json={"model": "alpha", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 200
    assert response.json()["choices"][0]["message"]["content"] == "hello"
    db.expire_all()
    assert db.query(UsageRecord).count() == 1


def test_streaming_proxy_records_usage_and_cleans_lease(db, monkeypatch):
    _, _, raw = api_fixture(db)
    original_async_client = httpx.AsyncClient
    event = {
        "choices": [{"delta": {"content": "hello"}}],
        "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
    }

    async def upstream(_request):
        body = f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode()
        return httpx.Response(200, content=body, headers={"content-type": "text/event-stream"})

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    response = TestClient(gateway.app).post(
        "/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"},
        json={"model": "alpha", "stream": True, "messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 200
    assert "data:" in response.text
    db.expire_all()
    assert db.query(UsageRecord).one().streaming is True


def test_unhandled_gateway_error_is_sanitized(db, monkeypatch):
    _, _, raw = api_fixture(db)
    monkeypatch.setattr(gateway.httpx, "AsyncClient", lambda **_kwargs: (_ for _ in ()).throw(RuntimeError("sensitive internal detail")))
    client = TestClient(gateway.app, raise_server_exceptions=False)
    response = client.post(
        "/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"},
        json={"model": "alpha", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 500
    assert response.json()["error"]["type"] == "internal_error"
    assert "sensitive" not in response.text


def test_login_has_csrf_no_signup_and_admin_rbac(db):
    admin = User(name="Admin", email="admin@example.com", password_hash=hash_password("GoodPassword!123"), role="administrator")
    db.add(admin)
    db.commit()
    client = TestClient(web.app)
    assert client.get("/signup").status_code == 404
    page = client.get("/login")
    token = page.cookies["ai_login_csrf"]
    denied = client.post("/login", data={"email": admin.email, "password": "GoodPassword!123", "csrf_token": "wrong"})
    assert denied.status_code == 403
    response = client.post(
        "/login",
        data={"email": admin.email, "password": "GoodPassword!123", "csrf_token": token},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert "ai_session" in response.cookies
    client.cookies.update(response.cookies)
    assert client.get("/admin").status_code == 200


def test_conversation_ownership_and_csrf(db):
    first = User(name="First", email="first@example.com", password_hash=hash_password("GoodPassword!123"))
    second = User(name="Second", email="second@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add_all([first, second])
    db.flush()
    raw, session = create_web_session(db, first, "127.0.0.1", "test")
    foreign = Conversation(user_id=second.id, model_alias="alpha", title="Private")
    own = Conversation(user_id=first.id, model_alias="alpha", title="Own")
    db.add_all([foreign, own])
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    assert client.get(f"/api/conversations/{foreign.id}").status_code == 404
    bad = client.patch(f"/api/conversations/{own.id}", json={"title": "Renamed", "csrf_token": "wrong"})
    assert bad.status_code == 403
    good = client.patch(f"/api/conversations/{own.id}", json={"title": "Renamed", "csrf_token": session.csrf_token})
    assert good.status_code == 200
    assert good.json()["title"] == "Renamed"


def test_user_cannot_access_admin_and_logout_terminates_session(db):
    user = User(name="Regular", email="regular@example.com", password_hash=hash_password("GoodPassword!123"), role="user")
    db.add(user)
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    assert client.get("/admin").status_code == 403
    response = client.post("/logout", data={"csrf_token": session.csrf_token}, follow_redirects=False)
    assert response.status_code == 303
    assert client.get("/profile/password").status_code == 401


def test_disabled_user_login_and_password_change(db):
    disabled = User(name="Disabled", email="disabled@example.com", password_hash=hash_password("GoodPassword!123"), enabled=False)
    active = User(name="Active", email="active@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add_all([disabled, active])
    db.flush()
    raw, session = create_web_session(db, active, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    login = client.get("/login")
    response = client.post("/login", data={"email": disabled.email, "password": "GoodPassword!123", "csrf_token": login.cookies["ai_login_csrf"]})
    assert response.status_code == 401
    client.cookies.set("ai_session", raw)
    changed = client.post(
        "/profile/password",
        data={"current_password": "GoodPassword!123", "new_password": "NewPassword!456", "confirm_password": "NewPassword!456", "csrf_token": session.csrf_token},
        follow_redirects=False,
    )
    assert changed.status_code == 303
    assert changed.headers["location"] == "/"
    db.refresh(active)
    assert active.force_password_reset is False
    assert client.get("/").status_code == 200


def test_forced_password_reset_blocks_platform_until_password_page(db):
    user = User(name="Reset", email="reset@example.com", password_hash=hash_password("GoodPassword!123"), role="administrator", force_password_reset=True)
    db.add(user)
    db.flush()
    raw, _ = create_web_session(db, user, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    assert client.get("/admin").status_code == 403
    assert client.get("/profile/password").status_code == 200


def test_admin_pages_render_with_server_side_authorization(db):
    admin = User(name="Admin", email="pages@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, _ = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    for path in (
        "/admin", "/admin/users", "/admin/service-accounts", "/admin/api-keys", "/admin/models",
        "/admin/performance", "/admin/jupyter", "/admin/usage", "/admin/security", "/admin/audit", "/admin/settings",
        "/admin/operations",
    ):
        response = client.get(path)
        assert response.status_code == 200, path
        assert "Administration" in response.text


def test_admin_models_renders_coding_capabilities_and_runtime_state(db):
    admin = User(name="Admin", email="coding-models@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    model = ModelRecord(
        hf_model_id="Qwen/Qwen2.5-Coder-7B-Instruct-AWQ",
        alias="omnivis-coder",
        capabilities=["chat", "responses", "coding", "agentic", "tool_calling"],
        quantization="awq",
        max_model_len=8192,
        tool_calling=True,
        tool_call_parser="hermes",
    )
    model.instance = ModelInstance(
        container_name="vllm-model-omnivis-coder",
        internal_url="http://vllm-model-omnivis-coder:8000",
        status="inactive",
    )
    db.add_all([admin, model])
    db.flush()
    raw, _ = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()

    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    response = client.get("/admin/models?capability=coding")

    assert response.status_code == 200
    assert "omnivis-coder" in response.text
    assert "Coding" in response.text
    assert "Agentic" in response.text
    assert "Configured; runtime not yet verified" in response.text


def test_model_inspection_and_active_performance_controls_render_inside_admin(db, monkeypatch):
    admin = User(name="Admin", email="inspect@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3-14B-AWQ",
        alias="omnivis-general",
        download_status="downloaded",
        capabilities=["chat", "reasoning"],
        estimated_weight_gb=9.3,
        max_model_len=8192,
    )
    model.instance = ModelInstance(
        container_name="vllm-ai-omnivis-general",
        internal_url="http://127.0.0.1:19000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
        performance_profile="AUTO",
    )
    db.add_all([admin, model])
    db.flush()
    raw, _ = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()

    original_async_client = httpx.AsyncClient

    async def upstream(request):
        if request.url.path.endswith("/compatibility"):
            return httpx.Response(
                200,
                json={
                    "safe": True,
                    "label": "SAFE",
                    "estimated_vram_gb": 11.87,
                    "assigned_vram_gb": 23.89,
                    "safe_available_vram_gb": 20.55,
                },
            )
        if request.url.path.endswith("/metrics"):
            return httpx.Response(200, text="vllm:requests_running 1\n")
        return httpx.Response(200, text="INFO model ready\n")

    monkeypatch.setattr(
        web.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    for view, expected in (
        ("compatibility", "Compatibility details"),
        ("metrics", "vllm:requests_running 1"),
        ("logs", "INFO model ready"),
    ):
        response = client.get(f"/admin/models/{model.id}/inspect/{view}")
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/html")
        assert expected in response.text
        assert "Back to models" in response.text

    performance = client.get("/admin/performance")
    assert performance.status_code == 200
    assert "The model is active." in performance.text
    assert "Deactivate to change profile" in performance.text

