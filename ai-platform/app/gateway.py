from __future__ import annotations

import json
import ipaddress
import logging
import time
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from redis import Redis
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import __version__
from .capabilities import model_capabilities
from .codex_setup import codex_installer_script
from .config import get_settings
from .db import SessionLocal, get_db
from .models import APIKey, IPRule, ModelInstance, ModelPermission, ModelRecord, Quota, SystemSetting, UsageRecord, User
from .policy import PolicyDenied, RedisPolicyLimiter, approximate_tokens, require_model_access, require_scope_access
from .security import (
    AuthenticationError,
    Principal,
    authenticate_api_key,
    constant_time_token,
    ip_allowed,
    resolve_client_ip,
)


settings = get_settings()
logger = logging.getLogger("ai.gateway")
redis_client = Redis.from_url(settings.redis_url, decode_responses=True)
REQUESTS = Counter("ai_gateway_requests_total", "Gateway requests", ["endpoint", "status"])
LATENCY = Histogram("ai_gateway_latency_seconds", "Gateway latency", ["endpoint"])

REASONING_TOKEN_BUDGETS = {
    "low": 2_048,
    "medium": 4_096,
    "high": 8_192,
}

app = FastAPI(title="vLLM AI Gateway", version=__version__, docs_url=None, redoc_url=None, openapi_url=None)
if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
        expose_headers=["X-Request-ID"],
        max_age=600,
    )


def request_id() -> str:
    return f"req_{uuid.uuid4().hex}"


def error_response(error_type: str, message: str, req_id: str, status: int) -> JSONResponse:
    REQUESTS.labels("error", str(status)).inc()
    return JSONResponse(
        {"error": {"type": error_type, "message": message, "request_id": req_id}},
        status_code=status,
        headers={"X-Request-ID": req_id},
    )


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, __: RequestValidationError) -> JSONResponse:
    req_id = request_id()
    return error_response("invalid_request", "The request is invalid.", req_id, 422)


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception) -> JSONResponse:
    req_id = getattr(request.state, "request_id", request_id())
    logger.exception("request failed request_id=%s type=%s", req_id, type(exc).__name__)
    return error_response("internal_error", "The request could not be completed.", req_id, 500)


@app.middleware("http")
async def request_context(request: Request, call_next):
    req_id = request_id()
    request.state.request_id = req_id
    peer = request.client.host if request.client else "0.0.0.0"
    request.state.client_ip = resolve_client_ip(
        peer,
        request.headers.get("x-forwarded-for") if constant_time_token(request.headers.get("x-ai-proxy-token", ""), settings.proxy_shared_token) else None,
        request.headers.get("x-real-ip") if constant_time_token(request.headers.get("x-ai-proxy-token", ""), settings.proxy_shared_token) else None,
        settings.trusted_proxy_networks,
    )
    if constant_time_token(request.headers.get("x-ai-internal-token", ""), settings.internal_gateway_token):
        try:
            request.state.client_ip = str(ipaddress.ip_address(request.headers.get("x-ai-client-ip", "")))
        except ValueError:
            pass
    response = await call_next(request)
    response.headers["X-Request-ID"] = req_id
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/health")
def health(db: Session = Depends(get_db)) -> dict:
    db.execute(select(1))
    redis_client.ping()
    return {"status": "ok", "version": __version__}


@app.get("/internal/metrics")
def metrics(request: Request) -> Response:
    peer = request.client.host if request.client else ""
    if not ip_allowed(peer, settings.trusted_proxy_networks, unrestricted_when_empty=False):
        return Response(status_code=404)
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def _bearer(request: Request) -> str:
    value = request.headers.get("authorization", "")
    if not value.lower().startswith("bearer "):
        raise AuthenticationError("missing_api_key", "An API key is required.")
    return value[7:].strip()


