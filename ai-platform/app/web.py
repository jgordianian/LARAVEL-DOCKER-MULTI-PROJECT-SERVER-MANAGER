from __future__ import annotations

import json
import re
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from redis import Redis
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from . import __version__
from .capabilities import (
    MODEL_CAPABILITIES,
    model_capabilities,
    normalize_capabilities,
    normalize_endpoints,
    validate_service_account_purpose,
)
from .config import get_settings
from .db import SessionLocal, get_db
from .environment import load_environment_snapshot
from .models import (
    APIKey,
    AuditLog,
    Conversation,
    IPRule,
    Message,
    ModelInstance,
    ModelPermission,
    ModelRecord,
    Quota,
    ServiceAccount,
    SystemSetting,
    UsageRecord,
    User,
    WebSession,
)
from .runtime import RuntimeOperationError, activation_plan, compatibility_analysis, container_name_for, recommend_profile
from .security import (
    create_web_session,
    constant_time_token,
    generate_api_key,
    get_web_session,
    hash_password,
    ip_allowed,
    normalize_email,
    parse_networks,
    resolve_client_ip,
    verify_password,
)


settings = get_settings()
BASE = Path(__file__).resolve().parent
CONTAINER_PLATFORM_ROOT = Path("/platform")
DATA_ROOT = CONTAINER_PLATFORM_ROOT if settings.ai_runtime_mode == "docker" and CONTAINER_PLATFORM_ROOT.is_dir() else settings.ai_platform_root
ENVIRONMENT_SNAPSHOT_PATH = DATA_ROOT / "hardware" / "environment.json"
NOTEBOOKS_ROOT = DATA_ROOT / "notebooks"
templates = Jinja2Templates(directory=str(BASE / "templates"))
redis_client = Redis.from_url(settings.redis_url, decode_responses=True)
app = FastAPI(title="vLLM AI Platform", version=__version__, docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")
ADMIN_ROLES = {"super_admin", "administrator"}


@app.middleware("http")
async def security_headers(request: Request, call_next):
    peer = request.client.host if request.client else "0.0.0.0"
    request.state.client_ip = resolve_client_ip(
        peer,
        request.headers.get("x-forwarded-for") if constant_time_token(request.headers.get("x-ai-proxy-token", ""), settings.proxy_shared_token) else None,
        request.headers.get("x-real-ip") if constant_time_token(request.headers.get("x-ai-proxy-token", ""), settings.proxy_shared_token) else None,
        settings.trusted_proxy_networks,
    )
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    )
    if settings.cookie_secure:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


@app.get("/health")
def health(db: Session = Depends(get_db)) -> dict:
    db.execute(select(1))
    return {"status": "ok", "version": __version__}


def session_for(request: Request, db: Session) -> WebSession | None:
    return get_web_session(db, request.cookies.get("ai_session"), settings)


def require_session(request: Request, db: Session = Depends(get_db)) -> WebSession:
    session = session_for(request, db)
    if session is None:
        raise HTTPException(401, "authentication required")
    if session.user.force_password_reset and request.url.path not in {"/profile/password", "/logout"}:
        raise HTTPException(403, "password change required before using the platform")
    return session


def require_admin(request: Request, db: Session = Depends(get_db)) -> WebSession:
    if not settings.admin_panel_enabled:
        raise HTTPException(404, "administration panel is disabled")
    session = require_session(request, db)
    if session.user.role not in ADMIN_ROLES:
        raise HTTPException(403, "administrator access required")
    return session


def require_chat_session(request: Request, db: Session) -> WebSession:
    if not settings.chat_portal_enabled:
        raise HTTPException(404, "chat portal is disabled")
    return require_session(request, db)


def verify_csrf(request: Request, session: WebSession, submitted: str) -> None:
    if not secrets.compare_digest(session.csrf_token, submitted or ""):
        raise HTTPException(403, "CSRF validation failed")


def audit(db: Session, session: WebSession | None, request: Request, action: str, target_type: str | None = None, target_id: Any = None, before=None, after=None, result="success") -> None:
    db.add(AuditLog(
        actor_type="user" if session else "system",
        actor_id=session.user_id if session else None,
        source_ip=request.state.client_ip,
        action=action,
        target_type=target_type,
        target_id=str(target_id) if target_id is not None else None,
        before=before,
        after=after,
        result=result,
    ))


def render(request: Request, name: str, session: WebSession | None = None, **context):
    return templates.TemplateResponse(request, name, {"session": session, "settings": settings, "version": __version__, **context})


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request, db: Session = Depends(get_db)):
    if session_for(request, db):
        return RedirectResponse("/", 303)
    token = secrets.token_urlsafe(32)
    response = render(request, "login.html", login_csrf=token, error=None)
    response.set_cookie("ai_login_csrf", token, secure=settings.cookie_secure, httponly=True, samesite="strict", max_age=600)
    return response


@app.post("/login", response_class=HTMLResponse)
def login(request: Request, email: str = Form(), password: str = Form(), csrf_token: str = Form(), db: Session = Depends(get_db)):
    cookie_csrf = request.cookies.get("ai_login_csrf", "")
    if not cookie_csrf or not secrets.compare_digest(cookie_csrf, csrf_token):
        raise HTTPException(403, "CSRF validation failed")
    ip = request.state.client_ip
    throttle_key = f"aip:login:{ip}"
    attempts = int(redis_client.incr(throttle_key))
    if attempts == 1:
        redis_client.expire(throttle_key, 900)
    if attempts > 10:
        response = render(request, "login.html", login_csrf=csrf_token, error="Too many login attempts. Try again later.")
        response.status_code = 429
        return response
    user = db.scalar(select(User).where(func.lower(User.email) == email.strip().lower()))
    if user is None or not user.enabled or not verify_password(user.password_hash, password):
        response = render(request, "login.html", login_csrf=csrf_token, error="Invalid email or password.")
        response.status_code = 401
        return response
    redis_client.delete(throttle_key)
    raw, web_session = create_web_session(db, user, ip, request.headers.get("user-agent", ""), settings)
    user.last_login_at = datetime.now(timezone.utc)
    audit(db, web_session, request, "user.login", "user", user.id)
    db.commit()
    response = RedirectResponse("/profile/password" if user.force_password_reset else "/", 303)
    response.set_cookie("ai_session", raw, secure=settings.cookie_secure, httponly=True, samesite="lax", max_age=settings.session_ttl_seconds)
    response.delete_cookie("ai_login_csrf")
    return response


