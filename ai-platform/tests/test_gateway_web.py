from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import tomllib
from html import unescape
from pathlib import Path
from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import gateway, web
from app.config import get_settings
from app.models import APIKey, AuditLog, Conversation, IPRule, ModelInstance, ModelRecord, PasswordResetToken, ServiceAccount, SystemSetting, UsageRecord, User, WebSession
from app.security import create_web_session, generate_api_key, hash_password, verify_password


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


def test_codex_installer_requires_coding_policy_and_generates_each_platform(db, tmp_path):
    owner = User(
        name="Codex Owner",
        email="codex-owner@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3-14B-AWQ",
        alias="omnivis-coder",
        revision="stable-revision",
        download_status="downloaded",
        capabilities=["chat", "coding", "agentic", "reasoning", "responses"],
        max_model_len=32_768,
        tool_calling=True,
        tool_call_parser="qwen3_coder",
        is_default=True,
    )
    model.instance = ModelInstance(
        container_name="vllm-omnivis-coder",
        internal_url="http://vllm-omnivis-coder:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    raw, key_id, prefix, secret_hash = generate_api_key(get_settings())
    db.add_all([owner, model])
    db.flush()
    key = APIKey(
        name="Codex installer",
        key_id=key_id,
        key_prefix=prefix,
        secret_hash=secret_hash,
        user_id=owner.id,
        allowed_models=[model.alias],
        scopes=["models", "responses", "tools", "coding"],
        allowed_endpoints=["/v1/models", "/v1/responses"],
    )
    db.add(key)
    db.commit()
    client = TestClient(gateway.app)
    headers = {"Authorization": f"Bearer {raw}"}

    missing = client.get("/v1/codex/install?platform=windows")
    assert missing.status_code == 401
    invalid = client.get("/v1/codex/install?platform=android", headers=headers)
    assert invalid.status_code == 400
    assert invalid.json()["error"]["type"] == "invalid_platform"

    windows = client.get("/v1/codex/install?platform=windows", headers=headers)
    assert windows.status_code == 200
    assert windows.headers["content-disposition"] == 'attachment; filename="omnivis-codex-setup.ps1"'
    assert "$env:OMNIVIS_CODING_API_KEY" in windows.text
    assert raw not in windows.text
    payloads = re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", windows.text)
    assert len(payloads) == 2
    config_text = base64.b64decode(payloads[0]).decode().replace("__CODEX_CATALOG_PATH__", "C:/Users/Test/.codex/omnivis-models.json").replace("__CODEX_TOKEN_PATH__", "C:/Users/Test/.codex/omnivis-api-key")
    parsed_config = tomllib.loads(config_text)
    assert parsed_config["model"] == "omnivis-coder"
    assert parsed_config["model_provider"] == "omnivis_gateway"
    assert parsed_config["model_context_window"] == 32_768
    assert parsed_config["model_providers"]["omnivis_gateway"]["base_url"] == "http://testserver/v1"
    assert parsed_config["model_providers"]["omnivis_gateway"]["wire_api"] == "responses"
    assert parsed_config["model_providers"]["omnivis_gateway"]["auth"]["command"] == "powershell.exe"
    catalog = json.loads(base64.b64decode(payloads[1]))
    assert catalog["models"][0]["slug"] == "omnivis-coder"
    assert catalog["models"][0]["supported_reasoning_levels"][-1]["effort"] == "high"

    linux = client.get("/v1/codex/install?platform=linux", headers=headers)
    macos = client.get("/v1/codex/install?platform=macos", headers=headers)
    assert linux.status_code == macos.status_code == 200
    assert "base64 -d" in linux.text
    assert "base64 -D" in macos.text
    assert linux.headers["content-disposition"] == 'attachment; filename="omnivis-codex-setup.sh"'
    codex_home = tmp_path / "codex-home"
    environment = os.environ.copy()
    environment.update(OMNIVIS_CODING_API_KEY=raw, CODEX_HOME=str(codex_home))
    installed = subprocess.run(["sh"], input=linux.text, text=True, capture_output=True, env=environment, check=False)
    assert installed.returncode == 0, installed.stderr
    assert "installed successfully" in installed.stdout
    installed_config = tomllib.loads((codex_home / "config.toml").read_text())
    assert installed_config["model"] == "omnivis-coder"
    assert installed_config["model_providers"]["omnivis_gateway"]["auth"]["command"] == "sh"
    assert json.loads((codex_home / "omnivis-models.json").read_text())["models"][0]["slug"] == "omnivis-coder"
    assert (codex_home / "omnivis-api-key").read_text().strip() == raw

    key.scopes = ["models", "responses", "tools"]
    db.commit()
    denied = client.get("/v1/codex/install?platform=linux", headers=headers)
    assert denied.status_code == 403
    assert denied.json()["error"]["type"] == "codex_configuration_unavailable"


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


def test_reasoning_preference_is_persisted_and_sent_to_gateway(db, monkeypatch):
    user = User(name="Reasoning User", email="reasoning@example.com", password_hash=hash_password("GoodPassword!123"))
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3-14B-AWQ",
        alias="reasoning-model",
        download_status="downloaded",
        capabilities=["chat", "reasoning"],
        is_default=True,
    )
    model.instance = ModelInstance(
        container_name="vllm-reasoning-model",
        internal_url="http://127.0.0.1:19000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    db.add_all([user, model])
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "test")
    db.commit()

    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["payload"] = json.loads(request.content)
        event = {"choices": [{"delta": {"content": "done"}}]}
        return httpx.Response(200, content=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode())

    monkeypatch.setattr(
        web.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    preference = client.post(
        "/api/preferences/reasoning",
        json={"reasoning_effort": "high", "csrf_token": session.csrf_token},
    )
    assert preference.status_code == 200
    db.refresh(user)
    assert user.reasoning_effort == "high"

    created = client.post(
        "/api/conversations",
        json={"model": model.alias, "csrf_token": session.csrf_token},
    ).json()
    response = client.post(
        "/api/chat",
        json={
            "conversation_id": created["id"],
            "content": "think",
            "reasoning_effort": "high",
            "csrf_token": session.csrf_token,
        },
    )
    assert response.status_code == 200
    assert captured["payload"]["reasoning_effort"] == "high"
    page = client.get("/")
    assert 'id="reasoning-select"' in page.text
    assert '<option value="high" selected' in page.text
    assert 'data-saved-value="high"' in page.text
    assert 'src="/static/chat.js?v=1.2.0-reasoning2"' in page.text


def test_global_and_per_user_language_preferences(db):
    user = User(name="Localized User", email="localized@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add_all([user, SystemSetting(key="system_language", value="es", secret=False)])
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    inherited = client.get("/")
    assert inherited.status_code == 200
    assert '<html lang="es">' in inherited.text
    assert 'src="/static/i18n.js?v=1.2.0-codex7"' in inherited.text
    assert 'class="language-menu"' in inherited.text
    assert '<span class="language-current">System</span>' in inherited.text
    assert 'name="preferred_language" value="" class="selected" aria-current="true"' in inherited.text
    assert '<select name="preferred_language"' not in inherited.text
    translations = client.get("/static/i18n.js")
    assert translations.status_code == 200
    assert "'Settings': 'Configuración'" in translations.text
    assert "'Localization': 'Localización'" in translations.text
    assert "languageForm.requestSubmit()" not in translations.text

    changed = client.post(
        "/profile/language",
        data={"preferred_language": "en", "return_path": "/", "csrf_token": session.csrf_token},
        follow_redirects=False,
    )
    assert changed.status_code == 303
    db.refresh(user)
    assert user.preferred_language == "en"
    explicit = client.get("/")
    assert '<html lang="en">' in explicit.text
    assert '<span class="language-current">English</span>' in explicit.text
    assert 'name="preferred_language" value="en" class="selected" aria-current="true"' in explicit.text


def test_user_can_manage_profile_and_email_change_is_reauthenticated(db):
    user = User(name="Original Name", email="profile@example.com", password_hash=hash_password("GoodPassword!123"))
    existing = User(name="Existing", email="existing@example.com", password_hash=hash_password("GoodPassword!123"))
    model = ModelRecord(
        hf_model_id="org/profile-model",
        alias="profile-model",
        download_status="downloaded",
        capabilities=["chat", "reasoning"],
    )
    model.instance = ModelInstance(
        container_name="vllm-profile-model",
        internal_url="http://vllm-profile-model:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    db.add_all([user, existing, model])
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "current")
    _, other_session = create_web_session(db, user, "127.0.0.1", "other")
    current_session_id = session.id
    other_session_id = other_session.id
    db.commit()

    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    page = client.get("/profile")
    assert page.status_code == 200
    assert 'action="/profile"' in page.text
    assert 'name="name" value="Original Name"' in page.text
    assert 'name="email" type="email" value="profile@example.com"' in page.text
    assert 'action="/profile/password"' in page.text

    common = {
        "name": "Updated Name",
        "preferred_language": "es",
        "default_model_alias": "profile-model",
        "reasoning_effort": "high",
        "system_prompt": "Be concise and precise.",
        "csrf_token": session.csrf_token,
    }
    duplicate = client.post(
        "/profile",
        data={**common, "email": existing.email, "current_password": "GoodPassword!123"},
    )
    assert duplicate.status_code == 200
    assert "Email already exists." in duplicate.text

    wrong_password = client.post(
        "/profile",
        data={**common, "email": "updated@example.com", "current_password": "wrong"},
    )
    assert wrong_password.status_code == 200
    assert "Current password is required to change your email address." in wrong_password.text

    changed = client.post(
        "/profile",
        data={**common, "email": "UPDATED@example.com", "current_password": "GoodPassword!123"},
        follow_redirects=False,
    )
    assert changed.status_code == 303
    assert changed.headers["location"] == "/profile?result=saved"
    db.expire_all()
    updated = db.get(User, user.id)
    assert updated.name == "Updated Name"
    assert updated.email == "updated@example.com"
    assert updated.preferred_language == "es"
    assert updated.default_model_alias == "profile-model"
    assert updated.reasoning_effort == "high"
    assert updated.system_prompt == "Be concise and precise."
    assert db.get(WebSession, current_session_id) is not None
    assert db.get(WebSession, other_session_id) is None
    event = db.scalar(select(AuditLog).where(AuditLog.action == "user.profile_changed"))
    assert event is not None
    assert event.after["other_sessions_terminated"] is True


def test_api_key_page_builds_codex_setup_command_without_revealing_stored_secrets(db):
    admin = User(
        name="Codex Admin",
        email="codex-admin@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    account = ServiceAccount(
        name="VS Code Codex",
        purpose="coding_agent",
        allowed_models=["omnivis-coder"],
        allowed_scopes=["models", "responses", "tools", "coding"],
        allowed_endpoints=["/v1/models", "/v1/responses"],
    )
    db.add_all([admin, account])
    db.flush()
    raw_session, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw_session)

    created = client.post(
        "/admin/api-keys",
        data={
            "name": "VS Code workstation",
            "owner_type": "service_account",
            "owner_id": str(account.id),
            "allowed_models": "omnivis-coder",
            "scopes": "models,responses,tools,coding",
            "allowed_endpoints": "/v1/models,/v1/responses",
            "csrf_token": session.csrf_token,
        },
    )
    assert created.status_code == 200
    key = db.query(APIKey).one()
    secret = re.search(r'<code id="created-secret-value">([^<]+)</code>', created.text).group(1)
    assert secret.startswith("ovai_live_")
    assert created.text.count(secret) == 1
    assert f'data-created-key-id="{key.id}"' in created.text
    assert f'data-key-id="{key.id}"' in created.text
    assert 'id="codex-setup-dialog"' in created.text
    assert 'data-installer-url="http://testserver/v1/codex/install"' in created.text
    assert 'src="/static/codex-setup.js?v=1.2.0-codex7"' in created.text

    later = client.get("/admin/api-keys")
    assert later.status_code == 200
    assert secret not in later.text
    assert "Configure Codex" in later.text

    rotated = client.post(
        f"/admin/api-keys/{key.id}/rotate",
        data={"csrf_token": session.csrf_token},
    )
    rotated_secret = re.search(r'<code id="created-secret-value">([^<]+)</code>', rotated.text).group(1)
    assert rotated_secret != secret
    assert rotated.text.count(rotated_secret) == 1
    assert f'data-created-key-id="{key.id}"' in rotated.text


def test_spanish_dictionary_covers_every_static_admin_literal():
    platform_root = Path(__file__).resolve().parents[1]
    translations = (platform_root / "app" / "static" / "i18n.js").read_text(encoding="utf-8")
    keys = {
        match.group(1).replace("\\'", "'")
        for match in re.finditer(r"^\s*'((?:\\.|[^'])+)':", translations, re.MULTILINE)
    }
    missing: list[str] = []
    literal_pattern = re.compile(r'>([^<>{}]+)<|(?:placeholder|title|aria-label)="([^"{}]+)"')
    for template in sorted((platform_root / "app" / "templates").glob("*.html")):
        source = template.read_text(encoding="utf-8")
        for match in literal_pattern.finditer(source):
            literal = match.group(1) or match.group(2)
            literal = unescape(" ".join(literal.split()))
            if re.search(r"[A-Za-z]", literal) and literal not in keys:
                missing.append(f"{template.name}: {literal}")
    assert not missing, "Spanish translations missing:\n" + "\n".join(missing)

    dynamic_literals = {
        "Active", "Revoked", "No expiry", "Inherited/all", "Inherited/legacy",
        "Running", "Detected", "Not detected", "AVAILABLE", "NOT AVAILABLE",
        "NOT DETECTED", "NOT TESTED", "UNKNOWN", "YES", "NO", "SAFE", "BLOCKED",
        "downloaded", "ready", "inactive", "not configured", "not calculated",
        "AUTO", "CONSERVATIVE", "BALANCED", "PERFORMANCE", "MAXIMUM", "CUSTOM",
        "Disable and end sessions", "enabled", "disabled", "success", "failure",
        "settings.branding_changed", "settings.localization_changed", "settings.smtp_changed",
        "user.language_changed", "user.profile_changed", "user.login", "user.logout", "user.created", "user.updated",
        "service_account.created", "service_account.policy_changed", "api_key.created",
        "api_key.revoked", "api_key.rotated", "model.registered", "model.activate",
        "model.deactivate", "model.restart", "model.default_changed",
        "model.configuration_changed", "performance.changed", "ip_rule.created", "ip_rule.deleted",
    }
    assert dynamic_literals <= keys
    for dynamic_fragment in ("cores", "GB used", "Last used", "last login", "requests", "system_setting"):
        assert dynamic_fragment in translations


def test_admin_can_change_global_localization(db):
    admin = User(name="Locale Admin", email="locale-admin@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    response = client.post(
        "/admin/settings/localization",
        data={"system_language": "es", "csrf_token": session.csrf_token},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["location"] == "/admin/settings?result=localization-saved"
    setting = db.get(SystemSetting, "system_language")
    assert setting.value == "es"
    page = client.get("/admin/settings")
    assert '<html lang="es">' in page.text
    assert "Localization" in page.text


def test_smtp_password_reset_uses_single_use_hashed_token(db, monkeypatch):
    user = User(name="Reset User", email="reset-mail@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add(user)
    for key, value, secret in (
        ("smtp_enabled", True, False),
        ("smtp_host", "smtp.example.com", False),
        ("smtp_port", 587, False),
        ("smtp_security", "starttls", False),
        ("smtp_username", "mailer", False),
        ("smtp_password", "smtp-secret", True),
        ("smtp_from_email", "no-reply@example.com", False),
        ("smtp_from_name", "Example AI", False),
        ("system_language", "es", False),
    ):
        db.add(SystemSetting(key=key, value=value, secret=secret))
    db.commit()

    delivered = {}

    def capture_email(configuration, recipient, subject, text_body):
        delivered.update(recipient=recipient, subject=subject, body=text_body)

    monkeypatch.setattr(web, "send_email", capture_email)
    client = TestClient(web.app)
    request_page = client.get("/forgot-password")
    csrf = request_page.cookies["ai_reset_csrf"]
    requested = client.post(
        "/forgot-password",
        data={"email": user.email, "csrf_token": csrf},
    )
    assert requested.status_code == 200
    assert "If that address belongs" in requested.text
    assert delivered["recipient"] == user.email
    assert delivered["subject"].startswith("Restablece tu contraseña")
    assert "Se solicitó restablecer" in delivered["body"]
    assert "smtp-secret" not in delivered["body"]
    token = re.search(r"token=([^\s]+)", delivered["body"]).group(1)
    stored = db.query(PasswordResetToken).one()
    assert stored.token_hash != token

    reset_page = client.get(f"/reset-password?token={token}")
    reset_csrf = reset_page.cookies["ai_reset_csrf"]
    completed = client.post(
        "/reset-password",
        data={
            "token": token,
            "new_password": "ChangedPassword!456",
            "confirm_password": "ChangedPassword!456",
            "csrf_token": reset_csrf,
        },
        follow_redirects=False,
    )
    assert completed.status_code == 303
    assert completed.headers["location"] == "/login?reset=1"
    db.refresh(user)
    db.refresh(stored)
    assert verify_password(user.password_hash, "ChangedPassword!456")
    assert stored.used_at is not None
    assert client.get(f"/reset-password?token={token}").status_code == 200


def test_admin_can_configure_branding_and_smtp_secret_is_not_rendered(db):
    admin = User(name="Brand Admin", email="brand-admin@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    branding = client.post(
        "/admin/settings/branding",
        data={
            "brand_name": "Omnivis AI",
            "browser_title": "Omnivis Intelligence",
            "footer_text": "Omnivis AI © 2026",
            "csrf_token": session.csrf_token,
        },
        files={
            "logo_dark": ("logo-dark.png", b"\x89PNG\r\n\x1a\ndark-logo", "image/png"),
            "favicon": ("favicon.png", b"\x89PNG\r\n\x1a\nimage", "image/png"),
        },
        follow_redirects=False,
    )
    assert branding.status_code == 303
    smtp = client.post(
        "/admin/settings/smtp",
        data={
            "smtp_enabled": "true",
            "smtp_host": "smtp.example.com",
            "smtp_port": "587",
            "smtp_security": "starttls",
            "smtp_username": "mailer",
            "smtp_password": "never-render-this-secret",
            "smtp_from_email": "no-reply@example.com",
            "smtp_from_name": "Omnivis AI",
            "action": "save",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert smtp.status_code == 303
    page = client.get("/admin/settings")
    assert "Omnivis AI" in page.text
    assert "Omnivis Intelligence" in page.text
    assert "never-render-this-secret" not in page.text
    assert "documents legal" not in page.text.lower()
    login = TestClient(web.app).get("/login")
    assert "Omnivis AI" in login.text
    favicon_match = re.search(r'/branding/favicon\.png\?v=([a-f0-9]+-[a-f0-9]+)', login.text)
    assert favicon_match
    assert re.search(r'/branding/logo_dark\.png\?v=[a-f0-9]+-[a-f0-9]+', page.text)
    assert client.get("/branding/logo_dark.png").content == b"\x89PNG\r\n\x1a\ndark-logo"

    replaced = client.post(
        "/admin/settings/branding",
        data={
            "brand_name": "Omnivis AI",
            "browser_title": "Omnivis Intelligence",
            "footer_text": "Omnivis AI © 2026",
            "csrf_token": session.csrf_token,
        },
        files={"favicon": ("favicon.png", b"\x89PNG\r\n\x1a\nreplacement-image", "image/png")},
        follow_redirects=False,
    )
    assert replaced.status_code == 303
    replaced_login = TestClient(web.app).get("/login")
    replaced_match = re.search(r'/branding/favicon\.png\?v=([a-f0-9]+-[a-f0-9]+)', replaced_login.text)
    assert replaced_match
    assert replaced_match.group(1) != favicon_match.group(1)
    assert client.get("/branding/favicon.png").content == b"\x89PNG\r\n\x1a\nreplacement-image"
    password = db.get(SystemSetting, "smtp_password")
    assert password.secret is True


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
