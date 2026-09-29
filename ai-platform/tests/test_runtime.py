from __future__ import annotations

import json
from pathlib import Path

import pytest
from docker.errors import NotFound

from app.config import Settings
from app.models import ModelInstance, ModelRecord
from app.runtime import ModelRuntime, NativeModelRuntime, RuntimeOperationError, activation_plan, build_vllm_args, compatibility_analysis, container_name_for, managed_model_root, supported_vllm_flags


GIB = 1024**3


def hardware(path: Path, vram=24, compute_capability="8.9"):
    target = path / "hardware"
    target.mkdir(parents=True)
    (target / "current.json").write_text(
        json.dumps(
            {
                "cpu": {"model": "CPU", "cores": 16},
                "memory": {"total_bytes": 64 * GIB},
                "storage": {"total_bytes": 500 * GIB},
                "gpus": [
                    {
                        "index": 0,
                        "uuid": "GPU-a",
                        "vendor": "NVIDIA",
                        "name": "GPU",
                        "compute_capability": compute_capability,
                        "memory_total_bytes": vram * GIB,
                        "memory_free_bytes": vram * GIB,
                    }
                ],
                "gpu_driver": {"version": "575"},
            }
        ),
        encoding="utf-8",
    )


def model_pair():
    model = ModelRecord(
        hf_model_id="org/model",
        alias="alpha",
        local_path="/models/alpha",
        download_status="downloaded",
        estimated_weight_gb=4,
        capabilities=["chat"],
        revision="main",
        dtype="auto",
        max_model_len=4096,
    )
    model.instance = ModelInstance(
        container_name="vllm-model-alpha",
        internal_url="http://vllm-model-alpha:8000",
        tensor_parallel_size=1,
        pipeline_parallel_size=1,
        max_num_seqs=4,
        gpu_memory_utilization=0.9,
        cpu_offload_gb=0,
        swap_space_gb=4,
        enable_prefix_caching=True,
        extra_args=[],
    )
    return model, model.instance


def test_vllm_arguments_are_managed_and_stable():
    model, instance = model_pair()
    args = build_vllm_args(model, instance)
    assert args[:2] == ["--model", "/models/alpha"]
    assert args[args.index("--served-model-name") + 1] == "alpha"
    assert "--api-key" not in args
    instance.extra_args = ["--host", "0.0.0.0"]
    with pytest.raises(RuntimeOperationError):
        build_vllm_args(model, instance)
    instance.extra_args = ["--gpu-memory-utilization", "0.99"]
    with pytest.raises(RuntimeOperationError):
        build_vllm_args(model, instance)
    instance.extra_args = ["--reasoning-parser", "qwen3"]
    args = build_vllm_args(model, instance, Settings(ai_runtime_mode="native", native_vllm_version="0.30.0"))
    assert args[args.index("--reasoning-parser") + 1] == "qwen3"
    assert "--swap-space" not in args


def test_vllm_compatibility_matrix_removes_retired_flags_by_version():
    current = Settings(ai_runtime_mode="native", native_vllm_version="0.30.0")
    historical = Settings(ai_runtime_mode="native", native_vllm_version="0.8.5")

    assert "--swap-space" not in supported_vllm_flags(current)
    assert "--swap-space" in supported_vllm_flags(historical)
    model, instance = model_pair()
    assert "--swap-space" in build_vllm_args(model, instance, historical)


def test_container_name_validation():
    assert container_name_for("My-Model") == "vllm-ai-my-model"
    with pytest.raises(RuntimeOperationError):
        container_name_for("My Model")
    with pytest.raises(RuntimeOperationError):
        container_name_for("---")


def test_compatibility_auto_assigns_best_gpu(db, tmp_path):
    hardware(tmp_path)
    model, instance = model_pair()
    db.add(model)
    db.commit()
    settings = Settings(ai_platform_root=tmp_path)
    result = compatibility_analysis(db, model, instance, settings)
    assert result["safe"] is True
    assert instance.gpu_assignment == [0]


