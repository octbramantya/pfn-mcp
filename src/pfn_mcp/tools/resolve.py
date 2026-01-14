"""Shared resolution utilities for tenant and device lookups.

This module provides common resolution functions used across multiple tools
to convert user-friendly names/codes to database IDs with fuzzy matching.

Key behavior for tenant resolution:
- resolve_tenant(None) returns (None, None, None) - "superuser mode", no filtering
- resolve_tenant("PRS") resolves tenant_code with priority over tenant_name
- Resolution uses fuzzy matching: exact > starts-with > contains
"""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)


async def resolve_tenant(
    tenant: str | None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve tenant name or code to tenant ID using fuzzy match.

    Supports both tenant_code (e.g., "PRS") and tenant_name (e.g., "PT Persada").
    tenant_code exact match has highest priority for frontend integration.

    Args:
        tenant: Tenant name or code string, or None for superuser mode

    Returns:
        Tuple of (tenant_id, tenant_info_dict, error_message):
        - On success: (id, {"id": id, "tenant_name": ..., "tenant_code": ...}, None)
        - On not found: (None, None, "Tenant not found: {tenant}")
        - On None input: (None, None, None) - superuser mode, no filtering

    Example:
        # Regular user with tenant
        tenant_id, info, error = await resolve_tenant("PRS")
        if error:
            return {"error": error}

        # Superuser mode (all tenants)
        tenant_id, info, error = await resolve_tenant(None)
        # tenant_id is None, no filtering applied
    """
    if not tenant:
        return None, None, None

    tenant_row = await db.fetch_one(
        """
        SELECT id, tenant_name, tenant_code
        FROM tenants
        WHERE is_active = true
          AND (tenant_name ILIKE $1 OR tenant_code ILIKE $1)
        ORDER BY
            CASE
                WHEN LOWER(tenant_code) = LOWER($2) THEN 0
                WHEN LOWER(tenant_name) = LOWER($2) THEN 1
                WHEN LOWER(tenant_name) LIKE LOWER($2) || '%' THEN 2
                ELSE 3
            END
        LIMIT 1
        """,
        f"%{tenant}%",
        tenant,
    )

    if not tenant_row:
        return None, None, f"Tenant not found: {tenant}"

    return tenant_row["id"], dict(tenant_row), None
