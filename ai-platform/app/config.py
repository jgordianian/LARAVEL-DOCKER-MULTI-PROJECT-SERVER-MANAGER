from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", case_sensitive=False)

    ai_platform_schema_version: int = 2
    ai_domain: str = "localhost"
    cloudflare_api_hostname: str = ""
    database_url: str
    redis_url: str
    app_secret: str
    api_key_pepper: str
    internal_gateway_token: str
    controller_token: str
    proxy_shared_token: str
    trusted_proxy_cidrs: str = "127.0.0.1/32,::1/128"
    global_allowed_cidrs: str = ""
    allowed_origins: str = ""
    cookie_secure: bool = True
    admin_panel_enabled: bool = True
    chat_portal_enabled: bool = True
    prompt_logging: bool = False
    ai_disk_reserve_gb: int = 20
    ai_internal_network: str = "vllm-ai-internal"
    ai_shared_network: str = "laravel-shared"
    ai_platform_root: Path = Path("/opt/vllm-ai-platform")
    ai_runtime_mode: str = "docker"
    vllm_image: str = "vllm/vllm-openai:v0.30.0"
    native_vllm_version: str = "0.30.0"
    native_vllm_executable: Path = Path("/opt/vllm-ai-platform/native/vllm-venv/bin/vllm")
    native_gateway_port: int = 8000
    native_web_port: int = 18080
    native_controller_port: int = 8090
    native_redis_port: int = 16379
    native_vllm_port_start: int = 19000
    native_vllm_port_end: int = 19999
    native_service_user: str = "vllmai"
    hf_token_file: Path = Path("/run/secrets/hf_token")
    gateway_internal_url: str = "http://gateway:8000"
    controller_internal_url: str = "http://controller:8090"
    max_request_bytes: int = 4 * 1024 * 1024
    session_ttl_seconds: int = 12 * 60 * 60

    @field_validator("app_secret", "api_key_pepper", "internal_gateway_token", "controller_token", "proxy_shared_token")
    @classmethod
    def secrets_must_not_be_blank(cls, value: str) -> str:
        if len(value) < 16:
            raise ValueError("security secrets must be at least 16 characters")
        return value

    @field_validator("ai_runtime_mode")
    @classmethod
    def runtime_mode_must_be_supported(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"docker", "native"}:
            raise ValueError("AI_RUNTIME_MODE must be docker or native")
        return normalized

    @field_validator(
        "native_gateway_port",
        "native_web_port",
        "native_controller_port",
        "native_redis_port",
        "native_vllm_port_start",
        "native_vllm_port_end",
    )
    @classmethod
    def native_ports_must_be_valid(cls, value: int) -> int:
        if not 1024 <= value <= 65535:
            raise ValueError("native service ports must be between 1024 and 65535")
        return value

    @field_validator("native_service_user")
    @classmethod
    def native_service_user_must_be_valid(cls, value: str) -> str:
        normalized = value.strip()
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", normalized):
            raise ValueError("NATIVE_SERVICE_USER is invalid")
        return normalized

    @property
    def trusted_proxy_networks(self) -> list[str]:
        return [value.strip() for value in self.trusted_proxy_cidrs.split(",") if value.strip()]

    @property
    def global_allowed_networks(self) -> list[str]:
        return [value.strip() for value in self.global_allowed_cidrs.split(",") if value.strip()]

    @property
    def cors_origins(self) -> list[str]:
        return [value.strip() for value in self.allowed_origins.split(",") if value.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
