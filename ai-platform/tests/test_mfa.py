from __future__ import annotations

import base64
from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from app import mfa, web
from app.models import AuditLog, SystemSetting, User, WebSession
from app.security import create_web_session, hash_password


def authenticated_client(db, user: User):
    db.add(user)
    db.flush()
    raw, session = create_web_session(db, user, "127.0.0.1", "mfa-test")
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    return client, session


def set_setting(db, key: str, value):
    db.add(SystemSetting(key=key, value=value, secret=False))
    db.commit()


def test_totp_matches_rfc_vector_and_encrypts_secrets():
    secret = base64.b32encode(b"12345678901234567890").decode("ascii").rstrip("=")
    assert mfa.code_at_counter(secret, 1) == "287082"
    assert mfa.matching_counter(secret, "287 082", timestamp=59) == 1
    encrypted = mfa.encrypt_secret(secret)
    assert secret not in encrypted
    assert mfa.decrypt_secret(encrypted) == secret
    assert mfa.qr_data_uri(mfa.provisioning_uri(secret, "user@example.com", "Omnivis AI")).startswith(
        "data:image/svg+xml;base64,"
    )


def test_admin_can_configure_global_mfa_policy(db):
    admin = User(
        name="MFA Admin",
        email="mfa-admin@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    client, session = authenticated_client(db, admin)
    page = client.get("/admin/settings")
    assert page.status_code == 200
    assert "Multi-factor authentication (MFA)" in page.text
    assert 'action="/admin/settings/mfa"' in page.text
    assert "/static/mfa-settings.js?v=1.2.0-mfa1" in page.text

    response = client.post(
        "/admin/settings/mfa",
        data={
            "csrf_token": session.csrf_token,
            "mfa_required": "true",
            "mfa_challenge_mode": "interval",
            "mfa_interval_hours": "12",
            "mfa_daily_time": "09:30",
            "mfa_grace_days": "5",
        },
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["location"] == "/admin/settings?result=mfa-saved"
    policy = mfa.mfa_policy(db)
    assert policy.required is True
    assert policy.challenge_mode == "interval"
    assert policy.interval_hours == 12
    assert policy.grace_days == 5
    event = db.scalar(select(AuditLog).where(AuditLog.action == "settings.mfa_changed"))
    assert event is not None


def test_user_can_enroll_and_new_session_requires_non_replayed_totp(db, monkeypatch):
    user = User(name="MFA User", email="mfa-user@example.com", password_hash=hash_password("GoodPassword!123"))
    client, session = authenticated_client(db, user)
    profile = client.get("/profile")
    assert "Configure MFA" in profile.text

    setup = client.get("/mfa/setup")
    assert setup.status_code == 200
    assert "Set up your authenticator" in setup.text
    assert "data:image/svg+xml;base64," in setup.text
    db.expire_all()
    saved_user = db.get(User, user.id)
    secret = mfa.decrypt_secret(saved_user.totp_secret_encrypted)
    initial_time = 1_800_000_000
    monkeypatch.setattr(mfa.time, "time", lambda: initial_time)
    code = mfa.code_at_counter(secret, initial_time // 30)
    confirmed = client.post(
        "/mfa/setup/confirm",
        data={"csrf_token": session.csrf_token, "code": code},
        follow_redirects=False,
    )
    assert confirmed.status_code == 303
    db.expire_all()
    saved_user = db.get(User, user.id)
    assert saved_user.totp_enabled is True
    assert saved_user.totp_confirmed_at is not None
    assert db.get(WebSession, session.id).mfa_verified_at is not None

    raw, second_session = create_web_session(db, saved_user, "127.0.0.1", "second-session")
    db.commit()
    second = TestClient(web.app)
    second.cookies.set("ai_session", raw)
    blocked = second.get("/", follow_redirects=False)
    assert blocked.status_code == 303
    assert blocked.headers["location"] == "/mfa/challenge"
    assert second.get("/mfa/challenge").status_code == 200

    replayed = second.post(
        "/mfa/verify",
        data={"csrf_token": second_session.csrf_token, "code": code},
        follow_redirects=False,
    )
    assert replayed.status_code == 400
    assert "already been used" in replayed.text

    next_time = initial_time + 30
    monkeypatch.setattr(mfa.time, "time", lambda: next_time)
    next_code = mfa.code_at_counter(secret, next_time // 30)
    verified = second.post(
        "/mfa/verify",
        data={"csrf_token": second_session.csrf_token, "code": next_code},
        follow_redirects=False,
    )
    assert verified.status_code == 303
    assert verified.headers["location"] == "/"
    assert second.get("/").status_code == 200


def test_required_mfa_supports_per_session_grace_skip(db):
    set_setting(db, "mfa_required", True)
    set_setting(db, "mfa_grace_days", 5)
    user = User(name="Grace User", email="grace@example.com", password_hash=hash_password("GoodPassword!123"))
    client, session = authenticated_client(db, user)
    blocked = client.get("/", follow_redirects=False)
    assert blocked.status_code == 303
    assert blocked.headers["location"] == "/mfa/setup"
    setup = client.get("/mfa/setup")
    assert "You may postpone setup for 5 more day(s)." in setup.text

    skipped = client.post(
        "/mfa/skip",
        data={"csrf_token": session.csrf_token},
        follow_redirects=False,
    )
    assert skipped.status_code == 303
    assert client.get("/").status_code == 200
    db.expire_all()
    assert db.get(WebSession, session.id).mfa_grace_skipped is True
    assert db.get(User, user.id).totp_grace_expires_at is not None


def test_admin_reset_mfa_terminates_target_sessions(db):
    admin = User(
        name="MFA Admin",
        email="reset-admin@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    target = User(
        name="MFA Target",
        email="reset-target@example.com",
        password_hash=hash_password("GoodPassword!123"),
        totp_enabled=True,
        totp_secret_encrypted=mfa.encrypt_secret(mfa.generate_secret()),
        totp_confirmed_at=datetime.now(timezone.utc),
    )
    db.add_all([admin, target])
    db.flush()
    raw, admin_session = create_web_session(db, admin, "127.0.0.1", "admin")
    _, target_session = create_web_session(db, target, "127.0.0.1", "target")
    target_session_id = target_session.id
    db.commit()
    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)

    users_page = client.get("/admin/users")
    assert "Reset MFA and end sessions" in users_page.text
    response = client.post(
        f"/admin/users/{target.id}/reset-mfa",
        data={"csrf_token": admin_session.csrf_token},
        follow_redirects=False,
    )
    assert response.status_code == 303
    db.expire_all()
    reset_target = db.get(User, target.id)
    assert reset_target.totp_enabled is False
    assert reset_target.totp_secret_encrypted is None
    assert db.get(WebSession, target_session_id) is None
    assert db.scalar(select(AuditLog).where(AuditLog.action == "user.mfa_reset")) is not None
