from __future__ import annotations

import json
import secrets
import shutil
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from sqlalchemy.orm import Session

from . import __version__
from .config import get_settings
from .db import SessionLocal, get_db
from .models import AuditLog, ModelRecord, utcnow
from .runtime import ModelRuntime, RuntimeOperationError, activation_plan, compatibility_analysis, download_model, managed_model_root, sanitize_runtime_error
from .security import constant_time_token


settings = get_settings()
app = FastAPI(title="vLLM AI Runtime Controller", version=__version__, docs_url=None, redoc_url=None, openapi_url=None)


def require_controller_token(authorization: str | None = Header(default=None)) -> None:
    token = authorization.removeprefix("Bearer ").strip() if authorization else ""
    if not constant_time_token(token, settings.controller_token):
        raise HTTPException(401, "controller authentication failed")


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "version": __version__}


@app.get("/hardware", dependencies=[Depends(require_controller_token)])
def hardware() -> dict:
    path = Path("/platform/hardware/current.json")
    if settings.ai_runtime_mode == "native" or not path.exists():
        path = settings.ai_platform_root / "hardware" / "current.json"
    if not path.exists():
        raise HTTPException(503, "hardware snapshot unavailable")
    return json.loads(path.read_text(encoding="utf-8"))


def get_model_or_404(db: Session, model_id: int) -> ModelRecord:
    model = db.get(ModelRecord, model_id)
    if model is None:
        raise HTTPException(404, "model not found")
    return model


def set_guided_install_state(
    model: ModelRecord,
    *,
    status: str,
    phase: str,
    activate: bool | None = None,
    set_default: bool | None = None,
    force_download: bool | None = None,
    error: str | None = None,
) -> None:
    config = dict(model.config or {})
    previous = dict(config.get("guided_install") or {})
    config["guided_install"] = {
        **previous,
        "status": status,
        "phase": phase,
        "activate": bool(previous.get("activate")) if activate is None else bool(activate),
        "set_default": bool(previous.get("set_default")) if set_default is None else bool(set_default),
        "force_download": bool(previous.get("force_download")) if force_download is None else bool(force_download),
        "error": error,
        "updated_at": utcnow().isoformat(),
    }
    model.config = config


def guided_install_worker(model_id: int) -> None:
    db = SessionLocal()
    try:
        model = db.get(ModelRecord, model_id)
        if model is None:
            return
        request = dict((model.config or {}).get("guided_install") or {})
        activate = bool(request.get("activate"))
        make_default = bool(request.get("set_default")) and activate
        force_download = bool(request.get("force_download"))
        phase = "download"
        set_guided_install_state(model, status="running", phase=phase)
        db.commit()
        if force_download or model.download_status != "downloaded" or not model.local_path:
            download_model(db, model, settings)
        if activate:
            phase = "activation"
            set_guided_install_state(model, status="running", phase=phase)
            db.commit()
            ModelRuntime(db, settings).activate(model)
            if make_default:
                db.query(ModelRecord).update({ModelRecord.is_default: False})
                model.is_default = True
                db.commit()
        set_guided_install_state(
            model,
            status="completed",
            phase="ready" if activate else "downloaded",
        )
        db.add(
            AuditLog(
                actor_type="system",
                action="model.guided_install_completed",
                target_type="model",
                target_id=str(model.id),
                after={"activated": activate, "default": make_default},
            )
        )
        db.commit()
    except Exception as exc:
        db.rollback()
        model = db.get(ModelRecord, model_id)
        if model is not None:
            error = sanitize_runtime_error(str(exc))[:1000]
            set_guided_install_state(model, status="failed", phase=locals().get("phase", "download"), error=error)
            db.add(
                AuditLog(
                    actor_type="system",
                    action="model.guided_install_failed",
                    target_type="model",
                    target_id=str(model.id),
                    result="failure",
                    details={"phase": locals().get("phase", "download"), "error": error[:500]},
                )
            )
            db.commit()
    finally:
        db.close()


