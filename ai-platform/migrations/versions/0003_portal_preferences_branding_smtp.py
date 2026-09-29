"""Portal preferences and password reset support.

Revision ID: 0003
Revises: 0002
"""
from alembic import op
import sqlalchemy as sa


revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "reasoning_effort" not in _columns("users"):
        op.add_column(
            "users",
            sa.Column("reasoning_effort", sa.String(length=16), nullable=False, server_default="medium"),
        )
    if "password_reset_tokens" not in inspector.get_table_names():
        op.create_table(
            "password_reset_tokens",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("token_hash", sa.String(length=64), nullable=False),
            sa.Column("requested_ip", sa.String(length=64), nullable=False),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        )
        op.create_index("ix_password_reset_tokens_user_id", "password_reset_tokens", ["user_id"])
        op.create_index("ix_password_reset_tokens_token_hash", "password_reset_tokens", ["token_hash"], unique=True)
        op.create_index("ix_password_reset_tokens_expires_at", "password_reset_tokens", ["expires_at"])
        op.create_index("ix_password_reset_tokens_used_at", "password_reset_tokens", ["used_at"])
        op.create_index("ix_password_reset_tokens_created_at", "password_reset_tokens", ["created_at"])


def downgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "password_reset_tokens" in inspector.get_table_names():
        op.drop_table("password_reset_tokens")
    if "reasoning_effort" in _columns("users"):
        op.drop_column("users", "reasoning_effort")
