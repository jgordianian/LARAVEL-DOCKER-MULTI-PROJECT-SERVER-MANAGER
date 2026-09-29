from __future__ import annotations

from datetime import datetime, timedelta, timezone

import fakeredis
import pytest

from app.config import get_settings
from app.models import APIKey, ServiceAccount, User
from app.policy import PolicyDenied, RedisPolicyLimiter, approximate_tokens, require_model_access
from app.security import (
    AuthenticationError,
    authenticate_api_key,
    generate_api_key,
    hash_password,
    ip_allowed,
    parse_networks,
    resolve_client_ip,
    verify_password,
)


def make_key(db, *, scopes=None, models=None, **limits):
    user = User(name="User", email="user@example.com", password_hash=hash_password("GoodPassword!123"))
    db.add(user)
    db.flush()
    raw, key_id, prefix, secret_hash = generate_api_key(get_settings())
    key = APIKey(
        name="test",
        key_id=key_id,
        key_prefix=prefix,
        secret_hash=secret_hash,
        user_id=user.id,
        scopes=scopes or ["models", "chat"],
        allowed_models=models or [],
        **limits,
    )
    db.add(key)
    db.commit()
    return raw, key


def test_password_policy_and_verification():
    with pytest.raises(ValueError):
        hash_password("short")
    encoded = hash_password("GoodPassword!123")
    assert verify_password(encoded, "GoodPassword!123")
    assert not verify_password(encoded, "wrong")


def test_api_key_hash_only_authentication_and_lifecycle(db):
    raw, key = make_key(db)
    assert raw not in key.secret_hash
    principal = authenticate_api_key(db, raw)
    assert principal.api_key_id == key.id
    with pytest.raises(AuthenticationError) as wrong:
        authenticate_api_key(db, raw[:-1] + ("A" if raw[-1] != "A" else "B"))
    assert wrong.value.error_type == "invalid_api_key"
    key.revoked_at = datetime.now(timezone.utc)
    db.commit()
    with pytest.raises(AuthenticationError) as revoked:
        authenticate_api_key(db, raw)
    assert revoked.value.error_type == "revoked_api_key"
    key.revoked_at = None
    key.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    db.commit()
    with pytest.raises(AuthenticationError) as expired:
        authenticate_api_key(db, raw)
    assert expired.value.error_type == "expired_api_key"


def test_service_account_model_and_scope_policy(db):
    account = ServiceAccount(name="batch", allowed_models=["alpha"], allowed_scopes=["chat"])
    db.add(account)
    db.flush()
    key = APIKey(
        name="service",
        key_id="abcdefghij1234",
        key_prefix="ovai_live_abcdefghij1234",
        secret_hash="not-used",
        service_account_id=account.id,
        scopes=["models", "chat"],
    )
    db.add(key)
    db.commit()
    require_model_access(key, "alpha", "chat")
    with pytest.raises(PolicyDenied):
        require_model_access(key, "beta", "chat")
    with pytest.raises(PolicyDenied):
        require_model_access(key, "alpha", "models")


def test_ipv4_ipv6_and_trusted_proxy_resolution():
    assert str(parse_networks(["192.0.2.4/24", "2001:db8::1/64"])[0]) == "192.0.2.0/24"
    assert ip_allowed("2001:db8::5", ["2001:db8::/64"])
    assert not ip_allowed("192.0.2.5", ["2001:db8::/64"])
    assert resolve_client_ip("127.0.0.1", "198.51.100.7, 127.0.0.1", None, ["127.0.0.1/32"]) == "198.51.100.7"
    assert resolve_client_ip("203.0.113.8", "198.51.100.7", None, ["127.0.0.1/32"]) == "203.0.113.8"
    with pytest.raises(ValueError):
        parse_networks(["not-an-address"])


def test_redis_quotas_and_concurrency(db):
    _, key = make_key(
        db,
        requests_per_minute=1,
        tokens_per_minute=100,
        requests_per_day=10,
        requests_per_month=10,
        tokens_per_day=100,
        tokens_per_month=100,
        concurrent_requests=1,
    )
    limiter = RedisPolicyLimiter(fakeredis.FakeRedis(decode_responses=True))
    first = limiter.acquire(key, 5)
    with pytest.raises(PolicyDenied) as concurrent:
        limiter.acquire(key, 5)
    assert concurrent.value.status_code == 429
    first.release()
    with pytest.raises(PolicyDenied) as request_limit:
        limiter.acquire(key, 5)
    assert request_limit.value.error_type == "quota_exceeded"
    assert approximate_tokens({"messages": [{"role": "user", "content": "hello"}]}) > 0

