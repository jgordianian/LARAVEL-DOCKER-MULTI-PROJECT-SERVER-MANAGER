from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
from sqlalchemy import func, select

from .capabilities import (
    model_capabilities,
    normalize_capabilities,
    normalize_endpoints,
    validate_service_account_purpose,
)
from .config import get_settings
from .db import SessionLocal
from .environment import load_environment_snapshot
from .hardware import load_snapshot
from .models import APIKey, AuditLog, IPRule, ModelInstance, ModelRecord, ServiceAccount, UsageRecord, User
from .runtime import (
    ModelRuntime,
    RuntimeOperationError,
    activation_plan,
    build_vllm_args,
    compatibility_analysis,
    container_name_for,
    download_model,
    managed_model_root,
    recommend_profile,
)
from .security import generate_api_key, hash_password, normalize_email, parse_networks


settings = get_settings()


def csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def gpu_csv(value: str) -> list[int]:
    if value.lower() in {"", "auto"}:
        return []
    try:
        result = sorted({int(part.strip()) for part in value.split(",")})
    except ValueError:
        raise argparse.ArgumentTypeError("GPU assignment must be auto or comma-separated indexes") from None
    if any(value < 0 for value in result):
        raise argparse.ArgumentTypeError("GPU indexes cannot be negative")
    return result


def model_dict(model: ModelRecord) -> dict:
    return {
        "id": model.id, "model_id": model.hf_model_id, "revision": model.revision, "alias": model.alias,
        "download_status": model.download_status, "size_bytes": model.size_bytes, "capabilities": sorted(model_capabilities(model)),
        "default": model.is_default,
        "active": bool(model.instance and model.instance.desired_active),
        "runtime_status": model.instance.status if model.instance else "not-configured",
        "gpus": model.instance.gpu_assignment if model.instance else [],
        "tensor_parallel_size": model.instance.tensor_parallel_size if model.instance else None,
        "performance_profile": model.instance.performance_profile if model.instance else None,
        "last_error": model.instance.last_error if model.instance else None,
    }


def print_json(value) -> None:
    print(json.dumps(value, indent=2, default=str, sort_keys=True))


def get_model(db, identifier: str) -> ModelRecord:
    model = db.get(ModelRecord, int(identifier)) if identifier.isdigit() else db.scalar(select(ModelRecord).where(ModelRecord.alias == identifier))
    if model is None:
        raise RuntimeOperationError("model not found")
    return model


def cmd_init_admin(args) -> None:
    password = sys.stdin.readline().rstrip("\r\n") if args.password_stdin else ""
    if not password:
        raise RuntimeOperationError("administrator password is required on stdin")
    email = normalize_email(args.email)
    with SessionLocal() as db:
        existing = db.scalar(select(User).where(func.lower(User.email) == email))
        if existing:
            print_json({"status": "exists", "id": existing.id, "email": existing.email})
            return
        user = User(name=args.name.strip()[:160], email=email, password_hash=hash_password(password), role="super_admin", enabled=True)
        db.add(user)
        db.flush()
        db.add(AuditLog(actor_type="system", action="first_administrator.created", target_type="user", target_id=str(user.id)))
        db.commit()
        print_json({"status": "created", "id": user.id, "email": user.email})


def cmd_status(_args) -> None:
    with SessionLocal() as db:
        environment_path = Path("/platform/hardware/environment.json")
        if settings.ai_runtime_mode == "native" or not environment_path.exists():
            environment_path = settings.ai_platform_root / "hardware" / "environment.json"
        environment = load_environment_snapshot(environment_path)
        result = {
            "schema_version": settings.ai_platform_schema_version,
            "users": db.scalar(select(func.count()).select_from(User)),
            "models": db.scalar(select(func.count()).select_from(ModelRecord)),
            "downloaded_models": db.scalar(select(func.count()).select_from(ModelRecord).where(ModelRecord.download_status == "downloaded")),
            "active_models": db.scalar(select(func.count()).select_from(ModelInstance).where(ModelInstance.desired_active.is_(True))),
            "ready_models": db.scalar(select(func.count()).select_from(ModelInstance).where(ModelInstance.status == "ready")),
            "coding_models": sum(
                1
                for model in db.scalars(select(ModelRecord)).all()
                if model_capabilities(model).intersection({"coding", "agentic"})
            ),
            "active_api_keys": db.scalar(select(func.count()).select_from(APIKey).where(APIKey.enabled.is_(True), APIKey.revoked_at.is_(None))),
            "vllm_image": settings.vllm_image,
            "environment_type": environment.get("environment_type", "UNKNOWN"),
            "jupyter": {
                "detected": environment.get("jupyter", {}).get("detected", False),
                "running": environment.get("jupyter", {}).get("running", False),
                "management": environment.get("jupyter", {}).get("management", "UNKNOWN"),
            },
        }
        print_json(result)


