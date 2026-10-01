"""Add TOTP MFA policy and per-session verification state.

Revision ID: 0008
Revises: 0007
"""
from alembic import op
import sqlalchemy as sa


revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    user_columns = _columns("users")
    for name, column_type in [
        ("totp_confirmed_at", sa.DateTime(timezone=True)),
        ("totp_last_verified_at", sa.DateTime(timezone=True)),
        ("totp_last_used_step", sa.BigInteger()),
        ("totp_grace_started_at", sa.DateTime(timezone=True)),
        ("totp_grace_expires_at", sa.DateTime(timezone=True)),
    ]:
        if name not in user_columns:
            op.add_column("users", sa.Column(name, column_type, nullable=True))

    session_columns = _columns("web_sessions")
    if "mfa_verified_at" not in session_columns:
        op.add_column("web_sessions", sa.Column("mfa_verified_at", sa.DateTime(timezone=True), nullable=True))
    if "mfa_grace_skipped" not in session_columns:
        op.add_column("web_sessions", sa.Column("mfa_grace_skipped", sa.Boolean(), nullable=False, server_default=sa.false()))
    if "mfa_intended_path" not in session_columns:
        op.add_column("web_sessions", sa.Column("mfa_intended_path", sa.String(length=1024), nullable=True))


def downgrade() -> None:
    session_columns = _columns("web_sessions")
    for name in ["mfa_intended_path", "mfa_grace_skipped", "mfa_verified_at"]:
        if name in session_columns:
            op.drop_column("web_sessions", name)
    user_columns = _columns("users")
    for name in [
        "totp_grace_expires_at",
        "totp_grace_started_at",
        "totp_last_used_step",
        "totp_last_verified_at",
        "totp_confirmed_at",
    ]:
        if name in user_columns:
            op.drop_column("users", name)
