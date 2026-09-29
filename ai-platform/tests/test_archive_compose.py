from __future__ import annotations

import io
import json
import tarfile

import pytest
import yaml

from scripts.safe_archive import inspect


def manifest():
    return {"format": "vllm-ai-platform-backup", "schema_version": 1}


def test_safe_archive_accepts_manifest(tmp_path):
    archive = tmp_path / "backup.tar.gz"
    body = json.dumps(manifest()).encode()
    with tarfile.open(archive, "w:gz") as bundle:
        info = tarfile.TarInfo("manifest.json")
        info.size = len(body)
        bundle.addfile(info, io.BytesIO(body))
    assert inspect(archive)["schema_version"] == 1


def test_safe_archive_rejects_path_traversal(tmp_path):
    archive = tmp_path / "unsafe.tar.gz"
    body = json.dumps(manifest()).encode()
    with tarfile.open(archive, "w:gz") as bundle:
        info = tarfile.TarInfo("manifest.json")
        info.size = len(body)
        bundle.addfile(info, io.BytesIO(body))
        evil = tarfile.TarInfo("../outside")
        evil.size = 1
        bundle.addfile(evil, io.BytesIO(b"x"))
    with pytest.raises(ValueError, match="unsafe archive path"):
        inspect(archive)


def test_safe_archive_rejects_links(tmp_path):
    archive = tmp_path / "link.tar.gz"
    body = json.dumps(manifest()).encode()
    with tarfile.open(archive, "w:gz") as bundle:
        info = tarfile.TarInfo("manifest.json")
        info.size = len(body)
        bundle.addfile(info, io.BytesIO(body))
        link = tarfile.TarInfo("config/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "target"
        bundle.addfile(link)
    with pytest.raises(ValueError, match="links are not supported"):
        inspect(archive)


def test_compose_exposes_only_proxy_attached_apps():
    compose_path = __import__("pathlib").Path(__file__).resolve().parents[1] / "compose.yaml"
    compose = yaml.safe_load(compose_path.read_text(encoding="utf-8"))
    assert compose["networks"]["internal"]["internal"] is True
    for name in ("postgres", "redis", "gateway", "web", "controller"):
        assert "ports" not in compose["services"][name]
    assert "laravel-shared" not in compose["services"]["postgres"]["networks"]
    assert "laravel-shared" not in compose["services"]["redis"]["networks"]
    assert "laravel-shared" in compose["services"]["gateway"]["networks"]
    assert "laravel-shared" in compose["services"]["web"]["networks"]
    assert "healthcheck" in compose["services"]["gateway"]
    assert "/var/run/docker.sock:/var/run/docker.sock" in compose["services"]["controller"]["volumes"]
    assert "jupyter" not in compose["services"]
    assert "./notebooks:/platform/notebooks:ro" in compose["services"]["web"]["volumes"]
    assert all("jupyter" not in (service.get("depends_on") or {}) for service in compose["services"].values())
    for name in ("gateway", "web", "controller"):
        assert "--no-proxy-headers" in compose["services"][name]["command"]
        assert "--proxy-headers=false" not in compose["services"][name]["command"]