def cmd_models(args) -> None:
    with SessionLocal() as db:
        if args.model_command == "list":
            print_json([model_dict(model) for model in db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all()])
            return
        if args.model_command == "add":
            if db.scalar(select(ModelRecord).where(ModelRecord.alias == args.alias)):
                raise RuntimeOperationError("model alias already exists")
            reasoning_parser = args.reasoning_parser.strip()
            if reasoning_parser and not re.fullmatch(r"[a-z0-9_.-]{1,64}", reasoning_parser):
                raise RuntimeOperationError("reasoning parser name is invalid")
            if not 0.1 <= args.gpu_memory_utilization <= 0.95:
                raise RuntimeOperationError("GPU memory utilization must be between 0.1 and 0.95")
            name = container_name_for(args.alias)
            local_path = args.local_path
            status = "registered"
            size = None
            if local_path:
                path = Path(local_path).resolve()
                allowed_root = managed_model_root(settings).resolve()
                if path != allowed_root and allowed_root not in path.parents:
                    raise RuntimeOperationError(f"custom model path must be inside {allowed_root}")
                if not path.is_dir():
                    raise RuntimeOperationError("custom model path does not exist")
                status = "downloaded"
                size = sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
                local_path = str(path)
            model = ModelRecord(
                hf_model_id=args.model_id, revision=args.revision, alias=args.alias,
                local_path=local_path, source_type="custom" if local_path else "huggingface", download_status=status,
                size_bytes=size, estimated_weight_gb=args.estimated_weight_gb or (round(size / 1024**3, 2) if size else None),
                capabilities=normalize_capabilities(csv(args.capabilities), tool_calling=args.tool_calling),
                quantization=args.quantization or None, dtype=args.dtype,
                max_model_len=args.max_model_len, trust_remote_code=args.trust_remote_code,
                tool_calling=args.tool_calling, tool_call_parser=args.tool_call_parser or None,
                chat_template=args.chat_template or None, auto_start=args.auto_start,
            )
            model.instance = ModelInstance(
                container_name=name,
                internal_url=f"http://{name}:8000" if settings.ai_runtime_mode == "docker" else "",
                gpu_assignment=args.gpus,
                tensor_parallel_size=args.tensor_parallel_size, pipeline_parallel_size=args.pipeline_parallel_size,
                performance_profile=args.performance_profile.upper(), max_num_seqs=args.max_num_seqs,
                gpu_memory_utilization=args.gpu_memory_utilization,
                extra_args=["--reasoning-parser", reasoning_parser] if reasoning_parser else [],
            )
            db.add(model)
            db.flush()
            db.add(AuditLog(actor_type="root_cli", action="model.registered", target_type="model", target_id=str(model.id), after=model_dict(model)))
            db.commit()
            print_json(model_dict(model))
            return
        if args.model_command == "reconcile":
            runtime = ModelRuntime(db, settings)
            candidates = db.scalars(
                select(ModelRecord)
                .join(ModelInstance)
                .where((ModelInstance.desired_active.is_(True)) | (ModelRecord.auto_start.is_(True)))
                .order_by(ModelRecord.alias)
            ).all()
            results = []
            for candidate in candidates:
                current = runtime.status(candidate)
                if current.get("healthy"):
                    candidate.instance.status = "ready"
                    results.append({"model": candidate.alias, "status": "ready", "action": "unchanged"})
                    continue
                try:
                    result = runtime.activate(candidate, wait_seconds=args.wait_seconds)
                    results.append({"model": candidate.alias, "status": result["status"], "action": "started"})
                except RuntimeOperationError as exc:
                    results.append({"model": candidate.alias, "status": "error", "error": str(exc)})
            db.commit()
            print_json(results)
            if args.strict and any(item["status"] == "error" for item in results):
                raise RuntimeOperationError("one or more desired model instances failed reconciliation")
            return
        if args.model_command == "validate-config":
            results = []
            failures = []
            for candidate in db.scalars(select(ModelRecord).join(ModelInstance).order_by(ModelRecord.alias)).all():
                try:
                    arguments = build_vllm_args(candidate, candidate.instance, settings)
                    results.append({"model": candidate.alias, "status": "valid", "argument_count": len(arguments)})
                except RuntimeOperationError as exc:
                    failures.append({"model": candidate.alias, "status": "invalid", "error": str(exc)})
            print_json(results + failures)
            if failures:
                raise RuntimeOperationError("stored model configuration is incompatible with the selected vLLM image")
            return
        if args.model_command == "verify-storage":
            results = []
            for candidate in db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all():
                present = bool(candidate.local_path and Path(candidate.local_path).is_dir())
                if candidate.download_status == "downloaded" and not present:
                    candidate.download_status = "missing"
                    if candidate.instance:
                        candidate.instance.desired_active = False
                        candidate.instance.status = "inactive"
                    results.append({"model": candidate.alias, "status": "missing", "action": "redownload" if candidate.source_type == "huggingface" else "restore-custom-path"})
                else:
                    results.append({"model": candidate.alias, "status": candidate.download_status, "present": present})
            db.commit()
            print_json(results)
            return
        model = get_model(db, args.model)
        if args.model_command == "details":
            print_json(model_dict(model) | {"config": model.config, "local_path": model.local_path, "download_error": model.download_error})
        elif args.model_command == "download":
            download_model(db, model, settings)
            print_json(model_dict(model))
        elif args.model_command == "activate":
            print_json(ModelRuntime(db, settings).activate(model, wait_seconds=args.wait_seconds))
        elif args.model_command == "deactivate":
            print_json(ModelRuntime(db, settings).deactivate(model))
        elif args.model_command == "restart":
            runtime = ModelRuntime(db, settings)
            runtime.deactivate(model)
            print_json(runtime.activate(model, wait_seconds=args.wait_seconds))
        elif args.model_command == "compatibility":
            print_json(compatibility_analysis(db, model, model.instance, settings))
        elif args.model_command == "plan":
            print_json(activation_plan(db, model, model.instance, settings))
        elif args.model_command == "switch":
            print_json(ModelRuntime(db, settings).switch(model, wait_seconds=args.wait_seconds))
        elif args.model_command == "metrics":
            print(ModelRuntime(db, settings).metrics(model), end="")
        elif args.model_command == "default":
            db.query(ModelRecord).update({ModelRecord.is_default: False})
            model.is_default = True
            db.add(AuditLog(actor_type="root_cli", action="model.default_changed", target_type="model", target_id=str(model.id), after={"alias": model.alias}))
            db.commit()
            print_json(model_dict(model))
        elif args.model_command == "alias":
            if model.instance and model.instance.desired_active:
                raise RuntimeOperationError("deactivate the model before changing its alias")
            before = model.alias
            name = container_name_for(args.new_alias)
            model.alias = args.new_alias
            model.instance.container_name = name
            model.instance.internal_url = f"http://{name}:8000" if settings.ai_runtime_mode == "docker" else ""
            db.add(AuditLog(actor_type="root_cli", action="model.alias_changed", target_type="model", target_id=str(model.id), before={"alias": before}, after={"alias": model.alias}))
            db.commit()
            print_json(model_dict(model))
        elif args.model_command == "configure":
            if model.instance.desired_active:
                raise RuntimeOperationError("deactivate the model before changing runtime configuration")
            before = model_dict(model)
            for field in ("max_model_len", "dtype", "quantization", "tool_call_parser"):
                value = getattr(args, field)
                if value is not None:
                    setattr(model, field, value or None)
            if args.capabilities is not None or args.tool_calling is not None:
                capabilities = csv(args.capabilities) if args.capabilities is not None else list(model.capabilities)
                if args.tool_calling is False:
                    capabilities = [value for value in capabilities if value not in {"tools", "tool_calling", "tool-calling"}]
                if args.tool_calling is not None:
                    model.tool_calling = args.tool_calling
                model.capabilities = normalize_capabilities(capabilities, tool_calling=model.tool_calling)
            for field in ("tensor_parallel_size", "pipeline_parallel_size", "max_num_seqs", "gpu_memory_utilization", "cpu_offload_gb", "swap_space_gb"):
                value = getattr(args, field)
                if value is not None:
                    setattr(model.instance, field, value)
            if args.gpus is not None:
                model.instance.gpu_assignment = args.gpus
            if args.performance_profile:
                model.instance.performance_profile = args.performance_profile.upper()
            db.add(AuditLog(actor_type="root_cli", action="model.configuration_changed", target_type="model", target_id=str(model.id), before=before, after=model_dict(model)))
            db.commit()
            print_json(model_dict(model))
        elif args.model_command == "clone":
            name = container_name_for(args.new_alias)
            clone = ModelRecord(
                hf_model_id=model.hf_model_id, revision=model.revision, alias=args.new_alias, local_path=model.local_path,
                source_type=model.source_type, download_status=model.download_status, size_bytes=model.size_bytes,
                estimated_weight_gb=model.estimated_weight_gb, capabilities=list(model.capabilities), quantization=model.quantization,
                dtype=model.dtype, max_model_len=model.max_model_len, trust_remote_code=model.trust_remote_code,
                tool_calling=model.tool_calling, tool_call_parser=model.tool_call_parser, chat_template=model.chat_template,
                config=dict(model.config),
            )
            source = model.instance
            clone.instance = ModelInstance(
                container_name=name,
                internal_url=f"http://{name}:8000" if settings.ai_runtime_mode == "docker" else "",
                gpu_assignment=list(source.gpu_assignment),
                tensor_parallel_size=source.tensor_parallel_size, pipeline_parallel_size=source.pipeline_parallel_size,
                performance_profile=source.performance_profile, gpu_memory_utilization=source.gpu_memory_utilization,
                max_num_seqs=source.max_num_seqs, max_num_batched_tokens=source.max_num_batched_tokens,
                cpu_offload_gb=source.cpu_offload_gb, swap_space_gb=source.swap_space_gb,
                enable_prefix_caching=source.enable_prefix_caching, extra_args=list(source.extra_args),
            )
            db.add(clone)
            db.commit()
            print_json(model_dict(clone))
        elif args.model_command == "delete":
            if model.instance and model.instance.desired_active:
                raise RuntimeOperationError("deactivate the model before deleting it")
            path = Path(model.local_path).resolve() if model.local_path else None
            db.add(AuditLog(actor_type="root_cli", action="model.deleted", target_type="model", target_id=str(model.id), before=model_dict(model)))
            db.delete(model)
            db.commit()
            if args.delete_weights and path and path.is_dir():
                allowed = managed_model_root(settings).resolve()
                if allowed in path.parents and path != allowed:
                    shutil.rmtree(path)
            print_json({"status": "deleted", "weights_deleted": bool(args.delete_weights and path)})


