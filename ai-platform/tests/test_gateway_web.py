from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import tomllib
from html import unescape
from pathlib import Path
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import controller, gateway, model_catalog as stable_catalog, web
from app.config import get_settings
from app.mail import EmailBranding, SMTPConfiguration, send_email, smtp_test_email
from app.codex_setup import codex_model_catalog
from app.capabilities import model_api_scopes, model_capability_profile
from app.model_catalog import load_model_catalog
from app.models import APIKey, AuditLog, Conversation, IPRule, Message, MessageAttachment, ModelInstance, ModelRecord, PasswordResetToken, ServiceAccount, SystemSetting, UsageRecord, User, WebSession
from app.policy import PolicyDenied, require_model_access
from app.security import create_web_session, generate_api_key, hash_password, verify_password


def test_send_email_adds_required_date_and_message_id_headers(monkeypatch):
    delivered = {}

    class SMTPClient:
        def __init__(self, **kwargs):
            delivered["connection"] = kwargs

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, traceback):
            return False

        def ehlo(self):
            return None

        def login(self, username, password):
            delivered["login"] = (username, password)

        def send_message(self, message):
            delivered["message"] = message
            return {}

    monkeypatch.setattr("app.mail.smtplib.SMTP_SSL", SMTPClient)
    configuration = SMTPConfiguration(
        enabled=True,
        host="mail.example.com",
        port=465,
        security="ssl",
        username="mailer",
        password="secret",
        from_email="notifications@example.com",
        from_name="Example AI",
    )

    send_email(configuration, "recipient@example.net", "SMTP test", "Delivered", "<strong>Delivered</strong>")

    message = delivered["message"]
    assert message["Date"]
    assert message["Message-ID"].endswith("@example.com>")
    assert message["From"] == "Example AI <notifications@example.com>"
    assert message["To"] == "recipient@example.net"
    assert message.is_multipart()
    assert message.get_body(preferencelist=("plain",)).get_content().strip() == "Delivered"
    assert "<strong>Delivered</strong>" in message.get_body(preferencelist=("html",)).get_content()


def test_smtp_test_email_uses_professional_branded_spanish_template():
    email = smtp_test_email(
        EmailBranding(
            brand_name="Omnivis AI",
            logo_url="https://ia.omnivis.net/branding/logo.png?v=1&size=2",
            footer_text="Omnivis AI ©2026",
        ),
        "es",
        "recipient@example.net",
    )

    assert email.subject == "Prueba SMTP de Omnivis AI"
    assert '<html lang="es">' in email.html_body
    assert 'role="presentation"' in email.html_body
    assert "Prueba SMTP exitosa" in email.html_body
    assert "Configuración verificada" in email.html_body
    assert "recipient@example.net" in email.html_body
    assert "https://ia.omnivis.net/branding/logo.png?v=1&amp;size=2" in email.html_body
    assert "mensaje automático" in email.html_body
    assert "legal" not in email.html_body.lower()


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
        scopes=["models", "responses", "reasoning", "tools", "coding"],
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
    assert catalog["models"][0]["input_modalities"] == ["text"]

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


def test_codex_catalog_advertises_images_only_for_vision_models():
    vision = ModelRecord(
        id=42,
        hf_model_id="Qwen/Qwen3-VL-8B-Instruct-FP8",
        alias="omnivis-vision",
        revision="stable",
        capabilities=["chat", "responses", "coding", "agentic", "tool_calling", "vision"],
        max_model_len=16_384,
    )
    catalog = codex_model_catalog([vision])
    assert catalog["models"][0]["input_modalities"] == ["text", "image"]


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