class FakeContainer:
    status = "running"

    def reload(self):
        return None

    def stop(self, timeout=0):
        self.status = "exited"

    def remove(self):
        return None

    def logs(self, tail=0):
        return b""


class FakeContainers:
    def __init__(self):
        self.started = None

    def get(self, _name):
        raise NotFound("missing")

    def run(self, image, **kwargs):
        self.started = {"image": image, **kwargs}
        return FakeContainer()


class ExistingContainers(FakeContainers):
    def __init__(self, container):
        super().__init__()
        self.container = container

    def get(self, _name):
        return self.container


class FakeNetwork:
    def connect(self, _container):
        return None


class FakeNetworks:
    def get(self, _name):
        return FakeNetwork()


class FakeDocker:
    def __init__(self):
        self.containers = FakeContainers()
        self.networks = FakeNetworks()


def test_activation_uses_private_network_gpu_and_hardening(db, tmp_path, monkeypatch):
    hardware(tmp_path)
    (tmp_path / "models").mkdir()
    (tmp_path / "hf-cache").mkdir()
    model, _ = model_pair()
    db.add(model)
    db.commit()
    fake = FakeDocker()
    monkeypatch.setattr("app.runtime.httpx.get", lambda *_args, **_kwargs: type("R", (), {"status_code": 200})())
    settings = Settings(ai_platform_root=tmp_path, vllm_image="vllm/vllm-openai:v0.30.0")
    result = ModelRuntime(db, settings, client=fake).activate(model, wait_seconds=1)
    started = fake.containers.started
    assert result["status"] == "ready"
    assert started["network"] == "vllm-ai-internal"
    assert "ports" not in started
    assert started["ipc_mode"] == "host"
    assert started["security_opt"] == ["no-new-privileges:true"]
    assert started["cap_drop"] == ["ALL"]
    assert started["restart_policy"]["MaximumRetryCount"] == 3
    assert started["device_requests"][0].device_ids == ["0"]
    assert "CUDA_VISIBLE_DEVICES" not in started["environment"]


def test_insufficient_vram_blocks_activation(db, tmp_path):
    hardware(tmp_path, vram=2)
    model, instance = model_pair()
    model.estimated_weight_gb = 10
    db.add(model)
    db.commit()
    result = compatibility_analysis(db, model, instance, Settings(ai_platform_root=tmp_path))
    assert result["safe"] is False
    assert result["label"] == "INCOMPATIBLE"


def test_deactivation_stops_runtime_but_preserves_model(db):
    model, instance = model_pair()
    instance.desired_active = True
    instance.status = "ready"
    db.add(model)
    db.commit()
    container = FakeContainer()
    fake = FakeDocker()
    fake.containers = ExistingContainers(container)
    result = ModelRuntime(db, Settings(), client=fake).deactivate(model)
    assert result["status"] == "inactive"
    assert model.instance.desired_active is False
    assert db.get(ModelRecord, model.id) is not None
    assert container.status == "exited"