def cmd_performance(args) -> None:
    with SessionLocal() as db:
        model = get_model(db, args.model)
        if not model.instance:
            raise RuntimeOperationError("model instance is not configured")
        snapshot_path = Path("/platform/hardware/current.json")
        if settings.ai_runtime_mode == "native" or not snapshot_path.exists():
            snapshot_path = settings.ai_platform_root / "hardware" / "current.json"
        snapshot = load_snapshot(snapshot_path)
        recommendation = recommend_profile(args.profile, snapshot, model, model.instance)
        if args.apply:
            if model.instance.desired_active:
                raise RuntimeOperationError("deactivate the model before applying performance settings")
            model.instance.performance_profile = args.profile.upper()
            model.instance.gpu_memory_utilization = recommendation["gpu_memory_utilization"]
            model.max_model_len = recommendation["max_model_len"]
            model.instance.max_num_seqs = recommendation["max_num_seqs"]
            model.instance.max_num_batched_tokens = recommendation.get("max_num_batched_tokens")
            validation = compatibility_analysis(db, model, model.instance, settings)
            recommendation["compatibility"] = validation
            if not validation.get("safe"):
                db.rollback()
                raise RuntimeOperationError(f"profile is unsafe for current hardware: {validation}")
            db.add(AuditLog(actor_type="root_cli", action="performance.changed", target_type="model", target_id=str(model.id), after=recommendation))
            db.commit()
        print_json(recommendation | {"applied": args.apply})


