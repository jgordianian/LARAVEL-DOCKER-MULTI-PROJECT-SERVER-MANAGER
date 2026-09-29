from __future__ import annotations

import ast
import json
import re
from pathlib import Path

import pytest

from app.config import Settings
from app.cli import build_parser
from scripts.native_service import read_environment


def test_native_environment_parser_does_not_execute_shell_syntax(tmp_path):
    environment = tmp_path / ".env"
    environment.write_text(
        "AI_RUNTIME_MODE=native\n"
        "APP_SECRET=$(touch /tmp/never-execute-this)\n"
        "EMPTY=\n",
        encoding="utf-8",
    )

    values = read_environment(environment)

    assert values["AI_RUNTIME_MODE"] == "native"
    assert values["APP_SECRET"] == "$(touch /tmp/never-execute-this)"
    assert values["EMPTY"] == ""


def test_native_settings_validate_runtime_mode_and_private_ports(tmp_path):
    settings = Settings(
        ai_runtime_mode="NATIVE",
        ai_platform_root=tmp_path,
        native_gateway_port=18000,
    )
    assert settings.ai_runtime_mode == "native"
    assert settings.native_gateway_port == 18000
    with pytest.raises(ValueError):
        Settings(ai_runtime_mode="process-manager")
    with pytest.raises(ValueError):
        Settings(native_web_port=80)


def test_native_cloudflared_supervision_uses_protected_token_file():
    platform_root = Path(__file__).resolve().parents[1]
    runtime_path = platform_root / "scripts" / "native_runtime.py"
    source = runtime_path.read_text(encoding="utf-8")
    tree = ast.parse(source)
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "cloudflared_supervisor_program"
    )
    body = ast.get_source_segment(source, function) or ""

    assert "[program:cloudflared]" in body
    assert "--token-file {token_file}" in body
    assert "--token {token}" not in body
    assert "os.chown(SECRETS_ROOT, 0, account.pw_gid)" in body
    assert "SECRETS_ROOT.chmod(0o710)" in body
    assert "token_file.chmod(0o640)" in body
    assert "relative_to(SECRETS_ROOT.resolve())" in body


def test_native_example_defaults_to_private_external_exposure():
    environment = (Path(__file__).resolve().parents[1] / ".env.example").read_text(encoding="utf-8")
    assert "EXTERNAL_EXPOSURE_MODE=none" in environment
    assert "CLOUDFLARED_TOKEN_FILE=/opt/vllm-ai-platform/secrets/cloudflare_tunnel_token" in environment


def test_curated_catalog_contains_pinned_current_stable_models():
    platform_root = Path(__file__).resolve().parents[1]
    catalog = json.loads((platform_root / "config" / "model-catalog.json").read_text(encoding="utf-8"))
    models = catalog["models"]

    assert catalog["schema_version"] >= 2
    assert catalog["validated_vllm_version"] == "0.30.0"
    assert {"Qwen/Qwen3.5-4B", "Qwen/Qwen3.5-9B"} <= {model["model_id"] for model in models}
    assert len({model["key"] for model in models}) == len(models)
    for model in models:
        assert model["release_channel"] == "stable"
        assert re.fullmatch(r"[0-9a-f]{40}", model["revision"])
        assert model["display_name"] and model["summary"]
        assert model["estimated_weight_gb"] > 0
        assert model["recommended_vram_gb"] > 0


def test_model_add_cli_accepts_managed_reasoning_and_memory_defaults():
    args = build_parser().parse_args(
        [
            "models", "add", "--model-id", "Qwen/Qwen3.5-4B", "--alias", "qwen35",
            "--reasoning-parser", "qwen3", "--gpu-memory-utilization", "0.86",
        ]
    )

    assert args.reasoning_parser == "qwen3"
    assert args.gpu_memory_utilization == 0.86