def authenticate(request: Request, db: Session) -> Principal:
    internal = request.headers.get("x-ai-internal-token", "")
    if internal:
        if not constant_time_token(internal, settings.internal_gateway_token):
            raise AuthenticationError("invalid_internal_auth", "Internal authentication failed.")
        try:
            user_id = int(request.headers.get("x-ai-user-id", ""))
        except ValueError:
            raise AuthenticationError("invalid_internal_auth", "Internal user identity is invalid.") from None
        user = db.get(User, user_id)
        if user is None or not user.enabled:
            raise AuthenticationError("account_disabled", "The user is unavailable.", 403)
        return Principal(kind="user", user_id=user.id)
    principal = authenticate_api_key(db, _bearer(request), settings)
    db.commit()
    return principal


def enforce_ip_policy(db: Session, principal: Principal, client_ip: str) -> None:
    configured = settings.global_allowed_networks
    db_global = db.scalars(select(IPRule).where(IPRule.subject_type == "global", IPRule.enabled.is_(True))).all()
    configured = configured + [rule.cidr for rule in db_global]
    if configured and not ip_allowed(client_ip, configured):
        raise PolicyDenied("ip_access_denied", "This source address is not allowed.")
    if principal.api_key and principal.api_key.allowed_cidrs and not ip_allowed(client_ip, principal.api_key.allowed_cidrs):
        raise PolicyDenied("ip_access_denied", "This API key cannot be used from this source address.")
    if principal.api_key_id:
        key_rules = db.scalars(
            select(IPRule).where(
                IPRule.subject_type == "api_key",
                IPRule.subject_id == principal.api_key_id,
                IPRule.enabled.is_(True),
            )
        ).all()
        if key_rules and not ip_allowed(client_ip, [rule.cidr for rule in key_rules]):
            raise PolicyDenied("ip_access_denied", "This API key cannot be used from this source address.")
    if principal.service_account_id:
        rules = db.scalars(
            select(IPRule).where(
                IPRule.subject_type == "service_account",
                IPRule.subject_id == principal.service_account_id,
                IPRule.enabled.is_(True),
            )
        ).all()
        if rules and not ip_allowed(client_ip, [rule.cidr for rule in rules]):
            raise PolicyDenied("ip_access_denied", "The service account cannot be used from this source address.")


def _user_model_allowed(
    db: Session,
    user_id: int,
    model: ModelRecord,
    tools_requested: bool = False,
    coding_requested: bool = False,
) -> bool:
    user = db.get(User, user_id)
    if user is not None and user.enabled and user.role == "super_admin":
        return True

    permissions = db.scalars(
        select(ModelPermission).where(ModelPermission.subject_type == "user", ModelPermission.subject_id == user_id)
    ).all()
    if not permissions:
        # Existing portal users keep access to general models, but a model
        # explicitly classified for coding/agentic work requires approval.
        return not coding_requested
    match = next((permission for permission in permissions if permission.model_id == model.id), None)
    return bool(
        match
        and match.can_chat
        and (not tools_requested or match.can_use_tools)
        and (not coding_requested or match.can_code)
    )


def authorize_model(
    db: Session,
    principal: Principal,
    model: ModelRecord,
    scope: str,
    endpoint: str,
    tools_requested: bool = False,
) -> None:
    capabilities = model_capabilities(model)
    coding_requested = bool(capabilities.intersection({"coding", "agentic"}))
    if principal.api_key:
        require_model_access(principal.api_key, model.alias, scope, endpoint)
        if tools_requested:
            require_scope_access(principal.api_key, "tools")
        if coding_requested:
            require_scope_access(principal.api_key, "coding")
    if principal.user_id and not _user_model_allowed(db, principal.user_id, model, tools_requested, coding_requested):
        raise PolicyDenied("model_access_denied", "This user cannot access the requested model.")
    if tools_requested and not model.tool_calling:
        raise PolicyDenied("tools_not_supported", "The requested model is not configured for tool calling.", 400)


def active_models(db: Session) -> list[ModelRecord]:
    return db.scalars(
        select(ModelRecord)
        .join(ModelInstance)
        .where(ModelInstance.desired_active.is_(True), ModelInstance.status == "ready")
        .order_by(ModelRecord.alias)
    ).all()


