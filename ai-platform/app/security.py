from __future__ import annotations

import hashlib
import hmac
import ipaddress
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from email_validator import EmailNotValidError, validate_email
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .models import APIKey, ServiceAccount, User, WebSession


password_hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=2)
api_hasher = PasswordHasher(time_cost=2, memory_cost=32768, parallelism=2)
API_KEY_RE = re.compile(r"^ovai_live_([A-Za-z0-9_-]{10,24})\.([A-Za-z0-9_-]{32,128})$")


class AuthenticationError(Exception):
    def __init__(self, error_type: str, message: str, status_code: int = 401):
        super().__init__(message)
        self.error_type = error_type
        self.message = message
        self.status_code = status_code


@dataclass
class Principal:
    kind: str
    user_id: int | None = None
    service_account_id: int | None = None
    api_key_id: int | None = None
    api_key: APIKey | None = None


def hash_password(password: str) -> str:
    validate_password(password)
    return password_hasher.hash(password)


def verify_password(stored_hash: str, password: str) -> bool:
    try:
        return password_hasher.verify(stored_hash, password)
    except (VerifyMismatchError, InvalidHashError):
        return False


def validate_password(password: str) -> None:
    if len(password) < 12 or len(password) > 256:
        raise ValueError("password must contain 12 to 256 characters")
    categories = sum(
        bool(re.search(pattern, password))
        for pattern in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^A-Za-z0-9]")
    )
    if categories < 3:
        raise ValueError("password must use at least three character categories")


def normalize_email(value: str) -> str:
    try:
        return validate_email(value.strip(), check_deliverability=False).normalized.lower()
    except EmailNotValidError as exc:
        raise ValueError("a valid email address is required") from exc


def _peppered(secret: str, settings: Settings) -> str:
    return hmac.new(settings.api_key_pepper.encode(), secret.encode(), hashlib.sha256).hexdigest()


def generate_api_key(settings: Settings | None = None) -> tuple[str, str, str, str]:
    settings = settings or get_settings()
    key_id = secrets.token_urlsafe(10).replace("-", "A").replace("_", "B")[:14]
    secret = secrets.token_urlsafe(42)
    complete = f"ovai_live_{key_id}.{secret}"
    prefix = f"ovai_live_{key_id}"
    return complete, key_id, prefix, api_hasher.hash(_peppered(secret, settings))


def authenticate_api_key(db: Session, raw_key: str, settings: Settings | None = None) -> Principal:
    settings = settings or get_settings()
    match = API_KEY_RE.fullmatch(raw_key.strip())
    if not match:
        raise AuthenticationError("invalid_api_key", "The API key is invalid.")
    key_id, secret = match.groups()
    record = db.scalar(select(APIKey).where(APIKey.key_id == key_id))
    if record is None:
        raise AuthenticationError("invalid_api_key", "The API key is invalid.")
    if not record.enabled or record.revoked_at is not None:
        raise AuthenticationError("revoked_api_key", "The API key is disabled or revoked.")
    now = datetime.now(timezone.utc)
    if record.expires_at is not None:
        expires = record.expires_at
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        if expires <= now:
            raise AuthenticationError("expired_api_key", "The API key has expired.")
    try:
        api_hasher.verify(record.secret_hash, _peppered(secret, settings))
    except (VerifyMismatchError, InvalidHashError):
        raise AuthenticationError("invalid_api_key", "The API key is invalid.") from None
    if record.user is not None and not record.user.enabled:
        raise AuthenticationError("account_disabled", "The API key owner is disabled.", 403)
    if record.service_account is not None and not record.service_account.enabled:
        raise AuthenticationError("account_disabled", "The service account is disabled.", 403)
    record.last_used_at = now
    return Principal(
        kind="api_key",
        user_id=record.user_id,
        service_account_id=record.service_account_id,
        api_key_id=record.id,
        api_key=record,
    )


def parse_networks(values: Iterable[str]) -> list[ipaddress.IPv4Network | ipaddress.IPv6Network]:
    networks = []
    for value in values:
        value = value.strip()
        if not value:
            continue
        try:
            networks.append(ipaddress.ip_network(value, strict=False))
        except ValueError as exc:
            raise ValueError(f"invalid IP/CIDR: {value}") from exc
    return networks


def ip_allowed(address: str, cidrs: Iterable[str], unrestricted_when_empty: bool = True) -> bool:
    networks = parse_networks(cidrs)
    if not networks:
        return unrestricted_when_empty
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    return any(ip.version == network.version and ip in network for network in networks)


def resolve_client_ip(peer_ip: str, x_forwarded_for: str | None, x_real_ip: str | None, trusted_proxy_cidrs: Iterable[str]) -> str:
    try:
        peer = ipaddress.ip_address(peer_ip)
    except ValueError:
        return peer_ip
    trusted = parse_networks(trusted_proxy_cidrs)
    peer_trusted = any(peer.version == network.version and peer in network for network in trusted)
    if not peer_trusted:
        return str(peer)

    chain: list[str] = []
    if x_forwarded_for:
        chain.extend(part.strip() for part in x_forwarded_for.split(",") if part.strip())
    elif x_real_ip:
        chain.append(x_real_ip.strip())
    chain.append(str(peer))

    # Walk right-to-left, discarding only explicitly trusted proxies. The first
    # untrusted address is the client. Invalid forwarded values are ignored.
    for candidate in reversed(chain):
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if any(ip.version == network.version and ip in network for network in trusted):
            continue
        return str(ip)
    return str(peer)


def session_token_hash(token: str, settings: Settings | None = None) -> str:
    settings = settings or get_settings()
    return hmac.new(settings.app_secret.encode(), token.encode(), hashlib.sha256).hexdigest()


def create_web_session(db: Session, user: User, ip: str, user_agent: str, settings: Settings | None = None) -> tuple[str, WebSession]:
    settings = settings or get_settings()
    raw = secrets.token_urlsafe(48)
    session = WebSession(
        user_id=user.id,
        token_hash=session_token_hash(raw, settings),
        csrf_token=secrets.token_urlsafe(32),
        ip_address=ip,
        user_agent=user_agent[:512],
        expires_at=datetime.now(timezone.utc) + timedelta(seconds=settings.session_ttl_seconds),
    )
    db.add(session)
    db.flush()
    return raw, session


def get_web_session(db: Session, raw: str | None, settings: Settings | None = None) -> WebSession | None:
    if not raw:
        return None
    record = db.scalar(select(WebSession).where(WebSession.token_hash == session_token_hash(raw, settings)))
    if record is None:
        return None
    expires = record.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= datetime.now(timezone.utc) or not record.user.enabled:
        db.delete(record)
        db.flush()
        return None
    return record


def constant_time_token(actual: str, expected: str) -> bool:
    return bool(actual and expected and hmac.compare_digest(actual, expected))

