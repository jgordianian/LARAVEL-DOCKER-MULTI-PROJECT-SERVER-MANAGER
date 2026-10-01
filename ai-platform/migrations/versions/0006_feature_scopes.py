"""Add explicit reasoning, structured-output and vision policy scopes.

Revision ID: 0006
Revises: 0005
"""
from alembic import op
import sqlalchemy as sa


revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


FEATURE_SCOPE_BASES = {
    "reasoning": {"chat", "responses"},
    "structured_outputs": {"chat", "completions", "responses"},
    "vision": {"chat", "responses"},
}


def _update_existing_policies(*, remove: bool = False) -> None:
    bind = op.get_bind()
    metadata = sa.MetaData()
    for table_name, scopes_column in (("service_accounts", "allowed_scopes"), ("api_keys", "scopes")):
        table = sa.Table(table_name, metadata, autoload_with=bind)
        rows = bind.execute(sa.select(table.c.id, table.c[scopes_column])).all()
        for row_id, stored_scopes in rows:
            scopes = list(stored_scopes or [])
            # An empty list means unrestricted/inherited and must stay empty.
            if not scopes:
                continue
            if remove:
                updated = [scope for scope in scopes if scope not in FEATURE_SCOPE_BASES]
            else:
                updated = list(scopes)
                base_scopes = set(scopes)
                for feature_scope, required_bases in FEATURE_SCOPE_BASES.items():
                    if base_scopes.intersection(required_bases) and feature_scope not in updated:
                        updated.append(feature_scope)
            if updated != scopes:
                bind.execute(
                    sa.update(table).where(table.c.id == row_id).values({scopes_column: updated})
                )


def upgrade() -> None:
    # Before these scopes existed, every key allowed to use the underlying
    # endpoint could use these model features. Preserve that behavior while
    # making the features independently restrictable for future policies.
    _update_existing_policies()


def downgrade() -> None:
    _update_existing_policies(remove=True)