def codex_models(db: Session, principal: Principal) -> list[ModelRecord]:
    compatible: list[ModelRecord] = []
    for model in active_models(db):
        capabilities = model_capabilities(model)
        if "responses" not in capabilities or not capabilities.intersection({"coding", "agentic"}) or not model.tool_calling:
            continue
        try:
            authorize_model(db, principal, model, "responses", "/v1/responses", tools_requested=True)
        except PolicyDenied:
            continue
        compatible.append(model)
    return sorted(compatible, key=lambda model: (not model.is_default, model.alias))


def _scope_for(endpoint: str) -> str:
    return {"models": "models", "chat/completions": "chat", "completions": "completions", "embeddings": "embeddings", "responses": "responses"}[endpoint]


def _model_supports(model: ModelRecord, endpoint: str) -> bool:
    capability = {"chat/completions": "chat", "completions": "completions", "embeddings": "embeddings", "responses": "responses"}.get(endpoint)
    if capability is not None and capability not in model_capabilities(model):
        return False
    runtime_support = (model.config or {}).get("runtime_api_support")
    if isinstance(runtime_support, dict) and runtime_support.get("verified") is True:
        supported = runtime_support.get("endpoints", [])
        return f"/v1/{endpoint}" in supported
    return True


def _apply_reasoning_budget(payload: dict[str, Any], endpoint: str) -> None:
    """Translate OpenAI reasoning effort into vLLM's enforceable token budget."""
    effort: Any = None
    if endpoint == "responses":
        reasoning = payload.get("reasoning")
        if isinstance(reasoning, dict):
            effort = reasoning.get("effort")
    elif endpoint == "chat/completions":
        effort = payload.get("reasoning_effort")
    if effort is None:
        return
    if not isinstance(effort, str) or effort not in {"none", *REASONING_TOKEN_BUDGETS}:
        raise PolicyDenied(
            "invalid_reasoning_effort",
            "Reasoning effort must be one of: none, low, medium, high.",
            400,
        )
    # `none` is handled by vLLM's enable_thinking=False translation. Do not
    # attach a zero-token budget because no reasoning block should be opened.
    if effort == "none":
        payload.pop("thinking_token_budget", None)
        return
    payload["thinking_token_budget"] = REASONING_TOKEN_BUDGETS[effort]


def _default_model(db: Session) -> str | None:
    api_default = db.get(SystemSetting, "api_default_model")
    if api_default and isinstance(api_default.value, str) and api_default.value:
        # A configured but unavailable API default must fail explicitly later;
        # never substitute a different model behind the client's back.
        return api_default.value
    model = db.scalar(select(ModelRecord).join(ModelInstance).where(ModelRecord.is_default.is_(True), ModelInstance.status == "ready"))
    return model.alias if model else None


def _apply_system_prompt(db: Session, payload: dict[str, Any], model: ModelRecord, principal: Principal) -> None:
    if "messages" not in payload:
        return
    has_client_system = any(message.get("role") in {"system", "developer"} for message in payload.get("messages", []))
    if has_client_system and principal.service_account_id:
        account = principal.api_key.service_account if principal.api_key else None
        if account is not None and not account.allow_custom_system_messages:
            raise PolicyDenied("custom_system_prompt_denied", "This service account cannot provide custom system messages.")
    if has_client_system:
        return
    prompt = None
    if principal.user_id:
        user = db.get(User, principal.user_id)
        prompt = user.system_prompt if user else None
    prompt = prompt or model.system_prompt
    if not prompt:
        setting = db.get(SystemSetting, "global_system_prompt")
        prompt = setting.value if setting and isinstance(setting.value, str) else None
    if prompt:
        payload["messages"] = [{"role": "system", "content": prompt}, *payload["messages"]]


def _virtual_user_key(db: Session, user_id: int) -> Any:
    quota = db.scalar(select(Quota).where(Quota.subject_type == "user", Quota.subject_id == user_id))
    values = quota.limits if quota else {}
    defaults = {
        "requests_per_minute": 30, "tokens_per_minute": 30_000, "concurrent_requests": 2,
        "requests_per_day": 2_000, "requests_per_month": 30_000,
        "tokens_per_day": 500_000, "tokens_per_month": 5_000_000,
        "max_input_tokens": 16_384, "max_output_tokens": 4_096,
    }
    defaults.update({key: int(value) for key, value in values.items() if key in defaults})
    return SimpleNamespace(id=f"user-{user_id}", **defaults)