def cmd_users(args) -> None:
    with SessionLocal() as db:
        if args.user_command == "list":
            print_json([{"id": u.id, "name": u.name, "email": u.email, "role": u.role, "enabled": u.enabled, "last_login_at": u.last_login_at} for u in db.scalars(select(User).order_by(User.email)).all()])
        elif args.user_command == "create":
            password = sys.stdin.readline().rstrip("\r\n")
            user = User(name=args.name.strip()[:160], email=normalize_email(args.email), role=args.role, password_hash=hash_password(password), force_password_reset=True)
            db.add(user); db.flush()
            db.add(AuditLog(actor_type="root_cli", action="user.created", target_type="user", target_id=str(user.id), after={"email": user.email, "role": user.role}))
            db.commit(); print_json({"id": user.id, "email": user.email})
        else:
            user = db.get(User, args.user_id)
            if not user:
                raise RuntimeOperationError("user not found")
            if args.user_command == "enable": user.enabled = True
            elif args.user_command == "disable": user.enabled = False
            elif args.user_command == "reset-password":
                user.password_hash = hash_password(sys.stdin.readline().rstrip("\r\n")); user.force_password_reset = True
            action = "user.password_reset" if args.user_command == "reset-password" else f"user.{args.user_command}d"
            db.add(AuditLog(actor_type="root_cli", action=action, target_type="user", target_id=str(user.id)))
            db.commit(); print_json({"id": user.id, "enabled": user.enabled})


