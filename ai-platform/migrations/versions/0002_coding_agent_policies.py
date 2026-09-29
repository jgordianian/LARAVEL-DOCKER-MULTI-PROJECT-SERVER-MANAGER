"""Coding-agent service-account and permission policy.

Revision ID: 0002
Revises: 0001
"""
from alembic import op
import sqlalchemy as sa


revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    # 0001 deliberately creates current metadata for clean installations. The
    # checks keep this migration safe both for those databases and for existing
    # schema-v1 deployments.
    service_columns = _columns("service_accounts")
    if "purpose" not in service_columns:
        op.add_column(
            "service_accounts",
            sa.Column("purpose", sa.String(length=32), nullable=False, server_default="general_api"),
        )
        op.create_index("ix_service_accounts_purpose", "service_accounts", ["purpose"])
    if "allowed_endpoints" not in service_columns:
        op.add_column(
            "service_accounts",
            sa.Column("allowed_endpoints", sa.JSON(), nullable=False, server_default=sa.text("'[]'")),
        )

    key_columns = _columns("api_keys")
    if "allowed_endpoints" not in key_columns:
        op.add_column(
            "api_keys",
            sa.Column("allowed_endpoints", sa.JSON(), nullable=False, server_default=sa.text("'[]'")),
        )

    permission_columns = _columns("model_permissions")
    if "can_code" not in permission_columns:
        op.add_column(
            "model_permissions",
            sa.Column("can_code", sa.Boolean(), nullable=False, server_default=sa.false()),
        )


def downgrade() -> None:
    permission_columns = _columns("model_permissions")
    if "can_code" in permission_columns:
        op.drop_column("model_permissions", "can_code")
    key_columns = _columns("api_keys")
    if "allowed_endpoints" in key_columns:
        op.drop_column("api_keys", "allowed_endpoints")
    service_columns = _columns("service_accounts")
    if "allowed_endpoints" in service_columns:
        op.drop_column("service_accounts", "allowed_endpoints")
    if "purpose" in service_columns:
        op.drop_index("ix_service_accounts_purpose", table_name="service_accounts")
        op.drop_column("service_accounts", "purpose")
