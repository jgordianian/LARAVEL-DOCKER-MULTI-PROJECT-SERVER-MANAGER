from __future__ import annotations

import base64
import hashlib
import hmac
import io
import secrets
import struct
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, urlencode

import qrcode
import qrcode.image.svg
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .models import SystemSetting, User, WebSession


MFA_MODE_LOGIN = "login"
MFA_MODE_INTERVAL = "interval"
MFA_MODE_DAILY = "daily"
MFA_MODES = {MFA_MODE_LOGIN, MFA_MODE_INTERVAL, MFA_MODE_DAILY}


@dataclass(frozen=True)
class MFAPolicy:
    required: bool = False
    challenge_mode: str = MFA_MODE_LOGIN
    interval_hours: int = 8
    daily_time: str = "08:00"
    grace_days: int = 15


@dataclass(frozen=True)
class MFAGrace:
    expires_at: datetime
    expired: bool
    days_remaining: int


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def aware_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def bounded_int(value: object, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    return max(minimum, min(maximum, parsed))


def mfa_policy(db: Session) -> MFAPolicy:
    keys = {
        "mfa_required",
        "mfa_challenge_mode",
        "mfa_interval_hours",
        "mfa_daily_time",
        "mfa_grace_days",
    }
    values = {row.key: row.value for row in db.scalars(select(SystemSetting).where(SystemSetting.key.in_(keys))).all()}
    mode = str(values.get("mfa_challenge_mode", MFA_MODE_LOGIN))
    if mode not in MFA_MODES:
        mode = MFA_MODE_LOGIN
    daily_time = str(values.get("mfa_daily_time", "08:00"))
    try:
        hour, minute = (int(part) for part in daily_time.split(":"))
        if not (0 <= hour <= 23 and 0 <= minute <= 59):
            raise ValueError
    except (TypeError, ValueError):
        daily_time = "08:00"
    return MFAPolicy(
        required=bool(values.get("mfa_required", False)),
        challenge_mode=mode,
        interval_hours=bounded_int(values.get("mfa_interval_hours"), 8, 1, 720),
        daily_time=daily_time,
        grace_days=bounded_int(values.get("mfa_grace_days"), 15, 0, 365),
    )


def ensure_grace(user: User, policy: MFAPolicy, now: datetime | None = None) -> MFAGrace:
    now = aware_utc(now) or utc_now()
    started = aware_utc(user.totp_grace_started_at)
    expires = aware_utc(user.totp_grace_expires_at)
    if started is None or expires is None:
        started = now
        expires = started + timedelta(days=policy.grace_days)
        user.totp_grace_started_at = started
        user.totp_grace_expires_at = expires
    remaining_seconds = max(0, int((expires - now).total_seconds()))
    return MFAGrace(
        expires_at=expires,
        expired=now >= expires,
        days_remaining=(remaining_seconds + 86399) // 86400,
    )


def should_challenge(session: WebSession, policy: MFAPolicy, now: datetime | None = None) -> bool:
    if not session.user.totp_enabled:
        return False
    verified = aware_utc(session.mfa_verified_at)
    if verified is None:
        return True
    now = aware_utc(now) or utc_now()
    if policy.challenge_mode == MFA_MODE_LOGIN:
        return False
    if policy.challenge_mode == MFA_MODE_INTERVAL:
        return verified <= now - timedelta(hours=policy.interval_hours)
    hour, minute = (int(part) for part in policy.daily_time.split(":"))
    threshold = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if now < threshold:
        threshold -= timedelta(days=1)
    return verified < threshold


def generate_secret(byte_count: int = 20) -> str:
    return base64.b32encode(secrets.token_bytes(byte_count)).decode("ascii").rstrip("=")


def provisioning_uri(secret: str, account: str, issuer: str) -> str:
    issuer = issuer.strip() or "Omnivis AI"
    label = f"{quote(issuer, safe='')}:{quote(account, safe='')}"
    query = urlencode(
        {"secret": secret, "issuer": issuer, "algorithm": "SHA1", "digits": 6, "period": 30},
        quote_via=quote,
    )
    return f"otpauth://totp/{label}?{query}"


def qr_data_uri(content: str) -> str:
    image = qrcode.make(
        content,
        image_factory=qrcode.image.svg.SvgPathImage,
        box_size=8,
        border=2,
    )
    output = io.BytesIO()
    image.save(output)
    return "data:image/svg+xml;base64," + base64.b64encode(output.getvalue()).decode("ascii")


def _fernet(settings: Settings | None = None) -> Fernet:
    settings = settings or get_settings()
    key = base64.urlsafe_b64encode(hashlib.sha256(settings.app_secret.encode("utf-8")).digest())
    return Fernet(key)


def encrypt_secret(secret: str, settings: Settings | None = None) -> str:
    return _fernet(settings).encrypt(secret.encode("ascii")).decode("ascii")


def decrypt_secret(encrypted: str, settings: Settings | None = None) -> str:
    try:
        return _fernet(settings).decrypt(encrypted.encode("ascii")).decode("ascii")
    except (InvalidToken, UnicodeError, ValueError) as exc:
        raise ValueError("the MFA secret could not be decrypted") from exc


def code_at_counter(secret: str, counter: int) -> str:
    padding = "=" * ((8 - len(secret) % 8) % 8)
    key = base64.b32decode(secret.upper() + padding, casefold=True)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    binary = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return f"{binary % 1_000_000:06d}"


def matching_counter(secret: str, code: str, window: int = 1, timestamp: int | None = None) -> int | None:
    normalized = "".join(character for character in str(code) if character not in " -")
    if len(normalized) != 6 or not normalized.isdigit():
        return None
    counter = int((time.time() if timestamp is None else timestamp) // 30)
    for offset in range(-window, window + 1):
        candidate = counter + offset
        if candidate >= 0 and hmac.compare_digest(code_at_counter(secret, candidate), normalized):
            return candidate
    return None