def test_low_vram_plan_and_switch_preserve_both_downloaded_models(db, tmp_path, monkeypatch):
    hardware(tmp_path, vram=12)
    (tmp_path / "models").mkdir()
    (tmp_path / "hf-cache").mkdir()
    general, general_instance = model_pair()
    general.alias = "omnivis-general"
    general_instance.container_name = "vllm-ai-omnivis-general"
    general_instance.internal_url = "http://vllm-ai-omnivis-general:8000"
    general_instance.gpu_assignment = [0]
    general_instance.desired_active = True
    general_instance.status = "ready"
    general_instance.estimated_vram_gb = 6.0
    coder, coder_instance = model_pair()
    coder.alias = "omnivis-coder"
    coder_instance.container_name = "vllm-ai-omnivis-coder"
    coder_instance.internal_url = "http://vllm-ai-omnivis-coder:8000"
    coder_instance.gpu_assignment = [0]
    db.add_all([general, coder])
    db.commit()
    settings = Settings(ai_platform_root=tmp_path)

    plan = activation_plan(db, coder, coder_instance, settings)
    assert plan["requires_switch"] is True
    assert plan["can_activate"] is True
    assert [item["alias"] for item in plan["active_conflicts"]] == ["omnivis-general"]

    fake = FakeDocker()
    monkeypatch.setattr("app.runtime.httpx.get", lambda *_args, **_kwargs: type("R", (), {"status_code": 200})())
    result = ModelRuntime(db, settings, client=fake).switch(coder, wait_seconds=1)
    assert result["status"] == "ready"
    assert result["switched_from"] == ["omnivis-general"]
    assert general.instance.desired_active is False
    assert coder.instance.desired_active is True
    assert general.download_status == "downloaded"
    assert coder.download_status == "downloaded"
    assert db.get(ModelRecord, general.id) is not None
    assert db.get(ModelRecord, coder.id) is not None


def test_native_runtime_uses_isolated_loopback_process(db, tmp_path, monkeypatch):
    hardware(tmp_path, compute_capability="12.0")
    (tmp_path / "models").mkdir()
    (tmp_path / "hf-cache").mkdir()
    executable = tmp_path / "native" / "vllm-venv" / "bin" / "vllm"
    executable.parent.mkdir(parents=True)
    executable.write_text("#!/bin/sh\n", encoding="utf-8")
    executable.chmod(0o700)
    model, instance = model_pair()
    model.local_path = str(tmp_path / "models" / "alpha")
    Path(model.local_path).mkdir()
    instance.internal_url = ""
    db.add(model)
    db.commit()
    started = {}

    class Process:
        pid = 4242

    def popen(command, **kwargs):
        started["command"] = command
        started["kwargs"] = kwargs
        return Process()

    class Response:
        status_code = 200

        def raise_for_status(self):
            return None

        def json(self):
            return {"paths": {"/v1/models": {}, "/v1/chat/completions": {}}}

    settings = Settings(
        ai_runtime_mode="native",
        ai_platform_root=tmp_path,
        native_vllm_executable=executable,
        native_vllm_port_start=19000,
        native_vllm_port_end=19010,
    )
    runtime = NativeModelRuntime(db, settings, popen=popen, sleeper=lambda _seconds: None)
    monkeypatch.setattr(runtime, "_service_account", lambda: None)
    monkeypatch.setattr(runtime, "_write_state", lambda *_args: {"pid": 4242, "port": 19000, "start_ticks": "1", "model_id": model.id})
    monkeypatch.setattr(runtime, "_state_is_running", lambda _state: True)
    monkeypatch.setattr("app.runtime.httpx.get", lambda *_args, **_kwargs: Response())

    result = runtime.activate(model, wait_seconds=1)

    assert result["runtime"] == "native"
    assert model.instance.internal_url == "http://127.0.0.1:19000"
    assert started["command"][:3] == [str(executable), "serve", model.local_path]
    assert started["command"][started["command"].index("--host") + 1] == "127.0.0.1"
    assert "--api-key" not in started["command"]
    assert started["kwargs"]["start_new_session"] is True
    assert started["kwargs"]["env"]["CUDA_VISIBLE_DEVICES"] == "0"
    assert started["kwargs"]["env"]["VLLM_USE_FLASHINFER_SAMPLER"] == "0"
    assert started["kwargs"]["env"]["XDG_CACHE_HOME"] == str(tmp_path / "native" / "cache")


def test_runtime_factory_and_storage_select_native_mode(db, tmp_path):
    settings = Settings(ai_runtime_mode="native", ai_platform_root=tmp_path)
    assert isinstance(ModelRuntime(db, settings), NativeModelRuntime)
    assert managed_model_root(settings) == tmp_path / "models"