@app.get("/models/{model_id}/compatibility", dependencies=[Depends(require_controller_token)])
def compatibility(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    if model.instance is None:
        raise HTTPException(409, "model instance is not configured")
    try:
        return compatibility_analysis(db, model, model.instance, settings)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.get("/models/{model_id}/activation-plan", dependencies=[Depends(require_controller_token)])
def model_activation_plan(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    if model.instance is None:
        raise HTTPException(409, "model instance is not configured")
    try:
        return activation_plan(db, model, model.instance, settings)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.get("/models/{model_id}/metrics", dependencies=[Depends(require_controller_token)], response_class=PlainTextResponse)
def metrics(model_id: int, db: Session = Depends(get_db)) -> str:
    model = get_model_or_404(db, model_id)
    try:
        return ModelRuntime(db, settings).metrics(model)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.get("/models/{model_id}/logs", dependencies=[Depends(require_controller_token)], response_class=PlainTextResponse)
def logs(model_id: int, tail: int = 300, db: Session = Depends(get_db)) -> str:
    model = get_model_or_404(db, model_id)
    try:
        return ModelRuntime(db, settings).logs(model, tail)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/download", dependencies=[Depends(require_controller_token)])
def download(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    try:
        path = download_model(db, model, settings)
        return {"status": "downloaded", "path": str(path), "size_bytes": model.size_bytes}
    except Exception as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/install", dependencies=[Depends(require_controller_token)], status_code=202)
def install(
    model_id: int,
    background_tasks: BackgroundTasks,
    activate: bool = False,
    set_default: bool = False,
    force_download: bool = False,
    db: Session = Depends(get_db),
) -> dict:
    model = get_model_or_404(db, model_id)
    current = dict((model.config or {}).get("guided_install") or {})
    if current.get("status") in {"queued", "running"}:
        return {"status": current["status"], "model_id": model.id}
    set_guided_install_state(
        model,
        status="queued",
        phase="activation" if model.download_status == "downloaded" and activate else "download",
        activate=activate,
        set_default=set_default and activate,
        force_download=force_download,
    )
    if model.download_status != "downloaded":
        model.download_status = "queued"
        model.download_error = None
    db.commit()
    background_tasks.add_task(guided_install_worker, model.id)
    return {"status": "queued", "model_id": model.id, "activate": activate}


@app.post("/models/{model_id}/activate", dependencies=[Depends(require_controller_token)])
def activate(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    try:
        return ModelRuntime(db, settings).activate(model)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/switch", dependencies=[Depends(require_controller_token)])
def switch(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    try:
        return ModelRuntime(db, settings).switch(model)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/deactivate", dependencies=[Depends(require_controller_token)])
def deactivate(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    try:
        return ModelRuntime(db, settings).deactivate(model)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/restart", dependencies=[Depends(require_controller_token)])
def restart(model_id: int, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    runtime = ModelRuntime(db, settings)
    try:
        runtime.deactivate(model)
        return runtime.activate(model)
    except RuntimeOperationError as exc:
        raise HTTPException(409, str(exc)) from None


@app.post("/models/{model_id}/delete", dependencies=[Depends(require_controller_token)])
def delete(model_id: int, delete_weights: bool = False, db: Session = Depends(get_db)) -> dict:
    model = get_model_or_404(db, model_id)
    if model.instance and (model.instance.desired_active or model.instance.status in {"starting", "ready", "stopping"}):
        raise HTTPException(409, "deactivate the model before deleting it")
    original: Path | None = None
    quarantine: Path | None = None
    if delete_weights and model.local_path:
        original = Path(model.local_path).resolve()
        allowed = managed_model_root(settings).resolve()
        if original == allowed or allowed not in original.parents:
            raise HTTPException(409, "refusing to delete a path outside the managed model store")
        if original.exists():
            quarantine = original.with_name(f".deleting-{model.id}-{secrets.token_hex(6)}")
            original.rename(quarantine)
    try:
        db.delete(model)
        db.commit()
    except Exception:
        db.rollback()
        if quarantine and original and quarantine.exists():
            quarantine.rename(original)
        raise
    cleanup_pending = False
    if quarantine:
        try:
            shutil.rmtree(quarantine)
        except OSError:
            cleanup_pending = True
    return {"status": "deleted", "weights_deleted": bool(delete_weights and not cleanup_pending), "cleanup_pending": cleanup_pending}

