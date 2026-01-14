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


async def resolve_device(
    device_id: int | None = None,
    device_name: str | None = None,
    tenant_id: int | None = None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Unified device resolution with optional tenant filtering.

    Supports lookup by device_id (exact) or device_name (fuzzy match).
    When tenant_id is provided, restricts results to that tenant.

    Args:
        device_id: Exact device ID lookup (highest priority)
        device_name: Fuzzy name search (if device_id not provided)
        tenant_id: Optional tenant ID to filter results

    Returns:
        Tuple of (device_id, device_info_dict, error_message):
        - On success: (id, {"id": ..., "display_name": ..., "device_code": ...,
          "tenant_id": ...}, None)
        - On not found: (None, None, "Device not found: {search_term}")
        - On missing input: (None, None, "Either device_id or device_name is required")

    Example:
        # Lookup by ID (ignores tenant filter for exact match)
        device_id, info, error = await resolve_device(device_id=123)

        # Lookup by name with tenant filter
        device_id, info, error = await resolve_device(
            device_name="Panel Utama",
            tenant_id=1  # Only search within this tenant
        )

        # Superuser lookup (no tenant filter)
        device_id, info, error = await resolve_device(device_name="Panel")
    """
    if device_id is None and device_name is None:
        return None, None, "Either device_id or device_name is required"

    # Exact lookup by device_id
    if device_id is not None:
        device = await db.fetch_one(
            """SELECT id, display_name, device_code, tenant_id
               FROM devices WHERE id = $1 AND is_active = true""",
            device_id,
        )
        if not device:
            return None, None, f"Device ID not found: {device_id}"

        # Optionally validate tenant access
        if tenant_id is not None and device["tenant_id"] != tenant_id:
            return None, None, f"Device ID {device_id} not accessible for this tenant"

        return device["id"], dict(device), None

    # Fuzzy lookup by device_name
    if tenant_id is not None:
        # Tenant-filtered fuzzy search
        device = await db.fetch_one(
            """SELECT id, display_name, device_code, tenant_id
               FROM devices
               WHERE is_active = true
                 AND tenant_id = $1
                 AND (display_name ILIKE $2 OR device_name ILIKE $2)
               ORDER BY
                   CASE
                       WHEN LOWER(display_name) = LOWER($3) THEN 0
                       WHEN LOWER(display_name) LIKE LOWER($3) || '%' THEN 1
                       ELSE 2
                   END
               LIMIT 1""",
            tenant_id,
            f"%{device_name}%",
            device_name,
        )
    else:
        # Global fuzzy search (superuser)
        device = await db.fetch_one(
            """SELECT id, display_name, device_code, tenant_id
               FROM devices
               WHERE is_active = true
                 AND (display_name ILIKE $1 OR device_name ILIKE $1)
               ORDER BY
                   CASE
                       WHEN LOWER(display_name) = LOWER($2) THEN 0
                       WHEN LOWER(display_name) LIKE LOWER($2) || '%' THEN 1
                       ELSE 2
                   END
               LIMIT 1""",
            f"%{device_name}%",
            device_name,
        )

    if not device:
        if tenant_id is not None:
            return None, None, f"Device not found in tenant: {device_name}"
        return None, None, f"Device not found: {device_name}"

    return device["id"], dict(device), None
