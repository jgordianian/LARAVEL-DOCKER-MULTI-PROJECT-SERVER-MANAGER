"""Global and per-user localization preferences.

Revision ID: 0004
Revises: 0003
"""
from alembic import op
import sqlalchemy as sa


revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    if "preferred_language" not in _columns("users"):
        op.add_column("users", sa.Column("preferred_language", sa.String(length=8), nullable=True))


def downgrade() -> None:
    if "preferred_language" in _columns("users"):
        op.drop_column("users", "preferred_language")
