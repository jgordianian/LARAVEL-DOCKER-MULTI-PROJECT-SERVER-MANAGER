"""Add private user profile photos.

Revision ID: 0007
Revises: 0006
"""
from alembic import op
import sqlalchemy as sa


revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def _columns(table: str) -> set[str]:
    return {column["name"] for column in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    if "profile_photo_key" not in _columns("users"):
        op.add_column("users", sa.Column("profile_photo_key", sa.String(length=96), nullable=True))


def downgrade() -> None:
    if "profile_photo_key" in _columns("users"):
        op.drop_column("users", "profile_photo_key")