def _effective_api_key(db: Session, key: APIKey) -> Any:
    subject_type = "service_account" if key.service_account_id else "user"
    subject_id = key.service_account_id or key.user_id
    owner_quota = db.scalar(select(Quota).where(Quota.subject_type == subject_type, Quota.subject_id == subject_id))
    names = (
        "requests_per_minute", "tokens_per_minute", "concurrent_requests", "requests_per_day",
        "requests_per_month", "tokens_per_day", "tokens_per_month", "max_input_tokens", "max_output_tokens",
    )

    def stricter(key_value: int, owner_value: int | None) -> int:
        if owner_value is None:
            return key_value
        if key_value <= 0:
            return owner_value
        if owner_value <= 0:
            return key_value
        return min(key_value, owner_value)

    values = {name: stricter(int(getattr(key, name)), int(owner_quota.limits[name]) if owner_quota and name in owner_quota.limits else None) for name in names}
    return SimpleNamespace(id=key.id, **values)


def _record_usage(
    req_id: str,
    principal: Principal,
    client_ip: str,
    model: ModelRecord,
    endpoint: str,
    usage: dict[str, Any],
    start: float,
    status: int,
    streaming: bool,
    error_type: str | None = None,
    ttft_ms: int | None = None,
) -> None:
    with SessionLocal() as db:
        input_tokens = int(usage.get("prompt_tokens", usage.get("input_tokens", 0)) or 0)
        output_tokens = int(usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0)
        total_tokens = int(usage.get("total_tokens", input_tokens + output_tokens) or 0)
        db.add(UsageRecord(
            request_id=req_id,
            user_id=principal.user_id,
            service_account_id=principal.service_account_id,
            api_key_id=principal.api_key_id,
            source_ip=client_ip,
            model_alias=model.alias,
            model_instance_id=model.instance.id if model.instance else None,
            endpoint=f"/v1/{endpoint}",
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            total_tokens=total_tokens,
            latency_ms=int((time.monotonic() - start) * 1000),
            ttft_ms=ttft_ms,
            generation_ms=int((time.monotonic() - start) * 1000),
            http_status=status,
            success=200 <= status < 400,
            streaming=streaming,
            error_type=error_type,
        ))
        db.commit()


def _extract_usage(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    usage = value.get("usage")
    if isinstance(usage, dict):
        return usage
    response = value.get("response")
    if isinstance(response, dict) and isinstance(response.get("usage"), dict):
        return response["usage"]
    return {}


@app.get("/v1/models")
def models(request: Request, db: Session = Depends(get_db)):
    req_id = request.state.request_id
    try:
        principal = authenticate(request, db)
        enforce_ip_policy(db, principal, request.state.client_ip)
        rows = []
        for model in active_models(db):
            try:
                authorize_model(db, principal, model, "models", "/v1/models")
            except PolicyDenied:
                continue
            rows.append(
                {
                    "id": model.alias,
                    "object": "model",
                    "created": int(model.created_at.timestamp()),
                    "owned_by": "vllm-ai-platform",
                    "capabilities": sorted(model_capabilities(model)),
                }
            )
        return JSONResponse({"object": "list", "data": rows}, headers={"X-Request-ID": req_id})
    except (AuthenticationError, PolicyDenied) as exc:
        return error_response(exc.error_type, exc.message, req_id, exc.status_code)


@app.get("/v1/codex/install")
def codex_install(request: Request, platform: str, db: Session = Depends(get_db)):
    req_id = request.state.request_id
    try:
        normalized_platform = platform.strip().lower()
        if normalized_platform not in {"windows", "linux", "macos"}:
            raise PolicyDenied("invalid_platform", "Platform must be windows, linux or macos.", 400)
        principal = authenticate(request, db)
        enforce_ip_policy(db, principal, request.state.client_ip)
        models = codex_models(db, principal)
        if not models:
            raise PolicyDenied(
                "codex_configuration_unavailable",
                "This API key cannot access an active Responses, tools and coding compatible model.",
                403,
            )
        if settings.cloudflare_api_hostname:
            api_base_url = f"https://{settings.cloudflare_api_hostname.strip().rstrip('.')}/v1"
        else:
            api_base_url = f"{str(request.base_url).rstrip('/')}/v1"
        script = codex_installer_script(models, api_base_url, normalized_platform)
        extension = "ps1" if normalized_platform == "windows" else "sh"
        return Response(
            content=script,
            media_type="text/plain; charset=utf-8",
            headers={
                "Content-Disposition": f'attachment; filename="omnivis-codex-setup.{extension}"',
                "X-Request-ID": req_id,
            },
        )
    except (AuthenticationError, PolicyDenied) as exc:
        return error_response(exc.error_type, exc.message, req_id, exc.status_code)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request, db: Session = Depends(get_db)):
    return await proxy(request, db, "chat/completions")