def cmd_service_accounts(args) -> None:
    with SessionLocal() as db:
        if args.service_command == "list":
            print_json([
                {
                    "id": account.id,
                    "name": account.name,
                    "description": account.description,
                    "purpose": account.purpose,
                    "enabled": account.enabled,
                    "allowed_models": account.allowed_models,
                    "allowed_scopes": account.allowed_scopes,
                    "allowed_endpoints": account.allowed_endpoints,
                    "allow_custom_system_messages": account.allow_custom_system_messages,
                }
                for account in db.scalars(select(ServiceAccount).order_by(ServiceAccount.name)).all()
            ])
            return
        if args.service_command == "create":
            if db.scalar(select(ServiceAccount).where(ServiceAccount.name == args.name)):
                raise RuntimeOperationError("service account name already exists")
            account = ServiceAccount(
                name=args.name,
                description=args.description,
                purpose=validate_service_account_purpose(args.purpose),
                allowed_models=csv(args.models),
                allowed_scopes=csv(args.scopes),
                allowed_endpoints=normalize_endpoints(csv(args.endpoints)),
                allow_custom_system_messages=args.allow_custom_system_messages,
            )
            db.add(account)
            db.flush()
            db.add(AuditLog(actor_type="root_cli", action="service_account.created", target_type="service_account", target_id=str(account.id)))
            db.commit()
            print_json({"id": account.id, "name": account.name, "enabled": account.enabled})
            return
        account = db.get(ServiceAccount, args.service_account_id)
        if account is None:
            raise RuntimeOperationError("service account not found")
        if args.service_command == "enable":
            account.enabled = True
        elif args.service_command == "disable":
            account.enabled = False
        elif args.service_command == "delete":
            db.add(AuditLog(actor_type="root_cli", action="service_account.deleted", target_type="service_account", target_id=str(account.id)))
            db.delete(account)
            db.commit()
            print_json({"status": "deleted"})
            return
        db.add(AuditLog(actor_type="root_cli", action=f"service_account.{args.service_command}d", target_type="service_account", target_id=str(account.id)))
        db.commit()
        print_json({"id": account.id, "name": account.name, "enabled": account.enabled})


def cmd_keys(args) -> None:
    with SessionLocal() as db:
        if args.key_command == "list":
            print_json([{"id": key.id, "name": key.name, "prefix": key.key_prefix, "enabled": key.enabled, "revoked_at": key.revoked_at, "expires_at": key.expires_at} for key in db.scalars(select(APIKey).order_by(APIKey.created_at.desc())).all()])
            return
        if args.key_command == "create":
            complete, key_id, prefix, secret_hash = generate_api_key(settings)
            key = APIKey(
                name=args.name, key_id=key_id, key_prefix=prefix, secret_hash=secret_hash,
                user_id=args.user_id, service_account_id=args.service_account_id,
                allowed_models=csv(args.models), allowed_cidrs=csv(args.cidrs), scopes=csv(args.scopes),
                allowed_endpoints=normalize_endpoints(csv(args.endpoints)),
                requests_per_minute=args.rpm, tokens_per_minute=args.tpm, concurrent_requests=args.concurrent,
            )
            parse_networks(key.allowed_cidrs)
            if bool(key.user_id) == bool(key.service_account_id):
                raise RuntimeOperationError("choose exactly one user or service-account owner")
            db.add(key); db.flush(); db.add(AuditLog(actor_type="root_cli", action="api_key.created", target_type="api_key", target_id=str(key.id), after={"prefix": prefix})); db.commit()
            print("COMPLETE KEY - DISPLAYED ONCE:")
            print(complete)
            return
        key = db.get(APIKey, args.key_id)
        if not key: raise RuntimeOperationError("API key not found")
        if args.key_command == "revoke":
            key.enabled = False; key.revoked_at = datetime.now(timezone.utc)
            db.add(AuditLog(actor_type="root_cli", action="api_key.revoked", target_type="api_key", target_id=str(key.id), after={"prefix": key.key_prefix}))
            db.commit(); print_json({"status": "revoked", "prefix": key.key_prefix})
        elif args.key_command == "rotate":
            complete, key_id, prefix, secret_hash = generate_api_key(settings)
            key.key_id, key.key_prefix, key.secret_hash = key_id, prefix, secret_hash
            key.enabled, key.revoked_at = True, None
            db.add(AuditLog(actor_type="root_cli", action="api_key.rotated", target_type="api_key", target_id=str(key.id), after={"prefix": prefix}))
            db.commit(); print("COMPLETE KEY - DISPLAYED ONCE:"); print(complete)


