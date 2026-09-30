from __future__ import annotations

import base64
import json
from collections.abc import Sequence
from typing import Any

from .capabilities import model_capabilities
from .models import ModelRecord


CODEX_PROVIDER_ID = "omnivis_gateway"
CODEX_CATALOG_FILENAME = "omnivis-models.json"
CODEX_TOKEN_FILENAME = "omnivis-api-key"


def _reasoning_levels(model: ModelRecord) -> list[dict[str, str]]:
    if "reasoning" not in model_capabilities(model):
        return [{"effort": "none", "description": "Fast responses without extended reasoning"}]
    return [
        {"effort": "none", "description": "Fast responses without extended reasoning"},
        {"effort": "low", "description": "Reasoning for routine coding tasks"},
        {"effort": "medium", "description": "Balanced reasoning for coding and tool use"},
        {"effort": "high", "description": "Extended reasoning for complex tasks"},
    ]


def codex_model_catalog(models: Sequence[ModelRecord]) -> dict[str, Any]:
    rows = []
    for priority, model in enumerate(models, start=1):
        capabilities = model_capabilities(model)
        reasoning = "reasoning" in capabilities
        context_window = max(1_024, int(model.max_model_len or 4_096))
        rows.append(
            {
                "slug": model.alias,
                "display_name": model.alias,
                "description": f"Private {model.hf_model_id} served by the Omnivis vLLM gateway.",
                "default_reasoning_level": "medium" if reasoning else "none",
                "supported_reasoning_levels": _reasoning_levels(model),
                "shell_type": "unified_exec",
                "visibility": "list",
                "supported_in_api": True,
                "priority": 101 - priority,
                "additional_speed_tiers": [],
                "service_tiers": [],
                "availability_nux": None,
                "upgrade": None,
                "model_messages": None,
                "include_skills_usage_instructions": False,
                "include_plugin_usage_instructions": False,
                "include_apps_usage_instructions": False,
                "default_reasoning_summary": "none",
                "support_verbosity": False,
                "default_verbosity": None,
                "apply_patch_tool_type": None,
                "web_search_tool_type": "text",
                "truncation_policy": {"mode": "bytes", "limit": 10_000},
                "supports_image_detail_original": False,
                "context_window": context_window,
                "max_context_window": context_window,
                "comp_hash": f"omnivis-{model.id}-{model.revision}",
                "effective_context_window_percent": 95,
                "experimental_supported_tools": [],
                "input_modalities": ["text"],
                "supports_search_tool": False,
                "supports_experimental_context": False,
                "use_responses_lite": False,
                "node_repl_auto_review_required": False,
                "node_repl_disabled": True,
                "tool_mode": None,
                "multi_agent_version": "v1",
                "multi_agent_reasoning_effort": None,
                "base_instructions": (
                    "You are Codex, a coding agent. Follow developer and user instructions, "
                    "use the available tools when needed, preserve unrelated work, and report results accurately."
                ),
            }
        )
    return {"models": rows}


def codex_config(models: Sequence[ModelRecord], api_base_url: str, platform: str) -> str:
    if not models:
        raise ValueError("at least one Codex-compatible model is required")
    default = next((model for model in models if model.is_default), models[0])
    effort = "medium" if "reasoning" in model_capabilities(default) else "none"
    if platform == "windows":
        auth_command = "powershell.exe"
        auth_args = [
            "-NoProfile",
            "-Command",
            '(Get-Content -Raw -LiteralPath "__CODEX_TOKEN_PATH__").Trim()',
        ]
    else:
        auth_command = "sh"
        auth_args = ["-c", 'cat "__CODEX_TOKEN_PATH__"']
    return "\n".join(
        [
            f"model = {json.dumps(default.alias)}",
            f"model_provider = {json.dumps(CODEX_PROVIDER_ID)}",
            f"model_context_window = {max(1_024, int(default.max_model_len or 4_096))}",
            f"model_reasoning_effort = {json.dumps(effort)}",
            'model_catalog_json = "__CODEX_CATALOG_PATH__"',
            "",
            f"[model_providers.{CODEX_PROVIDER_ID}]",
            'name = "Omnivis Private vLLM Gateway"',
            f"base_url = {json.dumps(api_base_url.rstrip('/'))}",
            'wire_api = "responses"',
            "request_max_retries = 2",
            "stream_max_retries = 2",
            "stream_idle_timeout_ms = 300000",
            "",
            f"[model_providers.{CODEX_PROVIDER_ID}.auth]",
            f"command = {json.dumps(auth_command)}",
            f"args = {json.dumps(auth_args)}",
            "timeout_ms = 5000",
            "refresh_interval_ms = 0",
            "",
            "[features]",
            "apps = false",
            "guardian_approval = false",
            "",
        ]
    )


