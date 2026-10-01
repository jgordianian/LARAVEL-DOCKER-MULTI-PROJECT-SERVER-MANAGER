from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from sqlalchemy import BigInteger, Boolean, DateTime, Float, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy import JSON
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False)


class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[str] = mapped_column(String(32), default="user", index=True, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    force_password_reset: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    totp_secret_encrypted: Mapped[str | None] = mapped_column(Text)
    totp_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    totp_confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    totp_last_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    totp_last_used_step: Mapped[int | None] = mapped_column(BigInteger)
    totp_grace_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    totp_grace_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    default_model_alias: Mapped[str | None] = mapped_column(String(160))
    system_prompt: Mapped[str | None] = mapped_column(Text)
    reasoning_effort: Mapped[str] = mapped_column(String(16), default="medium", nullable=False)
    preferred_language: Mapped[str | None] = mapped_column(String(8))
    profile_photo_key: Mapped[str | None] = mapped_column(String(96))


class WebSession(Base):
    __tablename__ = "web_sessions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    csrf_token: Mapped[str] = mapped_column(String(96), nullable=False)
    ip_address: Mapped[str] = mapped_column(String(64), nullable=False)
    user_agent: Mapped[str] = mapped_column(String(512), default="", nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    mfa_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    mfa_grace_skipped: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    mfa_intended_path: Mapped[str | None] = mapped_column(String(1024))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    user: Mapped[User] = relationship()


class PasswordResetToken(Base):
    __tablename__ = "password_reset_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    requested_ip: Mapped[str] = mapped_column(String(64), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    user: Mapped[User] = relationship()


class ServiceAccount(TimestampMixin, Base):
    __tablename__ = "service_accounts"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(160), unique=True, nullable=False)
    description: Mapped[str] = mapped_column(Text, default="", nullable=False)
    purpose: Mapped[str] = mapped_column(String(32), default="general_api", index=True, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    allowed_models: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    allowed_scopes: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    allowed_endpoints: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    allow_custom_system_messages: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)


class APIKey(TimestampMixin, Base):
    __tablename__ = "api_keys"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    key_id: Mapped[str] = mapped_column(String(24), unique=True, index=True, nullable=False)
    key_prefix: Mapped[str] = mapped_column(String(32), index=True, nullable=False)
    secret_hash: Mapped[str] = mapped_column(Text, nullable=False)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    service_account_id: Mapped[int | None] = mapped_column(ForeignKey("service_accounts.id", ondelete="CASCADE"), index=True)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    allowed_cidrs: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    allowed_models: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    allowed_endpoints: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    scopes: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    requests_per_minute: Mapped[int] = mapped_column(Integer, default=60, nullable=False)
    tokens_per_minute: Mapped[int] = mapped_column(Integer, default=60_000, nullable=False)
    concurrent_requests: Mapped[int] = mapped_column(Integer, default=4, nullable=False)
    requests_per_day: Mapped[int] = mapped_column(Integer, default=10_000, nullable=False)
    requests_per_month: Mapped[int] = mapped_column(Integer, default=100_000, nullable=False)
    tokens_per_day: Mapped[int] = mapped_column(Integer, default=2_000_000, nullable=False)
    tokens_per_month: Mapped[int] = mapped_column(Integer, default=20_000_000, nullable=False)
    max_input_tokens: Mapped[int] = mapped_column(Integer, default=32_768, nullable=False)
    max_output_tokens: Mapped[int] = mapped_column(Integer, default=8_192, nullable=False)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    user: Mapped[User | None] = relationship()
    service_account: Mapped[ServiceAccount | None] = relationship()

    __table_args__ = (
        Index("ix_api_keys_active", "enabled", "revoked_at", "expires_at"),
    )


class ModelRecord(TimestampMixin, Base):
    __tablename__ = "models"

    id: Mapped[int] = mapped_column(primary_key=True)
    hf_model_id: Mapped[str] = mapped_column(String(512), nullable=False)
    revision: Mapped[str] = mapped_column(String(160), default="main", nullable=False)
    alias: Mapped[str] = mapped_column(String(160), unique=True, index=True, nullable=False)
    local_path: Mapped[str | None] = mapped_column(String(1024))
    source_type: Mapped[str] = mapped_column(String(32), default="huggingface", nullable=False)
    download_status: Mapped[str] = mapped_column(String(32), default="registered", index=True, nullable=False)
    download_error: Mapped[str | None] = mapped_column(Text)
    size_bytes: Mapped[int | None] = mapped_column(BigInteger)
    estimated_weight_gb: Mapped[float | None] = mapped_column(Float)
    capabilities: Mapped[list[str]] = mapped_column(JSON, default=lambda: ["chat", "completions"], nullable=False)
    quantization: Mapped[str | None] = mapped_column(String(64))
    dtype: Mapped[str] = mapped_column(String(32), default="auto", nullable=False)
    max_model_len: Mapped[int] = mapped_column(Integer, default=4096, nullable=False)
    trust_remote_code: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    tool_calling: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    tool_call_parser: Mapped[str | None] = mapped_column(String(96))
    chat_template: Mapped[str | None] = mapped_column(Text)
    system_prompt: Mapped[str | None] = mapped_column(Text)
    auto_start: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    config: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict, nullable=False)
    instance: Mapped["ModelInstance | None"] = relationship(back_populates="model", uselist=False, cascade="all, delete-orphan")

    __table_args__ = (UniqueConstraint("hf_model_id", "revision", "alias", name="uq_model_revision_alias"),)


