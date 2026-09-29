from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app import web
from app.environment import classify_environment, probe_environment, sanitize_image_reference
from app.models import ModelInstance, ModelRecord, User
from app.notebooks import NOTEBOOK_KINDS, generate_notebook, notebook_document
from app.security import create_web_session, hash_password


def fake_runner(calls: list[list[str]]):
    def run(command: list[str], _timeout: int = 10):
        calls.append(command)
        if command[0] == "systemd-detect-virt":
            return 0, "docker"
        if command[0] == "ss":
            return 127, ""
        if command[0] == "nvidia-smi":
            return 127, ""
        if command[0] == "docker":
            return 127, ""
        return 127, ""

    return run


def fake_proc(root: Path, *, jupyter: bool) -> Path:
    proc = root / "proc"
    (proc / "1").mkdir(parents=True)
    (proc / "1" / "comm").write_text("tini\n", encoding="utf-8")
    (proc / "1" / "cgroup").write_text("0::/docker/test\n", encoding="utf-8")
    (proc / "self").mkdir()
    (proc / "self" / "status").write_text("CapEff:\t0000000000000000\n", encoding="utf-8")
    (proc / "net").mkdir()
    (proc / "net" / "tcp").write_text(
        "  sl  local_address rem_address st\n"
        "   0: 00000000:22B8 00000000:0000 0A\n",
        encoding="utf-8",
    )
    (proc / "net" / "tcp6").write_text("  sl  local_address rem_address st\n", encoding="utf-8")
    if jupyter:
        process = proc / "123"
        process.mkdir()
        (process / "comm").write_text("python\n", encoding="utf-8")
        (process / "cmdline").write_bytes(
            b"python\0-m\0jupyterlab\0--port=8888\0--ServerApp.token=never-log-this-token\0"
        )
    return proc


def test_vast_provider_jupyter_is_detected_without_modification(tmp_path):
    filesystem = tmp_path / "root"
    filesystem.mkdir()
    (filesystem / ".dockerenv").touch()
    proc = fake_proc(tmp_path, jupyter=True)
    platform_root = tmp_path / "platform"
    provider_config = tmp_path / "provider-jupyter-config.py"
    provider_config.write_text("c.ServerApp.token = 'provider-secret'\n", encoding="utf-8")
    original_config = provider_config.read_bytes()
    calls: list[list[str]] = []

    snapshot = probe_environment(
        platform_root=platform_root,
        filesystem_root=filesystem,
        proc_root=proc,
        env={"VASTAI_IMAGE": "vastai/base-image-cuda-12.8.1-auto/jupyter"},
        runner=fake_runner(calls),
        which=lambda name: f"/opt/provider/bin/{name}" if name in {"jupyter", "jupyter-lab"} else None,
    )

    encoded = json.dumps(snapshot)
    assert snapshot["environment_type"] == "VAST_AI_CONTAINER"
    assert snapshot["provider"] == "Vast.ai"
    assert snapshot["jupyter"]["running"] is True
    assert snapshot["jupyter"]["management"] == "PROVIDER_MANAGED"
    assert snapshot["jupyter"]["action"] == "PRESERVE_AND_REUSE"
    assert snapshot["jupyter"]["internal_listeners"] == [
        {"address": "0.0.0.0", "port": 8888, "scope": "ALL_INTERFACES"}
    ]
    assert "never-log-this-token" not in encoded
    assert "provider-secret" not in encoded
    assert provider_config.read_bytes() == original_config
    assert (proc / "123").is_dir()
    assert all(command[0] not in {"apt", "apt-get", "pip", "systemctl", "kill"} for command in calls)


def test_missing_jupyter_and_unprivileged_container_are_graceful(tmp_path):
    filesystem = tmp_path / "root"
    filesystem.mkdir()
    (filesystem / ".dockerenv").touch()
    proc = fake_proc(tmp_path, jupyter=False)
    calls: list[list[str]] = []

    snapshot = probe_environment(
        platform_root=tmp_path / "platform",
        filesystem_root=filesystem,
        proc_root=proc,
        env={},
        runner=fake_runner(calls),
        which=lambda _name: None,
    )

    assert snapshot["environment_type"] == "DOCKER_CONTAINER"
    assert snapshot["jupyter"]["detected"] is False
    assert snapshot["jupyter"]["management"] == "NONE"
    assert snapshot["capabilities"]["systemd_available"] is False
    assert snapshot["capabilities"]["docker_daemon_available"] is False
    assert snapshot["capabilities"]["host_firewall_management"] is False
    assert snapshot["capabilities"]["luks_block_devices"] is False
    assert snapshot["feature_compatibility"]["jupyter_integration"] is True
    assert snapshot["feature_compatibility"]["native_ai_platform"] is False