@app.post("/logout")
def logout(request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_session(request, db)
    verify_csrf(request, session, csrf_token)
    audit(db, session, request, "user.logout", "user", session.user_id)
    db.delete(session)
    db.commit()
    response = RedirectResponse("/login", 303)
    response.delete_cookie("ai_session")
    return response


@app.get("/profile/password", response_class=HTMLResponse)
def password_page(request: Request, db: Session = Depends(get_db)):
    session = require_session(request, db)
    return render(request, "password.html", session=session, error=None, success=None)


@app.post("/profile/password", response_class=HTMLResponse)
def password_change(request: Request, current_password: str = Form(), new_password: str = Form(), confirm_password: str = Form(), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_session(request, db)
    verify_csrf(request, session, csrf_token)
    error = None
    if not verify_password(session.user.password_hash, current_password):
        error = "Current password is invalid."
    elif new_password != confirm_password:
        error = "New passwords do not match."
    else:
        try:
            session.user.password_hash = hash_password(new_password)
            session.user.force_password_reset = False
            audit(db, session, request, "user.password_changed", "user", session.user_id)
            db.commit()
            return RedirectResponse("/", 303)
        except ValueError as exc:
            error = str(exc)
    return render(request, "password.html", session=session, error=error, success=None)


def permitted_models(db: Session, user_id: int) -> list[ModelRecord]:
    active = db.scalars(select(ModelRecord).join(ModelInstance).where(ModelInstance.status == "ready", ModelInstance.desired_active.is_(True)).order_by(ModelRecord.alias)).all()
    permissions = db.scalars(select(ModelPermission).where(ModelPermission.subject_type == "user", ModelPermission.subject_id == user_id, ModelPermission.can_chat.is_(True))).all()
    if not permissions:
        return active
    allowed = {permission.model_id for permission in permissions}
    return [model for model in active if model.id in allowed]


@app.get("/", response_class=HTMLResponse)
def chat_page(request: Request, q: str = "", db: Session = Depends(get_db)):
    if not settings.chat_portal_enabled:
        return RedirectResponse("/admin", 303)
    session = session_for(request, db)
    if session is None:
        return RedirectResponse("/login", 303)
    query = select(Conversation).where(Conversation.user_id == session.user_id, Conversation.archived.is_(False))
    if q:
        query = query.where(Conversation.title.ilike(f"%{q[:100]}%"))
    conversations = db.scalars(query.order_by(Conversation.updated_at.desc()).limit(100)).all()
    models = permitted_models(db, session.user_id)
    portal_setting = db.get(SystemSetting, "portal_default_model")
    system_default = next((model.alias for model in models if model.is_default), None)
    preferred = session.user.default_model_alias or (portal_setting.value if portal_setting and isinstance(portal_setting.value, str) else None) or system_default
    return render(
        request, "chat.html", session=session, conversations=conversations, models=models, search=q,
        preferred_model=preferred, default_unavailable=bool(preferred and preferred not in {model.alias for model in models}),
    )


@app.get("/api/conversations")
def conversation_list(request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    rows = db.scalars(select(Conversation).where(Conversation.user_id == session.user_id, Conversation.archived.is_(False)).order_by(Conversation.updated_at.desc())).all()
    return [{"id": row.id, "title": row.title, "model": row.model_alias, "updated_at": row.updated_at.isoformat()} for row in rows]


@app.get("/api/conversations/{conversation_id}")
def conversation_get(conversation_id: int, request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    row = db.scalar(select(Conversation).where(Conversation.id == conversation_id, Conversation.user_id == session.user_id))
    if row is None:
        raise HTTPException(404, "conversation not found")
    return {
        "id": row.id, "title": row.title, "model": row.model_alias,
        "messages": [{"id": message.id, "role": message.role, "content": message.content, "tool_calls": message.tool_calls, "created_at": message.created_at.isoformat()} for message in row.messages],
    }


@app.post("/api/conversations")
async def conversation_create(request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    data = await request.json()
    verify_csrf(request, session, str(data.get("csrf_token", "")))
    alias = str(data.get("model", ""))
    if alias not in {model.alias for model in permitted_models(db, session.user_id)}:
        raise HTTPException(403, "model unavailable or forbidden")
    row = Conversation(user_id=session.user_id, model_alias=alias, title="New conversation")
    db.add(row)
    db.commit()
    return {"id": row.id, "title": row.title, "model": row.model_alias}


@app.patch("/api/conversations/{conversation_id}")
async def conversation_rename(conversation_id: int, request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    data = await request.json()
    verify_csrf(request, session, str(data.get("csrf_token", "")))
    row = db.scalar(select(Conversation).where(Conversation.id == conversation_id, Conversation.user_id == session.user_id))
    if row is None:
        raise HTTPException(404, "conversation not found")
    title = str(data.get("title", "")).strip()[:255]
    if not title:
        raise HTTPException(422, "title is required")
    row.title = title
    db.commit()
    return {"status": "ok", "title": title}


@app.delete("/api/conversations/{conversation_id}")
async def conversation_delete(conversation_id: int, request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    data = await request.json()
    verify_csrf(request, session, str(data.get("csrf_token", "")))
    row = db.scalar(select(Conversation).where(Conversation.id == conversation_id, Conversation.user_id == session.user_id))
    if row is None:
        raise HTTPException(404, "conversation not found")
    db.delete(row)
    db.commit()
    return {"status": "deleted"}


@app.post("/api/chat")
async def portal_chat(request: Request, db: Session = Depends(get_db)):
    session = require_chat_session(request, db)
    data = await request.json()
    verify_csrf(request, session, str(data.get("csrf_token", "")))
    conversation_id = int(data.get("conversation_id", 0))
    regenerate = bool(data.get("regenerate", False))
    content = str(data.get("content", "")).strip()
    if not regenerate and (not content or len(content.encode("utf-8")) > settings.max_request_bytes):
        raise HTTPException(422, "message is empty or too large")
    conversation = db.scalar(select(Conversation).where(Conversation.id == conversation_id, Conversation.user_id == session.user_id))
    if conversation is None:
        raise HTTPException(404, "conversation not found")
    allowed = {model.alias for model in permitted_models(db, session.user_id)}
    if conversation.model_alias not in allowed:
        raise HTTPException(409, "the selected model is no longer available")
    if regenerate:
        last_assistant = db.scalar(
            select(Message)
            .where(Message.conversation_id == conversation.id, Message.role == "assistant")
            .order_by(Message.created_at.desc(), Message.id.desc())
        )
        if last_assistant is None:
            raise HTTPException(409, "there is no assistant response to regenerate")
        db.delete(last_assistant)
    else:
        user_message = Message(conversation_id=conversation.id, role="user", content=content)
        db.add(user_message)
        if conversation.title == "New conversation":
            conversation.title = re.sub(r"\s+", " ", content)[:80]
    db.commit()
    db.expire(conversation, ["messages"])
    messages = [{"role": message.role, "content": message.content, **({"tool_calls": message.tool_calls} if message.tool_calls else {})} for message in conversation.messages]
    payload = {"model": conversation.model_alias, "messages": messages, "stream": True}
    client = httpx.AsyncClient(timeout=httpx.Timeout(600, connect=10))
    upstream_request = client.build_request(
        "POST", f"{settings.gateway_internal_url}/v1/chat/completions", json=payload,
        headers={"X-AI-Internal-Token": settings.internal_gateway_token, "X-AI-User-ID": str(session.user_id), "X-AI-Client-IP": request.state.client_ip},
    )
    try:
        upstream = await client.send(upstream_request, stream=True)
    except httpx.HTTPError:
        await client.aclose()
        raise HTTPException(503, "model gateway unavailable") from None
    if upstream.status_code >= 400:
        body = await upstream.aread()
        await upstream.aclose()
        await client.aclose()
        return JSONResponse(json.loads(body), upstream.status_code)

    async def relay():
        answer: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        req_id = upstream.headers.get("x-request-id")
        try:
            async for line in upstream.aiter_lines():
                if not line:
                    continue
                wire = f"{line}\n\n".encode()
                if line.startswith("data: ") and line[6:] != "[DONE]":
                    try:
                        event = json.loads(line[6:])
                        for choice in event.get("choices", []):
                            delta = choice.get("delta", {})
                            if delta.get("content"):
                                answer.append(delta["content"])
                            if delta.get("tool_calls"):
                                tool_calls.extend(delta["tool_calls"])
                    except (json.JSONDecodeError, TypeError):
                        pass
                yield wire
        finally:
            await upstream.aclose()
            await client.aclose()
            if answer or tool_calls:
                with SessionLocal() as write_db:
                    write_db.add(Message(
                        conversation_id=conversation_id,
                        role="assistant",
                        content="".join(answer),
                        tool_calls=tool_calls,
                        request_id=req_id,
                    ))
                    write_db.commit()

    return StreamingResponse(relay(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})


@app.get("/admin", response_class=HTMLResponse)
def admin_dashboard(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    since = datetime.now(timezone.utc) - timedelta(days=1)
    usage_24h = db.execute(
        select(
            func.coalesce(func.sum(UsageRecord.input_tokens), 0),
            func.coalesce(func.sum(UsageRecord.output_tokens), 0),
            func.coalesce(func.avg(UsageRecord.latency_ms), 0),
        ).where(UsageRecord.occurred_at >= since)
    ).one()
    counts = {
        "users": db.scalar(select(func.count()).select_from(User)) or 0,
        "api_keys": db.scalar(select(func.count()).select_from(APIKey).where(APIKey.enabled.is_(True), APIKey.revoked_at.is_(None))) or 0,
        "models": db.scalar(select(func.count()).select_from(ModelRecord)) or 0,
        "active_models": db.scalar(select(func.count()).select_from(ModelInstance).where(ModelInstance.status == "ready")) or 0,
        "requests_24h": db.scalar(select(func.count()).select_from(UsageRecord).where(UsageRecord.occurred_at >= since)),
        "input_tokens_24h": int(usage_24h[0] or 0),
        "output_tokens_24h": int(usage_24h[1] or 0),
        "average_latency_24h": int(usage_24h[2] or 0),
    }
    hardware = {}
    try:
        hardware = json.loads((DATA_ROOT / "hardware" / "current.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    recent = db.scalars(select(AuditLog).order_by(AuditLog.occurred_at.desc()).limit(12)).all()
    return render(request, "admin_dashboard.html", session=session, counts=counts, hardware=hardware, recent=recent)


@app.get("/admin/users", response_class=HTMLResponse)
def users_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    users = db.scalars(select(User).order_by(User.email)).all()
    permissions = db.scalars(select(ModelPermission).where(ModelPermission.subject_type == "user")).all()
    quotas = db.scalars(select(Quota).where(Quota.subject_type == "user")).all()
    return render(
        request, "users.html", session=session, users=users, models=db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all(),
        permission_map={user.id: [permission.model_id for permission in permissions if permission.subject_id == user.id] for user in users},
        tool_permission_map={user.id: [permission.model_id for permission in permissions if permission.subject_id == user.id and permission.can_use_tools] for user in users},
        coding_permission_map={user.id: [permission.model_id for permission in permissions if permission.subject_id == user.id and permission.can_code] for user in users},
        quota_map={quota.subject_id: quota.limits for quota in quotas}, error=None,
    )


@app.post("/admin/users", response_class=HTMLResponse)
def user_create(request: Request, name: str = Form(), email: str = Form(), role: str = Form(), password: str = Form(), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    try:
        email = normalize_email(email)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    if role not in {"super_admin", "administrator", "user"}:
        raise HTTPException(422, "invalid role")
    if role == "super_admin" and session.user.role != "super_admin":
        raise HTTPException(403, "only a super administrator may create another super administrator")
    if db.scalar(select(User).where(func.lower(User.email) == email)):
        response = render(request, "users.html", session=session, users=db.scalars(select(User).order_by(User.email)).all(), models=[], permission_map={}, tool_permission_map={}, coding_permission_map={}, quota_map={}, error="Email already exists.")
        response.status_code = 409
        return response
    try:
        user = User(name=name.strip()[:160], email=email, role=role, password_hash=hash_password(password), force_password_reset=True)
    except ValueError as exc:
        response = render(request, "users.html", session=session, users=db.scalars(select(User).order_by(User.email)).all(), models=[], permission_map={}, tool_permission_map={}, coding_permission_map={}, quota_map={}, error=str(exc))
        response.status_code = 422
        return response
    db.add(user)
    db.flush()
    audit(db, session, request, "user.created", "user", user.id, after={"email": email, "role": role})
    db.commit()
    return RedirectResponse("/admin/users", 303)


def admin_target_user(db: Session, session: WebSession, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(404, "user not found")
    if user.role == "super_admin" and session.user.role != "super_admin":
        raise HTTPException(403, "only a super administrator may manage a super administrator")
    return user


@app.post("/admin/users/{user_id}/update")
def user_update(user_id: int, request: Request, name: str = Form(), role: str = Form(), default_model_alias: str = Form(""), system_prompt: str = Form(""), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    user = admin_target_user(db, session, user_id)
    if role not in {"super_admin", "administrator", "user"}:
        raise HTTPException(422, "invalid role")
    if role == "super_admin" and session.user.role != "super_admin":
        raise HTTPException(403, "only a super administrator may grant this role")
    if user.id == session.user_id and role != user.role:
        raise HTTPException(409, "use another super administrator to change your own role")
    before = {"name": user.name, "role": user.role, "default_model_alias": user.default_model_alias}
    user.name = name.strip()[:160]
    user.role = role
    user.default_model_alias = default_model_alias.strip() or None
    user.system_prompt = system_prompt.strip() or None
    audit(db, session, request, "user.updated", "user", user.id, before=before, after={"name": user.name, "role": role, "default_model_alias": user.default_model_alias})
    db.commit()
    return RedirectResponse("/admin/users", 303)


@app.post("/admin/users/{user_id}/reset-password")
def user_reset_password(user_id: int, request: Request, password: str = Form(), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    user = admin_target_user(db, session, user_id)
    user.password_hash = hash_password(password)
    user.force_password_reset = True
    db.query(WebSession).filter(WebSession.user_id == user.id).delete()
    audit(db, session, request, "user.password_reset", "user", user.id)
    db.commit()
    return RedirectResponse("/admin/users", 303)


@app.post("/admin/users/{user_id}/policy")
def user_policy(
    user_id: int, request: Request, model_ids: str = Form(""), tool_model_ids: str = Form(""), coding_model_ids: str = Form(""),
    requests_per_minute: int = Form(30), tokens_per_minute: int = Form(30000), concurrent_requests: int = Form(2),
    requests_per_day: int = Form(2000), requests_per_month: int = Form(30000),
    tokens_per_day: int = Form(500000), tokens_per_month: int = Form(5000000),
    max_input_tokens: int = Form(16384), max_output_tokens: int = Form(4096),
    csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    user = admin_target_user(db, session, user_id)
    selected = {int(value) for value in model_ids.split(",") if value.strip().isdigit()}
    tools = {int(value) for value in tool_model_ids.split(",") if value.strip().isdigit()}
    coding = {int(value) for value in coding_model_ids.split(",") if value.strip().isdigit()}
    valid = set(db.scalars(select(ModelRecord.id)).all())
    if not selected <= valid or not tools <= selected or not coding <= selected:
        raise HTTPException(422, "invalid model permission selection")
    db.query(ModelPermission).filter(ModelPermission.subject_type == "user", ModelPermission.subject_id == user.id).delete()
    for model_id in selected:
        db.add(
            ModelPermission(
                subject_type="user", subject_id=user.id, model_id=model_id,
                can_chat=True, can_use_tools=model_id in tools, can_code=model_id in coding,
            )
        )
    limits = {
        "requests_per_minute": max(0, requests_per_minute), "tokens_per_minute": max(0, tokens_per_minute),
        "concurrent_requests": max(1, concurrent_requests), "requests_per_day": max(0, requests_per_day),
        "requests_per_month": max(0, requests_per_month), "tokens_per_day": max(0, tokens_per_day),
        "tokens_per_month": max(0, tokens_per_month), "max_input_tokens": max(1, max_input_tokens),
        "max_output_tokens": max(1, max_output_tokens),
    }
    quota = db.scalar(select(Quota).where(Quota.subject_type == "user", Quota.subject_id == user.id))
    if quota is None:
        quota = Quota(subject_type="user", subject_id=user.id, limits=limits)
        db.add(quota)
    else:
        quota.limits = limits
    audit(db, session, request, "user.policy_changed", "user", user.id, after={"models": sorted(selected), "limits": limits})
    db.commit()
    return RedirectResponse("/admin/users", 303)


@app.post("/admin/users/{user_id}/toggle")
def user_toggle(user_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    user = admin_target_user(db, session, user_id)
    if user.id == session.user_id:
        raise HTTPException(409, "cannot disable your own account")
    before = {"enabled": user.enabled}
    user.enabled = not user.enabled
    if not user.enabled:
        db.query(WebSession).filter(WebSession.user_id == user.id).delete()
    audit(db, session, request, "user.enabled" if user.enabled else "user.disabled", "user", user.id, before=before, after={"enabled": user.enabled})
    db.commit()
    return RedirectResponse("/admin/users", 303)


@app.get("/admin/service-accounts", response_class=HTMLResponse)
def service_accounts_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    accounts = db.scalars(select(ServiceAccount).order_by(ServiceAccount.name)).all()
    quotas = db.scalars(select(Quota).where(Quota.subject_type == "service_account")).all()
    return render(request, "service_accounts.html", session=session, accounts=accounts, quota_map={quota.subject_id: quota.limits for quota in quotas})


@app.post("/admin/service-accounts")
def service_account_create(
    request: Request, name: str = Form(), description: str = Form(""), purpose: str = Form("general_api"),
    allowed_models: str = Form(""), scopes: str = Form("models,chat"), allowed_endpoints: str = Form(""),
    allow_custom_system_messages: bool = Form(False), csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    name = name.strip()[:160]
    if not name or db.scalar(select(ServiceAccount).where(ServiceAccount.name == name)):
        raise HTTPException(409, "service account name is empty or already exists")
    try:
        normalized_purpose = validate_service_account_purpose(purpose)
        endpoints = normalize_endpoints(v.strip() for v in allowed_endpoints.split(","))
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    account = ServiceAccount(
        name=name, description=description.strip()[:2000],
        purpose=normalized_purpose,
        allowed_models=[v.strip() for v in allowed_models.split(",") if v.strip()],
        allowed_scopes=[v.strip() for v in scopes.split(",") if v.strip()],
        allowed_endpoints=endpoints,
        allow_custom_system_messages=allow_custom_system_messages,
    )
    db.add(account)
    db.flush()
    audit(db, session, request, "service_account.created", "service_account", account.id)
    db.commit()
    return RedirectResponse("/admin/service-accounts", 303)


@app.post("/admin/service-accounts/{account_id}/toggle")
def service_account_toggle(account_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    account = db.get(ServiceAccount, account_id)
    if account is None:
        raise HTTPException(404, "service account not found")
    account.enabled = not account.enabled
    audit(db, session, request, "service_account.enabled" if account.enabled else "service_account.disabled", "service_account", account.id)
    db.commit()
    return RedirectResponse("/admin/service-accounts", 303)


@app.post("/admin/service-accounts/{account_id}/policy")
def service_account_policy(
    account_id: int, request: Request, purpose: str = Form("general_api"), allowed_models: str = Form(""),
    scopes: str = Form("models,chat"), allowed_endpoints: str = Form(""),
    allow_custom_system_messages: bool = Form(False), requests_per_minute: int = Form(60),
    tokens_per_minute: int = Form(60000), concurrent_requests: int = Form(4), requests_per_day: int = Form(10000),
    requests_per_month: int = Form(100000), tokens_per_day: int = Form(2000000), tokens_per_month: int = Form(20000000),
    max_input_tokens: int = Form(32768), max_output_tokens: int = Form(8192), csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    account = db.get(ServiceAccount, account_id)
    if account is None:
        raise HTTPException(404, "service account not found")
    try:
        account.purpose = validate_service_account_purpose(purpose)
        account.allowed_endpoints = normalize_endpoints(value.strip() for value in allowed_endpoints.split(","))
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    account.allowed_models = [value.strip() for value in allowed_models.split(",") if value.strip()]
    account.allowed_scopes = [value.strip() for value in scopes.split(",") if value.strip()]
    account.allow_custom_system_messages = allow_custom_system_messages
    limits = {
        "requests_per_minute": max(0, requests_per_minute), "tokens_per_minute": max(0, tokens_per_minute),
        "concurrent_requests": max(1, concurrent_requests), "requests_per_day": max(0, requests_per_day),
        "requests_per_month": max(0, requests_per_month), "tokens_per_day": max(0, tokens_per_day),
        "tokens_per_month": max(0, tokens_per_month), "max_input_tokens": max(1, max_input_tokens),
        "max_output_tokens": max(1, max_output_tokens),
    }
    quota = db.scalar(select(Quota).where(Quota.subject_type == "service_account", Quota.subject_id == account.id))
    if quota is None:
        db.add(Quota(subject_type="service_account", subject_id=account.id, limits=limits))
    else:
        quota.limits = limits
    audit(db, session, request, "service_account.policy_changed", "service_account", account.id, after={"purpose": account.purpose, "models": account.allowed_models, "scopes": account.allowed_scopes, "endpoints": account.allowed_endpoints, "limits": limits})
    db.commit()
    return RedirectResponse("/admin/service-accounts", 303)


@app.get("/admin/api-keys", response_class=HTMLResponse)
def api_keys_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    return render(
        request, "api_keys.html", session=session,
        keys=db.scalars(select(APIKey).order_by(APIKey.created_at.desc())).all(),
        users=db.scalars(select(User).where(User.enabled.is_(True)).order_by(User.email)).all(),
        accounts=db.scalars(select(ServiceAccount).where(ServiceAccount.enabled.is_(True)).order_by(ServiceAccount.name)).all(),
        created_secret=None,
    )


@app.post("/admin/api-keys", response_class=HTMLResponse)
def api_key_create(
    request: Request, name: str = Form(), owner_type: str = Form(), owner_id: int = Form(),
    allowed_models: str = Form(""), allowed_cidrs: str = Form(""), scopes: str = Form("models,chat"),
    allowed_endpoints: str = Form(""),
    requests_per_minute: int = Form(60), tokens_per_minute: int = Form(60000), concurrent_requests: int = Form(4),
    requests_per_day: int = Form(10000), requests_per_month: int = Form(100000),
    tokens_per_day: int = Form(2000000), tokens_per_month: int = Form(20000000),
    max_input_tokens: int = Form(32768), max_output_tokens: int = Form(8192), expires_at: str = Form(""),
    csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    cidrs = [value.strip() for value in allowed_cidrs.split(",") if value.strip()]
    try:
        parse_networks(cidrs)
        endpoints = normalize_endpoints(value.strip() for value in allowed_endpoints.split(","))
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    secret, key_id, prefix, secret_hash = generate_api_key(settings)
    if owner_type == "user" and db.get(User, owner_id) is None:
        raise HTTPException(422, "user owner not found")
    if owner_type == "service_account" and db.get(ServiceAccount, owner_id) is None:
        raise HTTPException(422, "service account owner not found")
    expiry = None
    if expires_at:
        try:
            expiry = datetime.fromisoformat(expires_at)
            expiry = expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry.astimezone(timezone.utc)
        except ValueError:
            raise HTTPException(422, "invalid key expiry timestamp") from None
    key = APIKey(
        name=name.strip()[:160], key_id=key_id, key_prefix=prefix, secret_hash=secret_hash,
        user_id=owner_id if owner_type == "user" else None,
        service_account_id=owner_id if owner_type == "service_account" else None,
        allowed_models=[value.strip() for value in allowed_models.split(",") if value.strip()],
        allowed_cidrs=cidrs,
        scopes=[value.strip() for value in scopes.split(",") if value.strip()],
        allowed_endpoints=endpoints,
        requests_per_minute=max(0, requests_per_minute), tokens_per_minute=max(0, tokens_per_minute),
        concurrent_requests=max(1, concurrent_requests),
        requests_per_day=max(0, requests_per_day), requests_per_month=max(0, requests_per_month),
        tokens_per_day=max(0, tokens_per_day), tokens_per_month=max(0, tokens_per_month),
        max_input_tokens=max(1, max_input_tokens), max_output_tokens=max(1, max_output_tokens),
        expires_at=expiry,
    )
    if key.user_id is None and key.service_account_id is None:
        raise HTTPException(422, "valid owner is required")
    db.add(key)
    db.flush()
    audit(db, session, request, "api_key.created", "api_key", key.id, after={"prefix": prefix, "models": key.allowed_models, "cidrs": cidrs})
    db.commit()
    return render(
        request, "api_keys.html", session=session,
        keys=db.scalars(select(APIKey).order_by(APIKey.created_at.desc())).all(),
        users=db.scalars(select(User).where(User.enabled.is_(True)).order_by(User.email)).all(),
        accounts=db.scalars(select(ServiceAccount).where(ServiceAccount.enabled.is_(True)).order_by(ServiceAccount.name)).all(),
        created_secret=secret,
    )


@app.post("/admin/api-keys/{key_id}/revoke")
def api_key_revoke(key_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    key = db.get(APIKey, key_id)
    if key is None:
        raise HTTPException(404)
    key.enabled = False
    key.revoked_at = datetime.now(timezone.utc)
    audit(db, session, request, "api_key.revoked", "api_key", key.id, after={"prefix": key.key_prefix})
    db.commit()
    return RedirectResponse("/admin/api-keys", 303)


@app.post("/admin/api-keys/{key_id}/rotate", response_class=HTMLResponse)
def api_key_rotate(key_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    key = db.get(APIKey, key_id)
    if key is None:
        raise HTTPException(404)
    secret, new_key_id, prefix, secret_hash = generate_api_key(settings)
    key.key_id, key.key_prefix, key.secret_hash = new_key_id, prefix, secret_hash
    key.enabled, key.revoked_at = True, None
    audit(db, session, request, "api_key.rotated", "api_key", key.id, after={"prefix": prefix})
    db.commit()
    return render(
        request, "api_keys.html", session=session,
        keys=db.scalars(select(APIKey).order_by(APIKey.created_at.desc())).all(),
        users=db.scalars(select(User).where(User.enabled.is_(True)).order_by(User.email)).all(),
        accounts=db.scalars(select(ServiceAccount).where(ServiceAccount.enabled.is_(True)).order_by(ServiceAccount.name)).all(),
        created_secret=secret,
    )


@app.get("/admin/models", response_class=HTMLResponse)
def models_page(request: Request, capability: str = "", db: Session = Depends(get_db)):
    session = require_admin(request, db)
    all_models = db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all()
    selected_capability = capability.strip().lower().replace(" ", "_")
    models = [model for model in all_models if not selected_capability or selected_capability in model_capabilities(model)]
    hardware = {}
    try:
        hardware = json.loads((DATA_ROOT / "hardware" / "current.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    plans = {}
    for model in models:
        if model.instance and model.download_status == "downloaded" and not model.instance.desired_active:
            try:
                plans[model.id] = activation_plan(db, model, model.instance, settings)
            except RuntimeOperationError as exc:
                plans[model.id] = {"can_activate": False, "requires_switch": False, "reason": str(exc)}
    usage_rows = db.execute(
        select(
            UsageRecord.model_alias,
            func.count(UsageRecord.id),
            func.coalesce(func.sum(UsageRecord.total_tokens), 0),
        ).group_by(UsageRecord.model_alias)
    ).all()
    usage_map = {alias: {"requests": count, "tokens": int(tokens or 0)} for alias, count, tokens in usage_rows}
    accounts = db.scalars(select(ServiceAccount).where(ServiceAccount.enabled.is_(True)).order_by(ServiceAccount.name)).all()
    account_map = {
        model.alias: [account.name for account in accounts if not account.allowed_models or model.alias in account.allowed_models]
        for model in models
    }
    return render(
        request, "models.html", session=session, models=models,
        storage_used=sum(model.size_bytes or 0 for model in all_models),
        storage_free=hardware.get("storage", {}).get("free_bytes"),
        storage_reserve=settings.ai_disk_reserve_gb * 1024**3,
        capability_options=sorted(MODEL_CAPABILITIES), selected_capability=selected_capability,
        capability_map={model.id: sorted(model_capabilities(model)) for model in models},
        activation_plans=plans, usage_map=usage_map, account_map=account_map,
    )


@app.post("/admin/models")
def model_create(
    request: Request, hf_model_id: str = Form(), revision: str = Form("main"), alias: str = Form(),
    capabilities: str = Form("chat,completions"), estimated_weight_gb: float = Form(0), max_model_len: int = Form(4096),
    quantization: str = Form(""), dtype: str = Form("auto"), trust_remote_code: bool = Form(False),
    tool_calling: bool = Form(False), tool_call_parser: str = Form(""), csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    alias = alias.strip().lower()
    name = container_name_for(alias)
    if db.scalar(select(ModelRecord).where(ModelRecord.alias == alias)):
        raise HTTPException(409, "model alias already exists")
    if not hf_model_id.strip() or "/" not in hf_model_id.strip():
        raise HTTPException(422, "a Hugging Face organization/model ID is required")
    if trust_remote_code and request.headers.get("x-confirm-trust-remote-code") != "accepted":
        # HTML checkbox is explicit acceptance; this guard is intentionally not
        # used by the form path. It documents the API contract for future JSON UI.
        pass
    try:
        normalized_capabilities = normalize_capabilities(
            (value.strip() for value in capabilities.split(",")), tool_calling=tool_calling
        )
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    model = ModelRecord(
        hf_model_id=hf_model_id.strip(), revision=revision.strip() or "main", alias=alias,
        capabilities=normalized_capabilities,
        estimated_weight_gb=estimated_weight_gb or None, max_model_len=max(256, max_model_len),
        quantization=quantization.strip() or None, dtype=dtype.strip() or "auto", trust_remote_code=trust_remote_code,
        tool_calling=tool_calling, tool_call_parser=tool_call_parser.strip() or None,
    )
    model.instance = ModelInstance(container_name=name, internal_url=f"http://{name}:8000")
    db.add(model)
    db.flush()
    audit(db, session, request, "model.registered", "model", model.id, after={"model_id": model.hf_model_id, "alias": model.alias})
    db.commit()
    return RedirectResponse("/admin/models", 303)


async def controller_action(model_id: int, action: str, params: dict[str, Any] | None = None) -> httpx.Response:
    async with httpx.AsyncClient(timeout=900) as client:
        return await client.post(
            f"{settings.controller_internal_url}/models/{model_id}/{action}",
            headers={"Authorization": f"Bearer {settings.controller_token}"},
            params=params,
        )


@app.post("/admin/models/{model_id}/action/{action}")
async def model_action(model_id: int, action: str, request: Request, csrf_token: str = Form(), confirmation: str = Form(""), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    if action not in {"download", "activate", "switch", "deactivate", "restart", "delete-record", "delete-weights"}:
        raise HTTPException(404)
    model = db.get(ModelRecord, model_id)
    if model is None:
        raise HTTPException(404)
    controller_name = action
    params = None
    if action in {"delete-record", "delete-weights"}:
        if model.instance and model.instance.desired_active:
            raise HTTPException(409, "deactivate the model before deleting it")
        if action == "delete-weights" and confirmation != "DELETE":
            raise HTTPException(422, "type DELETE to confirm permanent weight deletion")
        controller_name = "delete"
        params = {"delete_weights": action == "delete-weights"}
    response = await controller_action(model_id, controller_name, params)
    audit(db, session, request, f"model.{action}", "model", model_id, result="success" if response.is_success else "failure")
    db.commit()
    if not response.is_success:
        raise HTTPException(response.status_code, response.text[:1000])
    return RedirectResponse("/admin/models", 303)


@app.get("/admin/models/{model_id}/inspect/{view}", response_class=HTMLResponse)
async def model_inspect(model_id: int, view: str, request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    model = db.get(ModelRecord, model_id)
    if view not in {"compatibility", "metrics", "logs"} or model is None:
        raise HTTPException(404)
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.get(
            f"{settings.controller_internal_url}/models/{model_id}/{view}",
            headers={"Authorization": f"Bearer {settings.controller_token}"},
        )
    content = response.text
    structured = None
    error = None
    if response.is_success and view == "compatibility":
        try:
            structured = response.json()
            content = json.dumps(structured, indent=2, sort_keys=True)
        except (ValueError, TypeError):
            error = "The controller returned invalid compatibility data."
    elif not response.is_success:
        try:
            detail = response.json().get("detail", "")
        except (ValueError, AttributeError):
            detail = ""
        error = str(detail or "The requested model inspection is unavailable.")[:1000]
        content = ""
    rendered = render(
        request,
        "model_inspect.html",
        session=session,
        model=model,
        view=view,
        title={"compatibility": "Compatibility", "metrics": "Metrics", "logs": "Runtime logs"}[view],
        content=content,
        structured=structured,
        error=error,
    )
    rendered.headers["Cache-Control"] = "no-store"
    if not response.is_success:
        rendered.status_code = response.status_code
    return rendered


@app.post("/admin/models/{model_id}/default")
def model_default(model_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    model = db.get(ModelRecord, model_id)
    if model is None:
        raise HTTPException(404)
    db.query(ModelRecord).update({ModelRecord.is_default: False})
    model.is_default = True
    audit(db, session, request, "model.default_changed", "model", model_id, after={"alias": model.alias})
    db.commit()
    return RedirectResponse("/admin/models", 303)


@app.post("/admin/models/{model_id}/configure")
def model_configure(
    model_id: int, request: Request, alias: str = Form(), max_model_len: int = Form(4096),
    capabilities: str = Form("chat,completions"), tool_calling: bool = Form(False), tool_call_parser: str = Form(""),
    gpu_assignment: str = Form(""), tensor_parallel_size: int = Form(1), pipeline_parallel_size: int = Form(1),
    max_num_seqs: int = Form(4), gpu_memory_utilization: float = Form(0.82), cpu_offload_gb: float = Form(0),
    swap_space_gb: float = Form(4), performance_profile: str = Form("AUTO"), system_prompt: str = Form(""),
    chat_template: str = Form(""), csrf_token: str = Form(), db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    model = db.get(ModelRecord, model_id)
    if model is None or model.instance is None:
        raise HTTPException(404, "model instance not found")
    if model.instance.desired_active:
        raise HTTPException(409, "deactivate the model before changing runtime configuration")
    alias = alias.strip().lower()
    name = container_name_for(alias)
    if db.scalar(select(ModelRecord).where(ModelRecord.alias == alias, ModelRecord.id != model.id)):
        raise HTTPException(409, "model alias already exists")
    try:
        gpus = sorted({int(value.strip()) for value in gpu_assignment.split(",") if value.strip()})
    except ValueError:
        raise HTTPException(422, "GPU assignment must be comma-separated numeric indexes") from None
    if any(index < 0 for index in gpus):
        raise HTTPException(422, "GPU indexes cannot be negative")
    if tensor_parallel_size < 1 or pipeline_parallel_size < 1 or max_num_seqs < 1 or max_model_len < 256:
        raise HTTPException(422, "parallelism, context and sequence values must be positive")
    if gpus and tensor_parallel_size * pipeline_parallel_size != len(gpus):
        raise HTTPException(422, "selected GPU count must equal tensor x pipeline parallel workers")
    if not 0.1 <= gpu_memory_utilization <= 0.95 or cpu_offload_gb < 0 or swap_space_gb < 0:
        raise HTTPException(422, "invalid memory configuration")
    if performance_profile not in {"AUTO", "CONSERVATIVE", "BALANCED", "PERFORMANCE", "MAXIMUM", "CUSTOM"}:
        raise HTTPException(422, "invalid performance profile")
    before = {"alias": model.alias, "instance": {"gpus": model.instance.gpu_assignment, "tensor_parallel_size": model.instance.tensor_parallel_size, "profile": model.instance.performance_profile}}
    try:
        normalized_capabilities = normalize_capabilities(
            (value.strip() for value in capabilities.split(",")), tool_calling=tool_calling
        )
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from None
    model.alias = alias
    model.capabilities = normalized_capabilities
    model.tool_calling = tool_calling
    model.tool_call_parser = tool_call_parser.strip() or None
    model.max_model_len = max_model_len
    model.system_prompt = system_prompt.strip() or None
    model.chat_template = chat_template.strip() or None
    model.instance.container_name = name
    model.instance.internal_url = f"http://{name}:8000"
    model.instance.gpu_assignment = gpus
    model.instance.tensor_parallel_size = tensor_parallel_size
    model.instance.pipeline_parallel_size = pipeline_parallel_size
    model.instance.max_num_seqs = max_num_seqs
    model.instance.gpu_memory_utilization = gpu_memory_utilization
    model.instance.cpu_offload_gb = cpu_offload_gb
    model.instance.swap_space_gb = swap_space_gb
    model.instance.performance_profile = performance_profile
    after = {"alias": model.alias, "instance": {"gpus": gpus, "tensor_parallel_size": tensor_parallel_size, "profile": performance_profile}}
    audit(db, session, request, "model.configuration_changed", "model", model.id, before=before, after=after)
    db.commit()
    return RedirectResponse("/admin/models", 303)


@app.get("/admin/security", response_class=HTMLResponse)
def security_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    return render(request, "security.html", session=session, rules=db.scalars(select(IPRule).order_by(IPRule.subject_type, IPRule.cidr)).all())


@app.post("/admin/security/ip-rules")
def ip_rule_create(request: Request, cidr: str = Form(), subject_type: str = Form("global"), subject_id: str = Form(""), description: str = Form(""), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    network = str(parse_networks([cidr])[0])
    if subject_type not in {"global", "service_account", "api_key"}:
        raise HTTPException(422, "invalid IP rule scope")
    parsed_subject = int(subject_id) if subject_id.strip().isdigit() else None
    if subject_type != "global" and parsed_subject is None:
        raise HTTPException(422, "a numeric subject ID is required")
    rule = IPRule(subject_type=subject_type, subject_id=parsed_subject, cidr=network, description=description.strip()[:255])
    db.add(rule)
    db.flush()
    audit(db, session, request, "ip_rule.created", "ip_rule", rule.id, after={"cidr": network})
    db.commit()
    return RedirectResponse("/admin/security", 303)


@app.post("/admin/security/ip-rules/{rule_id}/delete")
def ip_rule_delete(rule_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    rule = db.get(IPRule, rule_id)
    if rule is None:
        raise HTTPException(404)
    audit(db, session, request, "ip_rule.deleted", "ip_rule", rule.id, before={"cidr": rule.cidr})
    db.delete(rule)
    db.commit()
    return RedirectResponse("/admin/security", 303)


@app.get("/admin/usage", response_class=HTMLResponse)
def usage_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    rows = db.scalars(select(UsageRecord).order_by(UsageRecord.occurred_at.desc()).limit(500)).all()
    totals = db.execute(select(func.count(UsageRecord.id), func.coalesce(func.sum(UsageRecord.total_tokens), 0))).one()
    accounts = {account.id: account for account in db.scalars(select(ServiceAccount)).all()}
    keys = {key.id: key for key in db.scalars(select(APIKey)).all()}
    return render(request, "usage.html", session=session, rows=rows, totals=totals, accounts=accounts, keys=keys)


@app.get("/admin/performance", response_class=HTMLResponse)
def performance_page(request: Request, result: str = "", db: Session = Depends(get_db)):
    session = require_admin(request, db)
    hardware = {}
    changes = {}
    try:
        hardware = json.loads((DATA_ROOT / "hardware" / "current.json").read_text(encoding="utf-8"))
        changes = json.loads((DATA_ROOT / "hardware" / "change.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    notices = {
        "deactivated": "Model stopped. You can now validate and apply a performance profile.",
        "applied": "Performance profile validated and saved. The model remains stopped.",
        "applied-activated": "Performance profile validated, saved and activated.",
    }
    return render(
        request,
        "performance.html",
        session=session,
        models=db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all(),
        hardware=hardware,
        changes=changes,
        notice=notices.get(result),
    )


@app.get("/admin/jupyter", response_class=HTMLResponse)
def jupyter_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    environment = load_environment_snapshot(ENVIRONMENT_SNAPSHOT_PATH)
    notebooks = []
    try:
        root = NOTEBOOKS_ROOT.resolve()
        for path in sorted(root.rglob("*.ipynb"), key=lambda item: item.stat().st_mtime, reverse=True)[:200]:
            resolved = path.resolve()
            if root not in resolved.parents:
                continue
            stat = resolved.stat()
            notebooks.append(
                {
                    "name": resolved.name,
                    "path": str(resolved.relative_to(root)),
                    "size_bytes": stat.st_size,
                    "modified_at": datetime.fromtimestamp(stat.st_mtime, timezone.utc),
                }
            )
    except OSError:
        pass
    active_models = db.scalars(
        select(ModelRecord)
        .join(ModelInstance)
        .where(ModelInstance.desired_active.is_(True), ModelInstance.status == "ready")
        .order_by(ModelRecord.alias)
    ).all()
    return render(
        request,
        "jupyter.html",
        session=session,
        environment=environment,
        notebooks=notebooks,
        active_models=active_models,
    )


@app.post("/admin/performance/{model_id}/deactivate")
async def performance_deactivate(model_id: int, request: Request, csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    model = db.get(ModelRecord, model_id)
    if model is None or model.instance is None:
        raise HTTPException(404, "model instance not found")
    response = await controller_action(model_id, "deactivate")
    audit(
        db,
        session,
        request,
        "model.deactivate_for_performance",
        "model",
        model_id,
        result="success" if response.is_success else "failure",
    )
    db.commit()
    if not response.is_success:
        raise HTTPException(response.status_code, response.text[:1000])
    return RedirectResponse("/admin/performance?result=deactivated", 303)


@app.post("/admin/performance/{model_id}")
async def performance_apply(
    model_id: int,
    request: Request,
    profile: str = Form(),
    confirm_maximum: bool = Form(False),
    activate_after_apply: bool = Form(False),
    csrf_token: str = Form(),
    db: Session = Depends(get_db),
):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    model = db.get(ModelRecord, model_id)
    if model is None or model.instance is None:
        raise HTTPException(404, "model instance not found")
    if model.instance.desired_active:
        raise HTTPException(409, "deactivate the model before applying performance changes")
    if profile == "MAXIMUM" and not confirm_maximum:
        raise HTTPException(422, "MAXIMUM requires explicit acknowledgement of the reduced safety reserve")
    try:
        hardware = json.loads((DATA_ROOT / "hardware" / "current.json").read_text(encoding="utf-8"))
        recommendation = recommend_profile(profile, hardware, model, model.instance)
    except (OSError, json.JSONDecodeError, RuntimeOperationError) as exc:
        raise HTTPException(409, str(exc)) from None
    before = {"profile": model.instance.performance_profile, "max_model_len": model.max_model_len, "max_num_seqs": model.instance.max_num_seqs}
    model.instance.performance_profile = recommendation["profile"]
    model.instance.gpu_memory_utilization = recommendation["gpu_memory_utilization"]
    model.max_model_len = recommendation["max_model_len"]
    model.instance.max_num_seqs = recommendation["max_num_seqs"]
    model.instance.max_num_batched_tokens = recommendation.get("max_num_batched_tokens")
    try:
        validation = compatibility_analysis(db, model, model.instance, settings)
    except RuntimeOperationError as exc:
        db.rollback()
        raise HTTPException(409, str(exc)) from None
    recommendation["compatibility"] = validation
    if not validation.get("safe"):
        db.rollback()
        raise HTTPException(409, f"profile is unsafe for current hardware: {validation['label']}")
    audit(db, session, request, "performance.changed", "model", model.id, before=before, after=recommendation)
    db.commit()
    if activate_after_apply:
        response = await controller_action(model_id, "activate")
        if not response.is_success:
            raise HTTPException(response.status_code, response.text[:1000])
        return RedirectResponse("/admin/performance?result=applied-activated", 303)
    return RedirectResponse("/admin/performance?result=applied", 303)


@app.get("/admin/settings", response_class=HTMLResponse)
def settings_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    global_prompt = db.get(SystemSetting, "global_system_prompt")
    api_default = db.get(SystemSetting, "api_default_model")
    portal_default = db.get(SystemSetting, "portal_default_model")
    return render(
        request, "settings.html", session=session, global_system_prompt=global_prompt.value if global_prompt else "",
        api_default_model=api_default.value if api_default else "", portal_default_model=portal_default.value if portal_default else "",
        models=db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all(),
    )


@app.post("/admin/settings")
def settings_update(request: Request, global_system_prompt: str = Form(""), api_default_model: str = Form(""), portal_default_model: str = Form(""), csrf_token: str = Form(), db: Session = Depends(get_db)):
    session = require_admin(request, db)
    verify_csrf(request, session, csrf_token)
    aliases = set(db.scalars(select(ModelRecord.alias)).all())
    api_default_model = api_default_model.strip()
    portal_default_model = portal_default_model.strip()
    if (api_default_model and api_default_model not in aliases) or (portal_default_model and portal_default_model not in aliases):
        raise HTTPException(422, "default model must be a registered alias")
    values = {
        "global_system_prompt": global_system_prompt.strip(),
        "api_default_model": api_default_model,
        "portal_default_model": portal_default_model,
    }
    for key, value in values.items():
        setting = db.get(SystemSetting, key)
        if setting is None:
            db.add(SystemSetting(key=key, value=value, secret=False))
        else:
            setting.value = value
    audit(db, session, request, "settings.changed", "system_setting", "defaults", after={"global_prompt_configured": bool(values["global_system_prompt"]), "api_default_model": api_default_model, "portal_default_model": portal_default_model})
    db.commit()
    return RedirectResponse("/admin/settings", 303)


@app.get("/admin/audit", response_class=HTMLResponse)
def audit_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    rows = db.scalars(select(AuditLog).order_by(AuditLog.occurred_at.desc()).limit(500)).all()
    return render(request, "audit.html", session=session, rows=rows)


@app.get("/admin/operations", response_class=HTMLResponse)
def operations_page(request: Request, db: Session = Depends(get_db)):
    session = require_admin(request, db)
    return render(request, "operations.html", session=session)