def cmd_ip(args) -> None:
    with SessionLocal() as db:
        if args.ip_command == "list":
            print_json([{"id": rule.id, "scope": rule.subject_type, "subject_id": rule.subject_id, "cidr": rule.cidr, "enabled": rule.enabled} for rule in db.scalars(select(IPRule)).all()])
        elif args.ip_command == "add":
            network = str(parse_networks([args.cidr])[0]); rule = IPRule(subject_type=args.scope, subject_id=args.subject_id, cidr=network, description=args.description); db.add(rule); db.flush()
            db.add(AuditLog(actor_type="root_cli", action="ip_rule.created", target_type="ip_rule", target_id=str(rule.id), after={"scope": rule.subject_type, "subject_id": rule.subject_id, "cidr": rule.cidr}))
            db.commit(); print_json({"id": rule.id, "cidr": rule.cidr})
        elif args.ip_command == "delete":
            rule = db.get(IPRule, args.rule_id)
            if not rule: raise RuntimeOperationError("IP rule not found")
            db.add(AuditLog(actor_type="root_cli", action="ip_rule.deleted", target_type="ip_rule", target_id=str(rule.id), before={"scope": rule.subject_type, "subject_id": rule.subject_id, "cidr": rule.cidr}))
            db.delete(rule); db.commit(); print_json({"status": "deleted"})


def cmd_usage(args) -> None:
    with SessionLocal() as db:
        rows = db.scalars(select(UsageRecord).order_by(UsageRecord.occurred_at.desc()).limit(args.limit)).all()
        print_json([
            {
                "request_id": r.request_id, "time": r.occurred_at, "model": r.model_alias,
                "endpoint": r.endpoint, "service_account_id": r.service_account_id,
                "api_key_id": r.api_key_id, "tokens": r.total_tokens,
                "status": r.http_status, "latency_ms": r.latency_ms,
            }
            for r in rows
        ])


def cmd_coding_diagnostics(_args) -> None:
    with SessionLocal() as db:
        models = [
            model
            for model in db.scalars(select(ModelRecord).order_by(ModelRecord.alias)).all()
            if model_capabilities(model).intersection({"coding", "agentic"})
        ]
        account_rules = db.scalars(
            select(IPRule).where(IPRule.subject_type == "service_account", IPRule.enabled.is_(True))
        ).all()
        accounts = [
            account
            for account in db.scalars(select(ServiceAccount).order_by(ServiceAccount.name)).all()
            if account.purpose == "coding_agent" or "coding" in account.allowed_scopes
        ]
        try:
            gateway_health = httpx.get(f"{settings.gateway_internal_url}/health", timeout=5).status_code == 200
        except httpx.HTTPError:
            gateway_health = False
        print_json(
            {
                "gateway": {
                    "healthy": gateway_health,
                    "routes": ["/v1/models", "/v1/chat/completions", "/v1/responses"],
                },
                "coding_models_installed": len(models),
                "coding_models_active": sum(
                    bool(model.instance and model.instance.desired_active and model.instance.status == "ready")
                    for model in models
                ),
                "models": [
                    {
                        "alias": model.alias,
                        "capabilities": sorted(model_capabilities(model)),
                        "active": bool(model.instance and model.instance.desired_active and model.instance.status == "ready"),
                        "chat_completions_configured": "chat" in model_capabilities(model),
                        "responses_configured": "responses" in model_capabilities(model),
                        "runtime_api_support": (model.config or {}).get("runtime_api_support", {"verified": False}),
                        "tool_calling": {
                            "configured": model.tool_calling,
                            "parser": model.tool_call_parser,
                            "chat_template_configured": bool(model.chat_template),
                        },
                    }
                    for model in models
                ],
                "coding_service_accounts": [
                    {
                        "id": account.id,
                        "name": account.name,
                        "purpose": account.purpose,
                        "enabled": account.enabled,
                        "allowed_models": account.allowed_models,
                        "allowed_scopes": account.allowed_scopes,
                        "allowed_endpoints": account.allowed_endpoints,
                        "allowed_cidrs": [rule.cidr for rule in account_rules if rule.subject_id == account.id],
                    }
                    for account in accounts
                ],
                "secrets_included": False,
            }
        )


