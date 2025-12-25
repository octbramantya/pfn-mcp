"""Devices tool - browse and search devices."""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)


async def list_devices(
    search: str | None = None,
    tenant_id: int | None = None,
    limit: int = 20,
) -> list[dict]:
    """
    List devices with optional search and tenant filter.

    Args:
        search: Search term for device name (fuzzy matching)
        tenant_id: Filter by tenant ID
        limit: Maximum number of results

    Returns:
        List of device dictionaries with tenant context
    """
    conditions = ["d.is_active = true"]
    params = []
    param_idx = 1

    # Tenant filter
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    # Search filter with ranking for better fuzzy match
    order_clause = "d.display_name, d.device_name"
    if search:
        search_term = search.strip()
        # Use ILIKE for case-insensitive matching
        conditions.append(
            f"(d.display_name ILIKE ${param_idx} OR d.device_name ILIKE ${param_idx})"
        )
        params.append(f"%{search_term}%")
        param_idx += 1

        # Order by match quality:
        # 1. Exact match (highest priority)
        # 2. Starts with search term
        # 3. Contains search term
        order_clause = f"""
            CASE
                WHEN LOWER(d.display_name) = LOWER(${param_idx}) THEN 0
                WHEN LOWER(d.display_name) LIKE LOWER(${param_idx}) || ' %' THEN 1
                WHEN LOWER(d.display_name) LIKE LOWER(${param_idx}) || '%' THEN 2
                ELSE 3
            END,
            d.display_name, d.device_name
        """
        params.append(search_term)
        param_idx += 1

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            d.id,
            d.device_code,
            d.device_name,
            d.display_name,
            d.device_type,
            d.tenant_id,
            t.tenant_name,
            t.tenant_code
        FROM devices d
        LEFT JOIN tenants t ON d.tenant_id = t.id
        WHERE {where_clause}
        ORDER BY {order_clause}
        LIMIT ${param_idx}
    """
    params.append(limit)

    rows = await db.fetch_all(query, *params)
    return rows


def format_devices_response(devices: list[dict], search: str | None = None) -> str:
    """Format devices list for human-readable output."""
    if not devices:
        if search:
            return f"No devices found matching '{search}'."
        return "No devices found."

    # Group by tenant
    by_tenant: dict[str, list[dict]] = {}
    for d in devices:
        tenant = d.get("tenant_name") or "Unknown Tenant"
        if tenant not in by_tenant:
            by_tenant[tenant] = []
        by_tenant[tenant].append(d)

    lines = [f"Found {len(devices)} device(s):\n"]

    for tenant in sorted(by_tenant.keys()):
        items = by_tenant[tenant]
        lines.append(f"\n## {tenant}")
        lines.append("")

        for d in items:
            name = d.get("display_name") or d.get("device_name")
            device_type = d.get("device_type") or "-"
            lines.append(f"- **{name}** (ID: {d['id']})")
            lines.append(f"  Type: {device_type} | Code: `{d['device_code']}`")

    return "\n".join(lines)