class ModelInstance(TimestampMixin, Base):
    __tablename__ = "model_instances"

    id: Mapped[int] = mapped_column(primary_key=True)
    model_id: Mapped[int] = mapped_column(ForeignKey("models.id", ondelete="CASCADE"), unique=True, index=True)
    desired_active: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="inactive", index=True, nullable=False)
    container_name: Mapped[str] = mapped_column(String(160), unique=True, nullable=False)
    internal_url: Mapped[str] = mapped_column(String(512), nullable=False)
    gpu_assignment: Mapped[list[int]] = mapped_column(JSON, default=list, nullable=False)
    tensor_parallel_size: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    pipeline_parallel_size: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    performance_profile: Mapped[str] = mapped_column(String(32), default="AUTO", nullable=False)
    gpu_memory_utilization: Mapped[float] = mapped_column(Float, default=0.82, nullable=False)
    max_num_seqs: Mapped[int] = mapped_column(Integer, default=4, nullable=False)
    max_num_batched_tokens: Mapped[int | None] = mapped_column(Integer)
    cpu_offload_gb: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    swap_space_gb: Mapped[float] = mapped_column(Float, default=4.0, nullable=False)
    enable_prefix_caching: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    extra_args: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    estimated_vram_gb: Mapped[float | None] = mapped_column(Float)
    ready_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error: Mapped[str | None] = mapped_column(Text)
    model: Mapped[ModelRecord] = relationship(back_populates="instance")


class ModelPermission(Base):
    __tablename__ = "model_permissions"

    id: Mapped[int] = mapped_column(primary_key=True)
    subject_type: Mapped[str] = mapped_column(String(32), index=True)
    subject_id: Mapped[int] = mapped_column(Integer, index=True)
    model_id: Mapped[int] = mapped_column(ForeignKey("models.id", ondelete="CASCADE"), index=True)
    can_chat: Mapped[bool] = mapped_column(Boolean, default=True)
    can_use_tools: Mapped[bool] = mapped_column(Boolean, default=False)
    can_code: Mapped[bool] = mapped_column(Boolean, default=False)

    __table_args__ = (UniqueConstraint("subject_type", "subject_id", "model_id", name="uq_model_permission"),)


class IPRule(TimestampMixin, Base):
    __tablename__ = "ip_rules"

    id: Mapped[int] = mapped_column(primary_key=True)
    subject_type: Mapped[str] = mapped_column(String(32), default="global", index=True)
    subject_id: Mapped[int | None] = mapped_column(Integer, index=True)
    cidr: Mapped[str] = mapped_column(String(96), nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    description: Mapped[str] = mapped_column(String(255), default="", nullable=False)

    __table_args__ = (UniqueConstraint("subject_type", "subject_id", "cidr", name="uq_ip_rule_subject"),)


class Quota(TimestampMixin, Base):
    __tablename__ = "quotas"

    id: Mapped[int] = mapped_column(primary_key=True)
    subject_type: Mapped[str] = mapped_column(String(32), index=True)
    subject_id: Mapped[int] = mapped_column(Integer, index=True)
    limits: Mapped[dict[str, int]] = mapped_column(JSON, default=dict, nullable=False)

    __table_args__ = (UniqueConstraint("subject_type", "subject_id", name="uq_quota_subject"),)


class Conversation(TimestampMixin, Base):
    __tablename__ = "conversations"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(255), default="New conversation", nullable=False)
    model_alias: Mapped[str] = mapped_column(String(160), nullable=False)
    archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    messages: Mapped[list["Message"]] = relationship(cascade="all, delete-orphan", order_by="Message.created_at")


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(primary_key=True)
    conversation_id: Mapped[int] = mapped_column(ForeignKey("conversations.id", ondelete="CASCADE"), index=True)
    role: Mapped[str] = mapped_column(String(24), nullable=False)
    content: Mapped[str] = mapped_column(Text, default="", nullable=False)
    tool_calls: Mapped[list[dict[str, Any]]] = mapped_column(JSON, default=list, nullable=False)
    tool_call_id: Mapped[str | None] = mapped_column(String(255))
    request_id: Mapped[str | None] = mapped_column(String(64), index=True)
    input_tokens: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    attachments: Mapped[list["MessageAttachment"]] = relationship(
        back_populates="message",
        cascade="all, delete-orphan",
        order_by="MessageAttachment.id",
    )