def test_environment_classification_and_image_secret_sanitization():
    assert classify_environment(
        container_detected=False,
        virtualization="kvm",
        image=None,
        provider_hint=None,
        hostname="vm",
        vast_marker=False,
        jupyter_detected=False,
    ) == ("FULL_VM", "Local / self-managed")
    assert classify_environment(
        container_detected=False,
        virtualization="none",
        image=None,
        provider_hint=None,
        hostname="metal",
        vast_marker=False,
        jupyter_detected=False,
    ) == ("BARE_METAL", "Local / self-managed")
    assert sanitize_image_reference("https://user:password@registry.example/vastai/image:tag?token=secret") == "registry.example/vastai/image:tag"
    assert sanitize_image_reference("image token=secret") is None


def test_generated_notebooks_are_valid_gateway_only_and_secret_free(tmp_path):
    generated = []
    for kind in sorted(NOTEBOOK_KINDS):
        document = notebook_document(kind)
        assert document["nbformat"] == 4
        assert document["metadata"]["omnivis"]["contains_credentials"] is False
        target = generate_notebook(kind, tmp_path)
        generated.append(target)
        parsed = json.loads(target.read_text(encoding="utf-8"))
        source = json.dumps(parsed)
        assert "getpass.getpass" in source
        assert "OMNIVIS_CODING_API_KEY" in source
        assert "https://ai.example.com/v1" in source
        assert "ovai_live_" not in source
        assert "hf_" not in source
        assert "execute-shell" not in source
        assert parsed["metadata"]["omnivis"]["gateway_only"] is True
        for index, cell in enumerate(parsed["cells"]):
            if cell["cell_type"] == "code":
                compile("".join(cell["source"]), f"{kind}-cell-{index}", "exec")
    assert {path.parent.name for path in generated} == {"diagnostics", "benchmarks", "examples"}


def test_notebook_generation_never_overwrites_existing_file(tmp_path, monkeypatch):
    first = generate_notebook("vllm-api", tmp_path)
    original = first.read_bytes()
    second = generate_notebook("vllm-api", tmp_path)
    assert first != second
    assert first.read_bytes() == original


def test_admin_jupyter_page_is_read_only_and_renders_snapshot(db, tmp_path, monkeypatch):
    admin = User(
        name="Admin",
        email="jupyter-admin@example.com",
        password_hash=hash_password("GoodPassword!123"),
        role="super_admin",
    )
    model = ModelRecord(hf_model_id="org/model", alias="omnivis-general", download_status="downloaded")
    model.instance = ModelInstance(
        container_name="vllm-ai-general",
        internal_url="http://vllm-ai-general:8000",
        desired_active=True,
        status="ready",
    )
    db.add_all([admin, model])
    db.flush()
    raw, _ = create_web_session(db, admin, "127.0.0.1", "test")
    db.commit()

    snapshot_path = tmp_path / "environment.json"
    snapshot_path.write_text(
        json.dumps(
            {
                "environment_type": "VAST_AI_CONTAINER",
                "provider": "Vast.ai",
                "runtime": {"kind": "container", "image": "vastai/base-image-cuda-12.8.1-auto/jupyter"},
                "jupyter": {
                    "detected": True,
                    "lab_available": True,
                    "running": True,
                    "management": "PROVIDER_MANAGED",
                    "action": "PRESERVE_AND_REUSE",
                    "process_count": 1,
                    "runtime_files_detected": 1,
                    "internal_listeners": [],
                    "provider_access": "Use Vast.ai provider UI / Open button.",
                },
                "python": {"version": "3.11", "executable": "/opt/provider/bin/python"},
                "cuda": {"visible": True, "version": "12.8", "device_count": 1},
                "pytorch": {"available": True, "gpu_status": "YES"},
                "capabilities": {"docker_daemon_available": False, "systemd_available": False},
            }
        ),
        encoding="utf-8",
    )
    notebook_root = tmp_path / "notebooks"
    generate_notebook("vllm-api", notebook_root)
    monkeypatch.setattr(web, "ENVIRONMENT_SNAPSHOT_PATH", snapshot_path)
    monkeypatch.setattr(web, "NOTEBOOKS_ROOT", notebook_root)

    client = TestClient(web.app)
    client.cookies.set("ai_session", raw)
    response = client.get("/admin/jupyter")

    assert response.status_code == 200
    assert "VAST AI CONTAINER" in response.text
    assert "PROVIDER MANAGED" in response.text
    assert "Preserve and reuse" in response.text
    assert "omnivis-general" in response.text
    assert "vllm-api-" in response.text