def _encoded(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def codex_installer_script(models: Sequence[ModelRecord], api_base_url: str, platform: str) -> str:
    config = codex_config(models, api_base_url, platform)
    catalog = json.dumps(codex_model_catalog(models), ensure_ascii=False, indent=2) + "\n"
    config_payload = _encoded(config)
    catalog_payload = _encoded(catalog)
    default = next((model for model in models if model.is_default), models[0])
    if platform == "windows":
        return f"""$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:OMNIVIS_CODING_API_KEY)) {{ throw 'OMNIVIS_CODING_API_KEY is required.' }}
$codexDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {{ Join-Path $HOME '.codex' }} else {{ $env:CODEX_HOME }}
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
$configPath = Join-Path $codexDir 'config.toml'
$catalogPath = Join-Path $codexDir '{CODEX_CATALOG_FILENAME}'
$tokenPath = Join-Path $codexDir '{CODEX_TOKEN_FILENAME}'
if (Test-Path -LiteralPath $configPath) {{
  $backupPath = Join-Path $codexDir ('config.toml.backup-' + (Get-Date -Format 'yyyyMMddHHmmss'))
  Copy-Item -LiteralPath $configPath -Destination $backupPath
  Write-Host ('Existing Codex configuration backed up to ' + $backupPath)
}}
$utf8 = New-Object System.Text.UTF8Encoding($false)
$configTemplate = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{config_payload}'))
$configText = $configTemplate.Replace('__CODEX_CATALOG_PATH__', $catalogPath.Replace('\\', '/')).Replace('__CODEX_TOKEN_PATH__', $tokenPath.Replace('\\', '/'))
[IO.File]::WriteAllText($configPath, $configText, $utf8)
$catalogText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{catalog_payload}'))
[IO.File]::WriteAllText($catalogPath, $catalogText, $utf8)
[IO.File]::WriteAllText($tokenPath, $env:OMNIVIS_CODING_API_KEY.Trim() + [Environment]::NewLine, $utf8)
Write-Host 'Omnivis Codex configuration installed successfully.'
Write-Host 'Restart Visual Studio Code, then select model {default.alias} in Codex.'
"""

    decode_flag = "-D" if platform == "macos" else "-d"
    platform_name = "macOS" if platform == "macos" else "Linux"
    return f"""set -eu
: "${{OMNIVIS_CODING_API_KEY:?OMNIVIS_CODING_API_KEY is required.}}"
umask 077
codex_dir="${{CODEX_HOME:-$HOME/.codex}}"
mkdir -p "$codex_dir"
config_path="$codex_dir/config.toml"
catalog_path="$codex_dir/{CODEX_CATALOG_FILENAME}"
token_path="$codex_dir/{CODEX_TOKEN_FILENAME}"
if [ -f "$config_path" ]; then
  backup_path="$codex_dir/config.toml.backup-$(date +%Y%m%d%H%M%S)"
  cp "$config_path" "$backup_path"
  printf '%s\\n' "Existing Codex configuration backed up to $backup_path"
fi
config_tmp="$codex_dir/.omnivis-config.$$"
trap 'rm -f "$config_tmp"' EXIT HUP INT TERM
printf '%s' '{config_payload}' | base64 {decode_flag} > "$config_tmp"
catalog_escaped=$(printf '%s' "$catalog_path" | sed 's/[\\/&]/\\\\&/g')
token_escaped=$(printf '%s' "$token_path" | sed 's/[\\/&]/\\\\&/g')
sed -e "s/__CODEX_CATALOG_PATH__/$catalog_escaped/g" -e "s/__CODEX_TOKEN_PATH__/$token_escaped/g" "$config_tmp" > "$config_path"
printf '%s' '{catalog_payload}' | base64 {decode_flag} > "$catalog_path"
printf '%s\\n' "$OMNIVIS_CODING_API_KEY" > "$token_path"
chmod 600 "$config_path" "$catalog_path" "$token_path"
rm -f "$config_tmp"
trap - EXIT HUP INT TERM
printf '%s\\n' 'Omnivis Codex configuration installed successfully.'
printf '%s\\n' 'Restart Visual Studio Code, then select model {default.alias} in Codex on {platform_name}.'
"""