class MessageAttachment(Base):
    __tablename__ = "message_attachments"

    id: Mapped[int] = mapped_column(primary_key=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), index=True)
    filename: Mapped[str] = mapped_column(String(255), nullable=False)
    media_type: Mapped[str] = mapped_column(String(64), nullable=False)
    storage_key: Mapped[str] = mapped_column(String(96), unique=True, index=True, nullable=False)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    message: Mapped[Message] = relationship(back_populates="attachments")


class UsageRecord(Base):
    __tablename__ = "usage_records"

    id: Mapped[int] = mapped_column(primary_key=True)
    request_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    user_id: Mapped[int | None] = mapped_column(Integer, index=True)
    service_account_id: Mapped[int | None] = mapped_column(Integer, index=True)
    api_key_id: Mapped[int | None] = mapped_column(Integer, index=True)
    source_ip: Mapped[str] = mapped_column(String(64), nullable=False)
    model_alias: Mapped[str] = mapped_column(String(160), index=True)
    model_instance_id: Mapped[int | None] = mapped_column(Integer, index=True)
    endpoint: Mapped[str] = mapped_column(String(96), nullable=False)
    input_tokens: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_tokens: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    latency_ms: Mapped[int | None] = mapped_column(Integer)
    ttft_ms: Mapped[int | None] = mapped_column(Integer)
    generation_ms: Mapped[int | None] = mapped_column(Integer)
    http_status: Mapped[int] = mapped_column(Integer, nullable=False)
    success: Mapped[bool] = mapped_column(Boolean, nullable=False)
    streaming: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    error_type: Mapped[str | None] = mapped_column(String(96))

    __table_args__ = (Index("ix_usage_subject_time", "api_key_id", "occurred_at"),)


class PerformanceProfile(TimestampMixin, Base):
    __tablename__ = "performance_profiles"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(64), unique=True)
    settings: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict, nullable=False)
    builtin: Mapped[bool] = mapped_column(Boolean, default=False)


class SystemSetting(TimestampMixin, Base):
    __tablename__ = "system_settings"

    key: Mapped[str] = mapped_column(String(160), primary_key=True)
    value: Mapped[Any] = mapped_column(JSON, nullable=False)
    secret: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)


class HardwareSnapshot(Base):
    __tablename__ = "hardware_snapshots"

    id: Mapped[int] = mapped_column(primary_key=True)
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    fingerprint: Mapped[str] = mapped_column(String(64), index=True)
    source: Mapped[str] = mapped_column(String(32), default="host")
    snapshot: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    comparison: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    acknowledged: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[int] = mapped_column(primary_key=True)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    actor_type: Mapped[str] = mapped_column(String(32), nullable=False)
    actor_id: Mapped[int | None] = mapped_column(Integer, index=True)
    source_ip: Mapped[str | None] = mapped_column(String(64))
    action: Mapped[str] = mapped_column(String(160), index=True)
    target_type: Mapped[str | None] = mapped_column(String(64))
    target_id: Mapped[str | None] = mapped_column(String(160))
    result: Mapped[str] = mapped_column(String(32), default="success")
    before: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    after: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    details: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict, nullable=False)


class BackupRecord(Base):
    __tablename__ = "backup_records"

    id: Mapped[int] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    path: Mapped[str] = mapped_column(String(1024), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), default="configuration")
    size_bytes: Mapped[int | None] = mapped_column(BigInteger)
    checksum: Mapped[str | None] = mapped_column(String(128))
    schema_version: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(32), default="complete")
