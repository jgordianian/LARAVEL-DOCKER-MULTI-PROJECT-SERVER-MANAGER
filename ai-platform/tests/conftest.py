from __future__ import annotations

import atexit
import os
import shutil
import tempfile
from pathlib import Path

import fakeredis
import pytest


TEST_ROOT = Path(tempfile.mkdtemp(prefix="vllm-ai-platform-tests-"))
atexit.register(shutil.rmtree, TEST_ROOT, True)

os.environ.update(
    {
        "DATABASE_URL": f"sqlite:///{(TEST_ROOT / 'test.db').as_posix()}",
        "REDIS_URL": "redis://localhost:6379/15",
        "APP_SECRET": "test-app-secret-0123456789abcdef",
        "API_KEY_PEPPER": "test-key-pepper-0123456789abcdef",
        "INTERNAL_GATEWAY_TOKEN": "test-internal-token-0123456789",
        "CONTROLLER_TOKEN": "test-controller-token-0123456789",
        "PROXY_SHARED_TOKEN": "test-proxy-token-0123456789",
        "COOKIE_SECURE": "false",
        "TRUSTED_PROXY_CIDRS": "127.0.0.1/32,::1/128",
        "GLOBAL_ALLOWED_CIDRS": "",
        "AI_PLATFORM_ROOT": str(TEST_ROOT),
    }
)

from app import gateway, web  # noqa: E402
from app.db import Base, SessionLocal, engine  # noqa: E402


@pytest.fixture(autouse=True)
def clean_database(monkeypatch):
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    fake = fakeredis.FakeRedis(decode_responses=True)
    monkeypatch.setattr(gateway, "redis_client", fake)
    monkeypatch.setattr(web, "redis_client", fake)
    yield
    Base.metadata.drop_all(engine)


@pytest.fixture
def db():
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()