def cmd_jupyter_diagnostics(_args) -> None:
    environment_path = Path("/platform/hardware/environment.json")
    if settings.ai_runtime_mode == "native" or not environment_path.exists():
        environment_path = settings.ai_platform_root / "hardware" / "environment.json"
    snapshot = load_environment_snapshot(environment_path)
    try:
        gateway_internal = httpx.get(f"{settings.gateway_internal_url}/health", timeout=5).status_code == 200
    except httpx.HTTPError:
        gateway_internal = False

    with SessionLocal() as db:
        active_models = db.scalars(
            select(ModelRecord)
            .join(ModelInstance)
            .where(ModelInstance.desired_active.is_(True), ModelInstance.status == "ready")
            .order_by(ModelRecord.alias)
        ).all()
        runtimes = []
        for model in active_models:
            reachable = False
            try:
                reachable = httpx.get(f"{model.instance.internal_url}/health", timeout=5).status_code == 200
            except httpx.HTTPError:
                pass
            runtimes.append({"alias": model.alias, "reachable": reachable})

    print_json(
        {
            "environment": snapshot or {"status": "snapshot-unavailable"},
            "gateway_internal_reachable": gateway_internal,
            "gateway_reachable_from_jupyter": "NOT_TESTED",
            "vllm_runtimes": runtimes,
            "vllm_api_tested": bool(runtimes),
            "provider_external_ui_tested": "NOT_POSSIBLE_FROM_CURRENT_ENVIRONMENT",
            "secrets_included": False,
        }
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ai-platform")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init-admin"); init.add_argument("--name", required=True); init.add_argument("--email", required=True); init.add_argument("--password-stdin", action="store_true"); init.set_defaults(func=cmd_init_admin)
    status = sub.add_parser("status"); status.set_defaults(func=cmd_status)

    models = sub.add_parser("models"); ms = models.add_subparsers(dest="model_command", required=True)
    item = ms.add_parser("list"); item.set_defaults(func=cmd_models)
    item = ms.add_parser("add"); item.add_argument("--model-id", required=True); item.add_argument("--revision", default="main"); item.add_argument("--alias", required=True); item.add_argument("--local-path"); item.add_argument("--capabilities", default="chat,completions"); item.add_argument("--estimated-weight-gb", type=float, default=0); item.add_argument("--quantization", default=""); item.add_argument("--dtype", default="auto"); item.add_argument("--max-model-len", type=int, default=4096); item.add_argument("--gpus", type=gpu_csv, default=[]); item.add_argument("--tensor-parallel-size", type=int, default=1); item.add_argument("--pipeline-parallel-size", type=int, default=1); item.add_argument("--max-num-seqs", type=int, default=4); item.add_argument("--gpu-memory-utilization", type=float, default=0.82); item.add_argument("--performance-profile", default="AUTO"); item.add_argument("--trust-remote-code", action="store_true"); item.add_argument("--tool-calling", action="store_true"); item.add_argument("--tool-call-parser", default=""); item.add_argument("--reasoning-parser", default=""); item.add_argument("--chat-template", default=""); item.add_argument("--auto-start", action="store_true"); item.set_defaults(func=cmd_models)
    item = ms.add_parser("reconcile"); item.add_argument("--wait-seconds", type=int, default=600); item.add_argument("--strict", action="store_true"); item.set_defaults(func=cmd_models)
    ms.add_parser("validate-config").set_defaults(func=cmd_models)
    ms.add_parser("verify-storage").set_defaults(func=cmd_models)
    for name in ("details", "download", "compatibility", "plan", "metrics", "default", "deactivate"):
        item = ms.add_parser(name); item.add_argument("model"); item.set_defaults(func=cmd_models)
    for name in ("activate", "restart", "switch"):
        item = ms.add_parser(name); item.add_argument("model"); item.add_argument("--wait-seconds", type=int, default=600); item.set_defaults(func=cmd_models)
    item = ms.add_parser("alias"); item.add_argument("model"); item.add_argument("new_alias"); item.set_defaults(func=cmd_models)
    item = ms.add_parser("clone"); item.add_argument("model"); item.add_argument("new_alias"); item.set_defaults(func=cmd_models)
    item = ms.add_parser("delete"); item.add_argument("model"); item.add_argument("--delete-weights", action="store_true"); item.set_defaults(func=cmd_models)
    item = ms.add_parser("configure"); item.add_argument("model"); item.add_argument("--max-model-len", type=int); item.add_argument("--dtype"); item.add_argument("--quantization"); item.add_argument("--capabilities"); item.add_argument("--tool-calling", action=argparse.BooleanOptionalAction, default=None); item.add_argument("--tool-call-parser"); item.add_argument("--gpus", type=gpu_csv); item.add_argument("--tensor-parallel-size", type=int); item.add_argument("--pipeline-parallel-size", type=int); item.add_argument("--max-num-seqs", type=int); item.add_argument("--gpu-memory-utilization", type=float); item.add_argument("--cpu-offload-gb", type=float); item.add_argument("--swap-space-gb", type=float); item.add_argument("--performance-profile"); item.set_defaults(func=cmd_models)

    perf = sub.add_parser("performance"); perf.add_argument("model"); perf.add_argument("profile", choices=["AUTO", "CONSERVATIVE", "BALANCED", "PERFORMANCE", "MAXIMUM", "CUSTOM"]); perf.add_argument("--apply", action="store_true"); perf.set_defaults(func=cmd_performance)
    users = sub.add_parser("users"); us = users.add_subparsers(dest="user_command", required=True); us.add_parser("list").set_defaults(func=cmd_users)
    item = us.add_parser("create"); item.add_argument("--name", required=True); item.add_argument("--email", required=True); item.add_argument("--role", choices=["super_admin", "administrator", "user"], default="user"); item.set_defaults(func=cmd_users)
    for name in ("enable", "disable", "reset-password"):
        item = us.add_parser(name); item.add_argument("user_id", type=int); item.set_defaults(func=cmd_users)
    services = sub.add_parser("service-accounts"); ss = services.add_subparsers(dest="service_command", required=True); ss.add_parser("list").set_defaults(func=cmd_service_accounts)
    item = ss.add_parser("create"); item.add_argument("--name", required=True); item.add_argument("--description", default=""); item.add_argument("--purpose", choices=["general_api", "omnivis_production", "coding_agent", "custom"], default="general_api"); item.add_argument("--models", default=""); item.add_argument("--scopes", default=""); item.add_argument("--endpoints", default=""); item.add_argument("--allow-custom-system-messages", action="store_true"); item.set_defaults(func=cmd_service_accounts)
    for name in ("enable", "disable", "delete"):
        item = ss.add_parser(name); item.add_argument("service_account_id", type=int); item.set_defaults(func=cmd_service_accounts)
    keys = sub.add_parser("keys"); ks = keys.add_subparsers(dest="key_command", required=True); ks.add_parser("list").set_defaults(func=cmd_keys)
    item = ks.add_parser("create"); item.add_argument("--name", required=True); item.add_argument("--user-id", type=int); item.add_argument("--service-account-id", type=int); item.add_argument("--models", default=""); item.add_argument("--cidrs", default=""); item.add_argument("--scopes", default=""); item.add_argument("--endpoints", default=""); item.add_argument("--rpm", type=int, default=60); item.add_argument("--tpm", type=int, default=60000); item.add_argument("--concurrent", type=int, default=4); item.set_defaults(func=cmd_keys)
    for name in ("revoke", "rotate"):
        item = ks.add_parser(name); item.add_argument("key_id", type=int); item.set_defaults(func=cmd_keys)
    ips = sub.add_parser("ip"); ip_sub = ips.add_subparsers(dest="ip_command", required=True); ip_sub.add_parser("list").set_defaults(func=cmd_ip)
    item = ip_sub.add_parser("add"); item.add_argument("cidr"); item.add_argument("--scope", choices=["global", "service_account", "api_key"], default="global"); item.add_argument("--subject-id", type=int); item.add_argument("--description", default=""); item.set_defaults(func=cmd_ip)
    item = ip_sub.add_parser("delete"); item.add_argument("rule_id", type=int); item.set_defaults(func=cmd_ip)
    usage = sub.add_parser("usage"); usage.add_argument("--limit", type=int, default=100); usage.set_defaults(func=cmd_usage)
    coding = sub.add_parser("coding-diagnostics"); coding.set_defaults(func=cmd_coding_diagnostics)
    jupyter = sub.add_parser("jupyter-diagnostics"); jupyter.set_defaults(func=cmd_jupyter_diagnostics)
    return parser


def main() -> None:
    try:
        args = build_parser().parse_args()
        args.func(args)
    except (RuntimeOperationError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()

