from __future__ import annotations

import json
import secrets
import shutil
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from sqlalchemy.orm import Session

from . import __version__
from .config import get_settings
from .db import get_db
from .models import ModelRecord
from .runtime import ModelRuntime, RuntimeOperationError, activation_plan, compatibility_analysis, download_model, managed_model_root
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

