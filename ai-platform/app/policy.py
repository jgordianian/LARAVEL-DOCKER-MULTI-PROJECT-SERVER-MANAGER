from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone

from redis import Redis

from .models import APIKey


class PolicyDenied(Exception):
    def __init__(self, error_type: str, message: str, status_code: int = 403):
        super().__init__(message)
        self.error_type = error_type
        self.message = message
        self.status_code = status_code


def _tokenizable_input(value):
    if isinstance(value, list):
        rows = [_tokenizable_input(item) for item in value]
        return [row[0] for row in rows], sum(row[1] for row in rows)
    if not isinstance(value, dict):
        return value, 0
    if value.get("type") in {"image_url", "input_image"}:
        return {"type": value.get("type"), "image": "<uploaded-image>"}, 1
    result = {}
    images = 0
    for key, item in value.items():
        result[key], count = _tokenizable_input(item)
        images += count
    return result, images


def approximate_tokens(payload: dict) -> int:
    # Conservative preflight approximation. Authoritative counts are saved from
    # the upstream usage object after generation.
    tokenizable, image_count = _tokenizable_input(
        payload.get("messages", payload.get("input", payload.get("prompt", "")))
    )
    text = json.dumps(
        tokenizable,
        ensure_ascii=False,
    )
    # Image tokenization varies by model and resolution. Reserve a conservative
    # preflight allowance without counting the base64 transport bytes as text.
    return max(1, (len(text.encode("utf-8")) + 2) // 3 + image_count * 1_024)


def require_scope_access(key: APIKey, scope: str) -> None:
    if scope not in key.scopes:
        raise PolicyDenied("scope_denied", "This API key cannot use this endpoint.")
    owner = key.service_account
    if owner is not None and owner.allowed_scopes and scope not in owner.allowed_scopes:
        raise PolicyDenied("scope_denied", "The service account cannot use this capability.")


def require_endpoint_access(key: APIKey, endpoint: str) -> None:
    if key.allowed_endpoints and endpoint not in key.allowed_endpoints:
        raise PolicyDenied("endpoint_access_denied", "This API key cannot use this endpoint.")
    owner = key.service_account
    if owner is not None and owner.allowed_endpoints and endpoint not in owner.allowed_endpoints:
        raise PolicyDenied("endpoint_access_denied", "The service account cannot use this endpoint.")


def require_model_access(key: APIKey, model_alias: str, scope: str, endpoint: str | None = None) -> None:
    require_scope_access(key, scope)
    if endpoint:
        require_endpoint_access(key, endpoint)
    if key.allowed_models and model_alias not in key.allowed_models:
        raise PolicyDenied("model_access_denied", "This API key cannot access the requested model.")
    owner = key.service_account
    if owner is not None and owner.allowed_models and model_alias not in owner.allowed_models:
        raise PolicyDenied("model_access_denied", "The service account cannot access the requested model.")


@dataclass
class LimitLease:
    redis: Redis
    concurrency_key: str
    held: bool = True

    def release(self) -> None:
        if self.held:
            value = self.redis.decr(self.concurrency_key)
            if value <= 0:
                self.redis.delete(self.concurrency_key)
            self.held = False


class RedisPolicyLimiter:
    def __init__(self, redis: Redis):
        self.redis = redis

    @staticmethod
    def _periods(now: datetime) -> dict[str, tuple[str, int]]:
        return {
            "minute": (now.strftime("%Y%m%d%H%M"), 120),
            "day": (now.strftime("%Y%m%d"), 172800),
            "month": (now.strftime("%Y%m"), 2678400),
        }

    def _increment_checked(self, name: str, amount: int, limit: int, ttl: int) -> int:
        if limit <= 0:
            return 0
        value = int(self.redis.incrby(name, amount))
        if value == amount:
            self.redis.expire(name, ttl)
        if value > limit:
            self.redis.decrby(name, amount)
            raise PolicyDenied("quota_exceeded", "The configured usage limit has been reached.", 429)
        return value

    def acquire(self, key: APIKey, estimated_input_tokens: int) -> LimitLease:
        now = datetime.now(timezone.utc)
        periods = self._periods(now)
        prefix = f"aip:key:{key.id}"
        minute, minute_ttl = periods["minute"]
        day, day_ttl = periods["day"]
        month, month_ttl = periods["month"]

        increments = [
            (f"{prefix}:rpm:{minute}", 1, key.requests_per_minute, minute_ttl),
            (f"{prefix}:tpm:{minute}", estimated_input_tokens, key.tokens_per_minute, minute_ttl),
            (f"{prefix}:rpd:{day}", 1, key.requests_per_day, day_ttl),
            (f"{prefix}:rpmth:{month}", 1, key.requests_per_month, month_ttl),
            (f"{prefix}:tpd:{day}", estimated_input_tokens, key.tokens_per_day, day_ttl),
            (f"{prefix}:tpmth:{month}", estimated_input_tokens, key.tokens_per_month, month_ttl),
        ]
        applied: list[tuple[str, int]] = []
        concurrent_key = f"{prefix}:concurrent"
        try:
            for name, amount, limit, ttl in increments:
                self._increment_checked(name, amount, limit, ttl)
                if limit > 0:
                    applied.append((name, amount))
            current = int(self.redis.incr(concurrent_key))
            self.redis.expire(concurrent_key, 3600)
            if key.concurrent_requests > 0 and current > key.concurrent_requests:
                self.redis.decr(concurrent_key)
                raise PolicyDenied("concurrency_limit", "Too many concurrent requests.", 429)
        except PolicyDenied:
            for name, amount in applied:
                value = self.redis.decrby(name, amount)
                if value <= 0:
                    self.redis.delete(name)
            raise
        return LimitLease(self.redis, concurrent_key)

    def record_output(self, key: APIKey, output_tokens: int) -> None:
        if output_tokens <= 0:
            return
        now = datetime.now(timezone.utc)
        periods = self._periods(now)
        prefix = f"aip:key:{key.id}"
        minute, minute_ttl = periods["minute"]
        day, day_ttl = periods["day"]
        month, month_ttl = periods["month"]
        # Output is recorded after the request. Preflight input enforcement keeps
        # abuse bounded; a subsequent request is rejected if totals exceeded.
        for name, ttl in (
            (f"{prefix}:tpm:{minute}", minute_ttl),
            (f"{prefix}:tpd:{day}", day_ttl),
            (f"{prefix}:tpmth:{month}", month_ttl),
        ):
            self.redis.incrby(name, output_tokens)
            self.redis.expire(name, ttl)