@app.post("/v1/completions")
async def completions(request: Request, db: Session = Depends(get_db)):
    return await proxy(request, db, "completions")


@app.post("/v1/embeddings")
async def embeddings(request: Request, db: Session = Depends(get_db)):
    return await proxy(request, db, "embeddings")


@app.post("/v1/responses")
async def responses(request: Request, db: Session = Depends(get_db)):
    return await proxy(request, db, "responses")


async def proxy(request: Request, db: Session, endpoint: str):
    req_id = request.state.request_id
    start = time.monotonic()
    lease = None
    client: httpx.AsyncClient | None = None
    upstream: httpx.Response | None = None
    try:
        body = await request.body()
        if len(body) > settings.max_request_bytes:
            raise PolicyDenied("request_too_large", "The request body exceeds the configured limit.", 413)
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise PolicyDenied("invalid_json", "The request body must be valid JSON.", 400) from None
        if not isinstance(payload, dict):
            raise PolicyDenied("invalid_request", "The request body must be a JSON object.", 400)
        principal = authenticate(request, db)
        enforce_ip_policy(db, principal, request.state.client_ip)
        alias = payload.get("model") or _default_model(db)
        if not alias:
            raise PolicyDenied("model_required", "A model must be selected.", 400)
        model = db.scalar(select(ModelRecord).where(ModelRecord.alias == alias))
        if model is None or model.instance is None or model.instance.status != "ready" or not model.instance.desired_active:
            raise PolicyDenied("model_unavailable", "The requested model is not available.", 503)
        if not _model_supports(model, endpoint):
            raise PolicyDenied("endpoint_not_supported", "The requested model does not support this endpoint.", 400)
        scope = _scope_for(endpoint)
        authorize_model(db, principal, model, scope, f"/v1/{endpoint}", bool(payload.get("tools")))
        _apply_system_prompt(db, payload, model, principal)
        _apply_reasoning_budget(payload, endpoint)
        estimated = approximate_tokens(payload)
        limit_key = _effective_api_key(db, principal.api_key) if principal.api_key else _virtual_user_key(db, principal.user_id or 0)
        if estimated > limit_key.max_input_tokens:
            raise PolicyDenied("input_token_limit", "The estimated input exceeds the configured token limit.", 413)
        try:
            output_requested = int(
                payload.get(
                    "max_output_tokens",
                    payload.get("max_tokens", payload.get("max_completion_tokens", 0)),
                )
                or 0
            )
        except (TypeError, ValueError):
            raise PolicyDenied("invalid_request", "The requested output-token limit must be an integer.", 400) from None
        if output_requested < 0:
            raise PolicyDenied("invalid_request", "The requested output-token limit cannot be negative.", 400)
        if output_requested > limit_key.max_output_tokens:
            raise PolicyDenied("output_token_limit", "The requested output exceeds the configured token limit.", 400)
        lease = RedisPolicyLimiter(redis_client).acquire(limit_key, estimated)
        model.last_used_at = datetime.now(timezone.utc)
        db.commit()

        stream = bool(payload.get("stream"))
        if stream and endpoint != "responses":
            stream_options = payload.setdefault("stream_options", {})
            if isinstance(stream_options, dict):
                stream_options["include_usage"] = True
        payload["model"] = model.alias
        client = httpx.AsyncClient(timeout=httpx.Timeout(600, connect=15), follow_redirects=False)
        upstream_request = client.build_request(
            "POST",
            f"{model.instance.internal_url}/v1/{endpoint}",
            json=payload,
            headers={"X-Request-ID": req_id, "Accept": "text/event-stream" if stream else "application/json"},
        )
        upstream = await client.send(upstream_request, stream=stream)
        if upstream.status_code >= 400:
            upstream_status = upstream.status_code
            await upstream.aread()
            lease.release()
            await upstream.aclose()
            await client.aclose()
            status = upstream_status if upstream_status < 500 else 502
            _record_usage(req_id, principal, request.state.client_ip, model, endpoint, {}, start, status, stream, error_type="upstream_rejected")
            return error_response("upstream_rejected", "The model service rejected the request.", req_id, status)
        content_type = upstream.headers.get("content-type", "application/json")
        if not stream:
            content = await upstream.aread()
            usage: dict[str, Any] = {}
            try:
                parsed = json.loads(content)
                usage = _extract_usage(parsed)
            except (json.JSONDecodeError, AttributeError):
                pass
            RedisPolicyLimiter(redis_client).record_output(limit_key, int(usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0))
            lease.release()
            await upstream.aclose()
            await client.aclose()
            _record_usage(req_id, principal, request.state.client_ip, model, endpoint, usage, start, upstream.status_code, False)
            REQUESTS.labels(endpoint, str(upstream.status_code)).inc()
            LATENCY.labels(endpoint).observe(time.monotonic() - start)
            return Response(content=content, status_code=upstream.status_code, media_type=content_type, headers={"X-Request-ID": req_id})

        async def stream_body():
            usage: dict[str, Any] = {}
            ttft: int | None = None
            status = upstream.status_code
            try:
                async for chunk in upstream.aiter_bytes():
                    if ttft is None and chunk:
                        ttft = int((time.monotonic() - start) * 1000)
                    for line in chunk.splitlines():
                        if line.startswith(b"data: ") and line[6:] != b"[DONE]":
                            try:
                                event = json.loads(line[6:])
                                event_usage = _extract_usage(event)
                                if event_usage:
                                    usage = event_usage
                            except (json.JSONDecodeError, AttributeError):
                                pass
                    yield chunk
            except Exception:
                status = 502
                logger.exception("stream interrupted request_id=%s", req_id)
            finally:
                output = int(usage.get("completion_tokens", usage.get("output_tokens", 0)) or 0)
                RedisPolicyLimiter(redis_client).record_output(limit_key, output)
                lease.release()
                await upstream.aclose()
                await client.aclose()
                _record_usage(req_id, principal, request.state.client_ip, model, endpoint, usage, start, status, True, ttft_ms=ttft)
                REQUESTS.labels(endpoint, str(status)).inc()
                LATENCY.labels(endpoint).observe(time.monotonic() - start)

        return StreamingResponse(stream_body(), status_code=upstream.status_code, media_type=content_type, headers={"X-Request-ID": req_id, "X-Accel-Buffering": "no"})
    except (AuthenticationError, PolicyDenied) as exc:
        if lease:
            lease.release()
        if upstream:
            await upstream.aclose()
        if client:
            await client.aclose()
        return error_response(exc.error_type, exc.message, req_id, exc.status_code)
    except httpx.HTTPError:
        if lease:
            lease.release()
        if upstream:
            await upstream.aclose()
        if client:
            await client.aclose()
        logger.warning("upstream unavailable request_id=%s endpoint=%s", req_id, endpoint)
        return error_response("upstream_unavailable", "The model service is unavailable.", req_id, 503)
    except Exception:
        if lease:
            lease.release()
        if upstream:
            await upstream.aclose()
        if client:
            await client.aclose()
        raise