def test_gateway_rejects_images_for_text_models_and_accepts_valid_vision_data_urls(db, monkeypatch):
    _, model, raw = api_fixture(db)
    image = b"\x89PNG\r\n\x1a\nprivate-image"
    data_url = f"data:image/png;base64,{base64.b64encode(image).decode()}"
    payload = {
        "model": model.alias,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "Describe this image"},
            {"type": "image_url", "image_url": {"url": data_url}},
        ]}],
    }
    client = TestClient(gateway.app)
    denied = client.post("/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"}, json=payload)
    assert denied.status_code == 400
    assert denied.json()["error"]["type"] == "image_inputs_not_supported"

    model.capabilities = ["chat", "completions", "vision"]
    db.commit()
    missing_scope = client.post("/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"}, json=payload)
    assert missing_scope.status_code == 403
    assert missing_scope.json()["error"]["type"] == "scope_denied"

    key = db.query(APIKey).one()
    key.scopes = [*key.scopes, "vision"]
    db.commit()
    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["payload"] = json.loads(request.content)
        return httpx.Response(200, json={
            "choices": [{"message": {"role": "assistant", "content": "A test image"}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13},
        })

    monkeypatch.setattr(
        gateway.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    accepted = client.post("/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"}, json=payload)
    assert accepted.status_code == 200
    assert captured["payload"]["messages"][0]["content"][1]["image_url"]["url"] == data_url

    payload["messages"][0]["content"][1]["image_url"]["url"] = "https://internal.example/image.png"
    unsafe = client.post("/v1/chat/completions", headers={"Authorization": f"Bearer {raw}"}, json=payload)
    assert unsafe.status_code == 400
    assert unsafe.json()["error"]["type"] == "invalid_image_input"


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
    assert 'src="/static/chat.js?v=1.2.0-edit-resend1"' in page.text
    assert 'href="/static/chat-extra.css?v=1.2.0-mfa1"' in page.text
    assert '<footer class="chat-footer">' in page.text


def test_chat_shows_thinking_state_until_the_first_visible_token():
    platform_root = Path(__file__).resolve().parents[1]
    script = (platform_root / "app" / "static" / "chat.js").read_text(encoding="utf-8")
    styles = (platform_root / "app" / "static" / "chat-extra.css").read_text(encoding="utf-8")

    assert "showThinking(output);" in script
    assert "if (!answer) clearThinking(output);" in script
    assert "label.textContent = translate('AI is thinking');" in script
    assert "if (!answer) output.row.remove();" in script
    assert "const inlineMarkdown = value =>" in script
    assert "output.push(`<h${level}>" in script
    assert "openList('ul');" in script
    assert ".thinking-dots span" in styles
    assert "@keyframes thinking-pulse" in styles
    assert ".chat-footer { height: 42px;" in styles


def test_edit_and_resend_updates_original_message_and_discards_later_branch(db, monkeypatch):
    user = User(name="Editing User", email="editing@example.com", password_hash=hash_password("GoodPassword!123"))
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3.5-4B",
        alias="editing-model",
        download_status="downloaded",
        capabilities=["chat"],
        is_default=True,
    )
    model.instance = ModelInstance(
        container_name="vllm-editing-model",
        internal_url="http://127.0.0.1:19000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    db.add_all([user, model])
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "test")
    conversation = Conversation(user_id=user.id, model_alias=model.alias, title="Original title")
    db.add(conversation)
    db.flush()
    first_user = Message(conversation_id=conversation.id, role="user", content="Keep me")
    first_answer = Message(conversation_id=conversation.id, role="assistant", content="Kept answer")
    edited_user = Message(conversation_id=conversation.id, role="user", content="Original prompt")
    discarded_answer = Message(conversation_id=conversation.id, role="assistant", content="Discard me")
    db.add_all([first_user, first_answer, edited_user, discarded_answer])
    db.commit()

    captured = {}
    original_async_client = httpx.AsyncClient

    async def upstream(request):
        captured["payload"] = json.loads(request.content)
        event = {"choices": [{"delta": {"content": "Replacement answer"}}]}
        return httpx.Response(200, content=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode())

    monkeypatch.setattr(
        web.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    response = client.post(
        "/api/chat",
        json={
            "conversation_id": conversation.id,
            "content": "Edited prompt",
            "edit_message_id": edited_user.id,
            "reasoning_effort": "none",
            "csrf_token": session.csrf_token,
        },
    )

    assert response.status_code == 200
    assert response.headers["x-ai-user-message-id"] == str(edited_user.id)
    assert [message["content"] for message in captured["payload"]["messages"]] == [
        "Keep me",
        "Kept answer",
        "Edited prompt",
    ]
    history = client.get(f"/api/conversations/{conversation.id}").json()
    assert [message["content"] for message in history["messages"]] == [
        "Keep me",
        "Kept answer",
        "Edited prompt",
        "Replacement answer",
    ]
    assert history["messages"][2]["id"] == edited_user.id
    assert "Discard me" not in {message["content"] for message in history["messages"]}

    script = (Path(__file__).resolve().parents[1] / "app" / "static" / "chat.js").read_text(encoding="utf-8")
    assert "edit_message_id:editMessageId" in script
    assert "row.dataset.messageId" in script


def test_chat_image_decoder_accepts_20_mb_and_rejects_larger_files():
    assert web.MAX_CHAT_IMAGES == 10
    assert web.MAX_CHAT_IMAGE_BYTES == 20 * 1024 * 1024
    assert web.MAX_CHAT_IMAGE_TOTAL_BYTES == 60 * 1024 * 1024

    small_image = b"\x89PNG\r\n\x1a\nsmall"
    small_attachment = {
        "name": "small.png",
        "media_type": "image/png",
        "data_url": f"data:image/png;base64,{base64.b64encode(small_image).decode()}",
    }
    assert len(web.decode_chat_images([small_attachment] * 10)) == 10
    with pytest.raises(web.HTTPException) as count_exc_info:
        web.decode_chat_images([small_attachment] * 11)
    assert count_exc_info.value.status_code == 422
    assert "10 images" in count_exc_info.value.detail

    image = b"\x89PNG\r\n\x1a\n" + b"\0" * (web.MAX_CHAT_IMAGE_BYTES - 8)
    attachment = {
        "name": "large-screen.png",
        "media_type": "image/png",
        "data_url": f"data:image/png;base64,{base64.b64encode(image).decode()}",
    }
    decoded = web.decode_chat_images([attachment])
    assert len(decoded[0]["body"]) == 20 * 1024 * 1024

    oversized_image = image + bytes(1)
    attachment["data_url"] = f"data:image/png;base64,{base64.b64encode(oversized_image).decode()}"
    with pytest.raises(web.HTTPException) as exc_info:
        web.decode_chat_images([attachment])
    assert exc_info.value.status_code == 422
    assert "20 MB" in exc_info.value.detail


def test_portal_persists_private_images_and_sends_multimodal_content(db, monkeypatch):
    user = User(name="Vision User", email="vision@example.com", password_hash=hash_password("GoodPassword!123"))
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3-VL-8B-Instruct-FP8",
        alias="omnivis-vision",
        download_status="downloaded",
        capabilities=["chat", "reasoning", "vision"],
        is_default=True,
    )
    model.instance = ModelInstance(
        container_name="vllm-vision",
        internal_url="http://vllm-vision:8000",
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
        event = {"choices": [{"delta": {"content": "I can see it."}}]}
        return httpx.Response(200, content=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode())

    monkeypatch.setattr(
        web.httpx,
        "AsyncClient",
        lambda **kwargs: original_async_client(transport=httpx.MockTransport(upstream), timeout=kwargs.get("timeout")),
    )
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    page = client.get("/")
    assert 'data-vision="true"' in page.text
    assert 'id="image-picker"' in page.text
    assert 'src="/static/chat.js?v=1.2.0-edit-resend1"' in page.text

    conversation = client.post(
        "/api/conversations",
        json={"model": model.alias, "csrf_token": session.csrf_token},
    ).json()
    image = b"\x89PNG\r\n\x1a\nportal-private-image"
    data_url = f"data:image/png;base64,{base64.b64encode(image).decode()}"
    response = client.post(
        "/api/chat",
        json={
            "conversation_id": conversation["id"],
            "content": "Describe this",
            "attachments": [{"name": "screen.png", "media_type": "image/png", "data_url": data_url}],
            "reasoning_effort": "medium",
            "csrf_token": session.csrf_token,
        },
    )
    assert response.status_code == 200
    multimodal = captured["payload"]["messages"][0]["content"]
    assert multimodal[0] == {"type": "text", "text": "Describe this"}
    assert multimodal[1]["image_url"]["url"] == data_url

    history = client.get(f"/api/conversations/{conversation['id']}").json()
    attachment = history["messages"][0]["attachments"][0]
    assert attachment["name"] == "screen.png"
    downloaded = client.get(attachment["url"])
    assert downloaded.status_code == 200
    assert downloaded.headers["content-type"] == "image/png"
    assert downloaded.content == image
    stored = db.query(MessageAttachment).one()
    assert stored.sha256 == hashlib.sha256(image).hexdigest()

    model.capabilities = ["chat", "reasoning"]
    db.commit()
    rejected = client.post(
        "/api/chat",
        json={
            "conversation_id": conversation["id"],
            "content": "Another",
            "attachments": [{"name": "screen.png", "media_type": "image/png", "data_url": data_url}],
            "reasoning_effort": "medium",
            "csrf_token": session.csrf_token,
        },
    )
    assert rejected.status_code == 422
    assert "does not support image inputs" in rejected.json()["detail"]
    assert db.query(MessageAttachment).count() == 1


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
    assert 'src="/static/i18n.js?v=1.2.0-mfa1"' in inherited.text
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


def test_user_can_upload_serve_and_remove_private_profile_photo(db):
    user = User(name="Original Name", email="avatar@example.com", password_hash=hash_password("GoodPassword!123"))
    other = User(name="Other User", email="other-avatar@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add_all([user, other])
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "avatar-test")
    other_raw, _ = create_web_session(db, other, "127.0.0.1", "other-avatar-test")
    db.commit()

    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    page = client.get("/profile")
    assert page.status_code == 200
    assert 'class="user-menu"' in page.text
    assert 'class="user-menu-avatar"' in page.text
    assert '<span>ON</span>' in page.text
    assert 'src="/static/navigation.js?v=1.2.0-profile-avatar1"' in page.text
    assert 'src="/static/profile.js?v=1.2.0-profile-preview2"' in page.text
    profile_script = client.get("/static/profile.js").text
    assert "reader.readAsDataURL(file)" in profile_script
    assert "URL.createObjectURL" not in profile_script
    assert 'enctype="multipart/form-data"' in page.text
    assert 'name="profile_photo"' in page.text

    form = {
        "name": user.name,
        "email": user.email,
        "preferred_language": "en",
        "default_model_alias": "",
        "reasoning_effort": "medium",
        "system_prompt": "",
        "current_password": "",
        "csrf_token": session.csrf_token,
    }
    png = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    uploaded = client.post(
        "/profile",
        data=form,
        files={"profile_photo": ("avatar.png", png, "image/png")},
        follow_redirects=False,
    )
    assert uploaded.status_code == 303
    db.expire_all()
    saved_user = db.get(User, user.id)
    assert saved_user.profile_photo_key
    stored_path = web.profile_photo_path(saved_user.profile_photo_key)
    assert stored_path.read_bytes() == png

    photo = client.get("/profile/photo")
    assert photo.status_code == 200
    assert photo.content == png
    assert photo.headers["content-type"] == "image/png"
    assert photo.headers["cache-control"] == "private, no-cache"
    assert '/profile/photo?v=' in client.get("/profile").text
    saved_profile = client.get("/profile").text
    assert 'class="user-menu-avatar has-photo"' in saved_profile
    assert 'fetchpriority="high" decoding="sync"' in saved_profile
    assert 'class="profile-avatar profile-avatar-large has-photo"' in saved_profile

    other_client = TestClient(web.app)
    other_client.cookies.set("ai_session", other_raw)
    assert other_client.get("/profile/photo").status_code == 404

    removed = client.post(
        "/profile",
        data={**form, "remove_profile_photo": "true"},
        follow_redirects=False,
    )
    assert removed.status_code == 303
    db.expire_all()
    assert db.get(User, user.id).profile_photo_key is None
    assert not stored_path.exists()
    assert client.get("/profile/photo").status_code == 404

    invalid = client.post(
        "/profile",
        data=form,
        files={"profile_photo": ("avatar.png", b"not-an-image", "image/png")},
    )
    assert invalid.status_code == 200
    assert "does not match its PNG, JPEG or WebP type" in invalid.text


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
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3-Coder",
        alias="omnivis-coder",
        download_status="downloaded",
        capabilities=["chat", "coding", "agentic", "reasoning", "responses", "tool_calling"],
        tool_calling=True,
        tool_call_parser="qwen3_coder",
    )
    model.instance = ModelInstance(
        container_name="vllm-omnivis-coder",
        internal_url="http://vllm-omnivis-coder:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    db.add_all([admin, account, model])
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


def test_service_and_api_policy_selectors_default_to_inheritance(db):
    admin = User(
        name="Policy Admin",
        email="policy-admin@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    chat_model = ModelRecord(
        hf_model_id="org/active-chat",
        alias="active-chat",
        download_status="downloaded",
        capabilities=[
            "chat",
            "responses",
            "coding",
            "reasoning",
            "tool_calling",
            "structured_outputs",
            "vision",
        ],
        tool_calling=True,
        tool_call_parser="qwen3_coder",
    )
    chat_model.instance = ModelInstance(
        container_name="vllm-active-chat",
        internal_url="http://vllm-active-chat:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    embedding_model = ModelRecord(
        hf_model_id="org/active-embedding",
        alias="active-embedding",
        download_status="downloaded",
        capabilities=["embeddings"],
    )
    embedding_model.instance = ModelInstance(
        container_name="vllm-active-embedding",
        internal_url="http://vllm-active-embedding:8000",
        desired_active=True,
        status="ready",
        gpu_assignment=[0],
    )
    inactive_model = ModelRecord(
        hf_model_id="org/inactive",
        alias="inactive-model",
        capabilities=["chat", "responses"],
    )
    inactive_model.instance = ModelInstance(
        container_name="vllm-inactive",
        internal_url="http://vllm-inactive:8000",
        desired_active=False,
        status="inactive",
    )
    stale_account = ServiceAccount(
        name="Preserved policy",
        allowed_models=["retired-model"],
        allowed_scopes=["chat"],
    )
    db.add_all([admin, chat_model, embedding_model, inactive_model, stale_account])
    db.flush()
    raw_session, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw_session)

    assert model_api_scopes(chat_model) == [
        "models",
        "chat",
        "responses",
        "reasoning",
        "tools",
        "structured_outputs",
        "vision",
        "coding",
    ]
    service_page = client.get("/admin/service-accounts")
    assert service_page.status_code == 200
    assert 'type="checkbox" name="allowed_models" value="active-chat"' in service_page.text
    assert 'data-scopes="models,chat,responses,reasoning,tools,structured_outputs,vision,coding"' in service_page.text
    for scope in ("reasoning", "structured_outputs", "vision"):
        assert f'value="{scope}" data-policy-scope' in service_page.text
    assert 'value="active-embedding"' in service_page.text
    assert 'value="inactive-model"' not in service_page.text
    assert "/static/policy-selectors.js?v=1.0.1" in service_page.text
    assert 'value="retired-model" data-policy-model data-policy-stale="true" data-policy-existing="true"' in service_page.text
    assert 'value="chat" data-policy-scope checked data-policy-existing="true"' in service_page.text

    preserved_service = client.post(
        f"/admin/service-accounts/{stale_account.id}/policy",
        data={
            "purpose": "general_api",
            "allowed_models": ["retired-model"],
            "scopes": ["chat"],
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert preserved_service.status_code == 303
    db.refresh(stale_account)
    assert stale_account.allowed_models == ["retired-model"]
    assert stale_account.allowed_scopes == ["chat"]

    created_service = client.post(
        "/admin/service-accounts",
        data={
            "name": "Inherited policy",
            "purpose": "general_api",
            "allowed_endpoints": "",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert created_service.status_code == 303
    inherited_account = db.scalar(select(ServiceAccount).where(ServiceAccount.name == "Inherited policy"))
    assert inherited_account.allowed_models == []
    assert inherited_account.allowed_scopes == []

    explicit_service = client.post(
        "/admin/service-accounts",
        data={
            "name": "Chat policy",
            "purpose": "coding_agent",
            "allowed_models": ["active-chat"],
            "scopes": ["chat", "responses"],
            "allowed_endpoints": "",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert explicit_service.status_code == 303
    chat_account = db.scalar(select(ServiceAccount).where(ServiceAccount.name == "Chat policy"))
    assert chat_account.allowed_models == ["active-chat"]
    assert chat_account.allowed_scopes == ["chat", "responses"]

    invalid_service = client.post(
        "/admin/service-accounts",
        data={
            "name": "Invalid policy",
            "allowed_models": ["active-chat"],
            "scopes": ["embeddings"],
            "csrf_token": session.csrf_token,
        },
    )
    assert invalid_service.status_code == 422

    api_page = client.get("/admin/api-keys")
    assert api_page.status_code == 200
    assert "Leave blank to inherit all scopes from the service account." in api_page.text
    assert not re.search(r'name="scopes"[^>]*checked', api_page.text)

    created_key = client.post(
        "/admin/api-keys",
        data={
            "name": "Inherited key",
            "owner_type": "service_account",
            "owner_id": str(chat_account.id),
            "csrf_token": session.csrf_token,
        },
    )
    assert created_key.status_code == 200
    key = db.scalar(select(APIKey).where(APIKey.name == "Inherited key"))
    assert key.allowed_models == []
    assert key.scopes == []
    require_model_access(key, "active-chat", "chat")
    with pytest.raises(PolicyDenied):
        require_model_access(key, "active-embedding", "chat")
    with pytest.raises(PolicyDenied):
        require_model_access(key, "active-chat", "tools")

    invalid_key = client.post(
        "/admin/api-keys",
        data={
            "name": "Expanded key",
            "owner_type": "service_account",
            "owner_id": str(chat_account.id),
            "scopes": ["tools"],
            "csrf_token": session.csrf_token,
        },
    )
    assert invalid_key.status_code == 422


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
        "Model stopped. You can now validate and apply a performance profile.",
        "Performance profile validated and saved. The model remains stopped.",
        "Performance profile validated and saved. Model activation started in the background.",
        "Performance profile validated, saved and activated.",
        "The performance profile was saved, but model activation could not be queued. Try activating it again.",
        "SMTP settings were saved, but the test email could not be delivered. Verify the server, port, security mode and credentials.",
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

    def capture_email(configuration, recipient, subject, text_body, html_body=None):
        delivered.update(recipient=recipient, subject=subject, body=text_body, html=html_body)

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
    assert '<html lang="es">' in delivered["html"]
    assert "Restablecer contraseña" in delivered["html"]
    assert "mensaje automático" in delivered["html"]
    assert 'role="presentation"' in delivered["html"]
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


def test_catalog_refresh_keeps_newer_installed_catalog(monkeypatch, tmp_path):
    remote = {
        "schema_version": 2,
        "catalog_version": "2026.09.28",
        "updated_at": "2026-09-28",
    }

    def fetch(*_args, **_kwargs):
        return httpx.Response(
            200,
            content=json.dumps(remote).encode(),
            request=httpx.Request("GET", stable_catalog.CATALOG_UPDATE_URL),
        )

    monkeypatch.setattr(stable_catalog.httpx, "get", fetch)
    destination = tmp_path / "model-catalog.json"
    result = stable_catalog.refresh_model_catalog(
        destination=destination,
        backup_path=tmp_path / "previous.json",
    )

    assert result["status"] == "current"
    assert result["catalog_version"] == load_model_catalog()["catalog_version"]
    assert not destination.exists()


def test_catalog_refresh_validates_and_atomically_installs_newer_catalog(monkeypatch, tmp_path):
    payload = json.loads(stable_catalog.CATALOG_PATH.read_text(encoding="utf-8"))
    payload["catalog_version"] = "2026.10.02"
    payload["updated_at"] = "2026-10-02"
    payload["capabilities_reviewed_at"] = "2026-10-02"

    def fetch(*_args, **_kwargs):
        return httpx.Response(
            200,
            content=json.dumps(payload).encode(),
            request=httpx.Request("GET", stable_catalog.CATALOG_UPDATE_URL),
        )

    monkeypatch.setattr(stable_catalog.httpx, "get", fetch)
    destination = tmp_path / "model-catalog.json"
    backup = tmp_path / "previous.json"
    result = stable_catalog.refresh_model_catalog(destination=destination, backup_path=backup)

    assert result == {
        "status": "updated",
        "catalog_version": "2026.10.02",
        "previous_version": load_model_catalog()["catalog_version"],
        "source": str(destination),
    }
    assert stable_catalog.load_model_catalog(destination)["catalog_version"] == "2026.10.02"
    assert stable_catalog.load_model_catalog(backup)["catalog_version"] == load_model_catalog()["catalog_version"]
    assert not list(tmp_path.glob(".model-catalog-*.json"))


def test_catalog_refresh_rejects_newer_unsupported_schema(monkeypatch, tmp_path):
    payload = {
        "schema_version": 99,
        "catalog_version": "2026.10.03",
        "updated_at": "2026-10-03",
        "capabilities_reviewed_at": "2026-10-03",
    }

    def fetch(*_args, **_kwargs):
        return httpx.Response(
            200,
            content=json.dumps(payload).encode(),
            request=httpx.Request("GET", stable_catalog.CATALOG_UPDATE_URL),
        )

    monkeypatch.setattr(stable_catalog.httpx, "get", fetch)
    with pytest.raises(stable_catalog.ModelCatalogError, match="unsupported schema"):
        stable_catalog.refresh_model_catalog(
            destination=tmp_path / "model-catalog.json",
            backup_path=tmp_path / "previous.json",
        )
    assert not (tmp_path / "model-catalog.json").exists()


def test_admin_can_refresh_stable_catalog_with_csrf_and_audit(db, monkeypatch):
    admin = User(name="Admin", email="catalog-refresh@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    monkeypatch.setattr(
        web,
        "refresh_model_catalog",
        lambda: {"status": "updated", "catalog_version": "2026.10.02", "previous_version": "2026.10.01.1"},
    )

    response = client.post(
        "/admin/models/catalog/refresh",
        data={"csrf_token": session.csrf_token},
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/admin/models?result=catalog-refreshed#guided-installer"
    event = db.scalar(select(AuditLog).where(AuditLog.action == "model.catalog_refreshed"))
    assert event is not None
    assert event.after == {"catalog_version": "2026.10.02", "status": "updated"}

    invalid = client.post(
        "/admin/models/catalog/refresh",
        data={"csrf_token": "invalid"},
        follow_redirects=False,
    )
    assert invalid.status_code == 403


def test_reviewed_capabilities_follow_exact_revision_and_verified_runtime():
    catalog = load_model_catalog()
    entry = next(item for item in catalog["models"] if item["key"] == "qwen3.5-4b")
    model = ModelRecord(
        hf_model_id=entry["model_id"],
        revision=entry["revision"],
        alias="reviewed-capabilities",
        capabilities=["chat"],
        tool_calling=True,
        tool_call_parser="qwen3_coder",
        config={
            "catalog_key": entry["key"],
            "catalog_version": "outdated",
            "runtime_api_support": {
                "verified": True,
                "endpoints": ["/v1/models", "/v1/chat/completions", "/v1/responses"],
            },
        },
    )

    profile = model_capability_profile(model, catalog)
    assert profile["status"] == "reviewed"
    assert profile["catalog_version"] == catalog["catalog_version"]
    assert profile["reviewed_at"] == catalog["capabilities_reviewed_at"]
    assert {"coding", "reasoning", "responses", "structured_outputs", "tool_calling", "vision"} <= set(profile["capabilities"])
    assert "completions" not in profile["capabilities"]
    assert profile["unavailable_capabilities"] == ["completions"]

    model.tool_call_parser = None
    without_parser = model_capability_profile(model, catalog)
    assert "tool_calling" not in without_parser["capabilities"]
    assert without_parser["unavailable_capabilities"] == ["completions", "tool_calling"]

    model.revision = "f" * 40
    mismatch = model_capability_profile(model, catalog)
    assert mismatch["status"] == "revision_mismatch"
    assert mismatch["capabilities"] == ["chat"]


def test_admin_models_guided_catalog_registers_all_reviewed_capabilities(db):
    admin = User(name="Admin", email="guided-models@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    page = client.get("/admin/models")
    assert page.status_code == 200
    assert 'id="guided-model-form"' in page.text
    assert "Register an arbitrary model" not in page.text
    assert 'value="qwen3.5-4b"' in page.text
    assert 'data-capabilities="agentic,chat,coding,completions,general,reasoning,responses,structured_outputs,tool_calling,vision"' in page.text
    assert 'data-capabilities-reviewed-at="2026-10-01"' in page.text
    assert "https://huggingface.co/Qwen/Qwen3.5-4B/tree/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a" in page.text
    assert 'action="/admin/models/catalog/refresh"' in page.text
    assert 'class="secondary catalog-refresh-button"' in page.text
    assert 'aria-label="Refresh stable catalog"' in page.text
    assert "/static/models-guided.js?v=1.2.0-jobs1" in page.text
    assert "/static/i18n.js?v=1.2.0-mfa1" in page.text

    response = client.post(
        "/admin/models/catalog",
        data={
            "catalog_key": "qwen3.5-4b",
            "alias": "qwen-current",
            "capabilities": "",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/admin/models?result=catalog-registered"
    catalog_entry = load_model_catalog()["models"][0]
    model = db.scalar(select(ModelRecord).where(ModelRecord.alias == "qwen-current"))
    assert model is not None
    assert model.hf_model_id == catalog_entry["model_id"]
    assert model.revision == catalog_entry["revision"]
    assert model.capabilities == catalog_entry["capabilities"]
    assert model.tool_calling is True
    assert model.tool_call_parser == "qwen3_coder"
    assert model.config["catalog_key"] == "qwen3.5-4b"
    assert model.instance.max_num_seqs == 2
    assert model.instance.gpu_memory_utilization == 0.82
    assert model.instance.extra_args == ["--reasoning-parser", "qwen3"]
    model_page = client.get("/admin/models")
    assert '<option value="AUTO" selected>AUTO</option>' in model_page.text

    model.capabilities = ["chat"]
    model.tool_calling = False
    model.tool_call_parser = None
    db.commit()
    configured = client.post(
        f"/admin/models/{model.id}/configure",
        data={
            "alias": model.alias,
            "max_model_len": model.max_model_len,
            "capabilities": "chat",
            "gpu_assignment": "",
            "tensor_parallel_size": 1,
            "pipeline_parallel_size": 1,
            "max_num_seqs": model.instance.max_num_seqs,
            "gpu_memory_utilization": model.instance.gpu_memory_utilization,
            "cpu_offload_gb": 0,
            "swap_space_gb": 4,
            "performance_profile": "AUTOMÁTICO",
            "system_prompt": "",
            "chat_template": "",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert configured.status_code == 303
    db.refresh(model)
    assert model.capabilities == catalog_entry["capabilities"]
    assert model.tool_calling is True
    assert model.tool_call_parser == "qwen3_coder"
    assert model.instance.performance_profile == "AUTO"
    assert model.config["catalog_version"] == load_model_catalog()["catalog_version"]

    invalid_profile = client.post(
        f"/admin/models/{model.id}/configure",
        data={
            "alias": model.alias,
            "performance_profile": "invalid-profile",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert invalid_profile.status_code == 303
    assert invalid_profile.headers["location"] == (
        f"/admin/models?error=invalid-performance-profile&error_alias={model.alias}#model-{model.id}"
    )
    error_page = client.get(invalid_profile.headers["location"])
    assert "The selected performance profile is invalid." in error_page.text

    duplicate = client.post(
        "/admin/models/catalog",
        data={
            "catalog_key": "qwen3.5-4b",
            "alias": "another-alias",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert duplicate.status_code == 303
    assert duplicate.headers["location"] == "/admin/models?error=already-registered&error_alias=qwen-current#guided-installer"
    already_registered = client.get("/admin/models?error=already-registered&error_alias=qwen-current")
    assert "already registered as" in already_registered.text

    alias_collision = client.post(
        "/admin/models/catalog",
        data={
            "catalog_key": "qwen3-8b-awq",
            "alias": "qwen-current",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )
    assert alias_collision.status_code == 303
    assert alias_collision.headers["location"] == "/admin/models?error=alias-exists&error_alias=qwen-current#guided-installer"
    collision_page = client.get("/admin/models?error=alias-exists&error_alias=qwen-current")
    assert "Choose the suggested alias" in collision_page.text


def test_guided_catalog_install_queues_background_work_without_waiting(db, monkeypatch):
    admin = User(name="Admin", email="queued-model@example.com", password_hash=hash_password("GoodPassword!123"), role="super_admin")
    db.add(admin)
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()
    calls = []

    async def queue_install(model_id, action, params=None):
        calls.append((model_id, action, params))
        return httpx.Response(202, json={"status": "queued", "model_id": model_id})

    monkeypatch.setattr(web, "controller_action", queue_install)
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    response = client.post(
        "/admin/models/catalog",
        data={
            "catalog_key": "qwen3.5-4b",
            "alias": "qwen-background",
            "capabilities": "",
            "download_now": "true",
            "activate_now": "true",
            "set_default": "true",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )

    model = db.scalar(select(ModelRecord).where(ModelRecord.alias == "qwen-background"))
    assert response.status_code == 303
    assert response.headers["location"] == f"/admin/models?result=catalog-queued#model-{model.id}"
    assert calls == [(model.id, "install", {"activate": True, "set_default": True})]


def test_controller_guided_install_worker_tracks_completion(db, monkeypatch):
    model = ModelRecord(
        hf_model_id="org/background-model",
        alias="background-model",
        download_status="queued",
        capabilities=["chat"],
        config={"guided_install": {"status": "queued", "phase": "download", "activate": True, "set_default": True}},
    )
    model.instance = ModelInstance(container_name="vllm-background-model", internal_url="", status="inactive")
    db.add(model)
    db.commit()

    def fake_download(worker_db, worker_model, _settings):
        worker_model.download_status = "downloaded"
        worker_model.local_path = "/models/background-model"
        worker_db.commit()

    class FakeRuntime:
        def __init__(self, worker_db, _settings):
            self.db = worker_db

        def activate(self, worker_model):
            worker_model.instance.desired_active = True
            worker_model.instance.status = "ready"
            self.db.commit()
            return {"status": "ready"}

    monkeypatch.setattr(controller, "download_model", fake_download)
    monkeypatch.setattr(controller, "ModelRuntime", FakeRuntime)
    controller.guided_install_worker(model.id)

    db.expire_all()
    completed = db.get(ModelRecord, model.id)
    assert completed.download_status == "downloaded"
    assert completed.instance.status == "ready"
    assert completed.is_default is True
    assert completed.config["guided_install"]["status"] == "completed"
    assert completed.config["guided_install"]["phase"] == "ready"


def test_controller_install_endpoint_returns_accepted_and_persists_queue(db, monkeypatch):
    model = ModelRecord(hf_model_id="org/queued-model", alias="queued-model", capabilities=["chat"])
    model.instance = ModelInstance(container_name="vllm-queued-model", internal_url="", status="inactive")
    db.add(model)
    db.commit()
    monkeypatch.setattr(controller, "guided_install_worker", lambda _model_id: None)
    client = TestClient(controller.app)

    response = client.post(
        f"/models/{model.id}/install?activate=true&set_default=true",
        headers={"Authorization": f"Bearer {get_settings().controller_token}"},
    )

    assert response.status_code == 202
    assert response.json()["status"] == "queued"
    db.expire_all()
    queued = db.get(ModelRecord, model.id)
    assert queued.download_status == "queued"
    assert queued.config["guided_install"] | {"updated_at": None} == {
        "status": "queued",
        "phase": "download",
        "activate": True,
        "set_default": True,
        "force_download": False,
        "error": None,
        "updated_at": None,
    }


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


def test_performance_activation_is_queued_and_polled_in_background(db, monkeypatch, tmp_path):
    admin = User(
        name="Performance Admin",
        email="performance-queue@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    model = ModelRecord(
        hf_model_id="Qwen/Qwen3.5-4B",
        alias="queued-performance-model",
        download_status="downloaded",
        local_path="/models/qwen3.5-4b",
        capabilities=["chat", "reasoning"],
        estimated_weight_gb=8.5,
        max_model_len=8192,
    )
    model.instance = ModelInstance(
        container_name="vllm-queued-performance-model",
        internal_url="http://127.0.0.1:19001",
        desired_active=False,
        status="inactive",
        gpu_assignment=[0],
        performance_profile="AUTO",
    )
    db.add_all([admin, model])
    db.flush()
    raw, session = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()

    hardware_dir = tmp_path / "hardware"
    hardware_dir.mkdir()
    (hardware_dir / "current.json").write_text('{"gpus": []}', encoding="utf-8")
    monkeypatch.setattr(web, "DATA_ROOT", tmp_path)

    monkeypatch.setattr(
        web,
        "recommend_profile",
        lambda *_args: {
            "profile": "AUTO",
            "resolved_profile": "PERFORMANCE",
            "gpu_memory_utilization": 0.82,
            "max_model_len": 8192,
            "max_num_seqs": 2,
            "max_num_batched_tokens": 8192,
        },
    )
    monkeypatch.setattr(web, "compatibility_analysis", lambda *_args: {"safe": True, "label": "SAFE"})
    queued_call = {}

    async def queue_activation(model_id, action, params=None):
        queued_call.update(model_id=model_id, action=action, params=params)
        return httpx.Response(202, json={"status": "queued", "model_id": model_id})

    monkeypatch.setattr(web, "controller_action", queue_activation)
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    response = client.post(
        f"/admin/performance/{model.id}",
        data={
            "profile": "AUTO",
            "activate_after_apply": "true",
            "csrf_token": session.csrf_token,
        },
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/admin/performance?result=activation-queued#model-{model.id}"
    )
    assert queued_call == {
        "model_id": model.id,
        "action": "install",
        "params": {"activate": True, "set_default": False, "force_download": False},
    }
    db.expire_all()
    saved = db.get(ModelRecord, model.id)
    assert saved.instance.performance_profile == "AUTO"
    assert saved.instance.desired_active is False
    assert db.scalar(select(AuditLog).where(AuditLog.action == "model.performance_activation_queued")) is not None

    saved.config = {
        **saved.config,
        "guided_install": {
            "status": "queued",
            "phase": "activation",
            "activate": True,
            "set_default": False,
            "force_download": False,
            "error": None,
        },
    }
    db.commit()
    (hardware_dir / "current.json").unlink()
    progress = client.get("/admin/performance?result=activation-queued")
    assert progress.status_code == 200
    assert "Model activation is running in the background." in progress.text
    assert f'data-install-status-url="/admin/models/{model.id}/status"' in progress.text
    assert f'data-install-success-url="/admin/performance?result=applied-activated#model-{model.id}"' in progress.text
    assert 'data-install-operation="activation"' in progress.text
    assert "/static/models-guided.js?v=1.2.0-jobs1" in progress.text
