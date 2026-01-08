"""Devices tool - browse and search devices."""

import logging

from pfn_mcp import db
from pfn_mcp.tools.resolve import resolve_tenant

logger = logging.getLogger(__name__)


async def list_devices(
    search: str | None = None,
    tenant: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """
    List devices with optional search and tenant filter.

    Args:
        search: Search term for device name (fuzzy matching)
        tenant: Tenant name or code to filter devices (None = all tenants/superuser)
        limit: Maximum number of results per page
        offset: Number of results to skip for pagination

    Returns:
        Dict with devices list, total count, and pagination info
    """
    conditions = ["d.is_active = true"]
    params = []
    param_idx = 1

    # Tenant filter - resolve string to ID
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"devices": [], "total": 0, "limit": limit, "offset": offset, "has_more": False}
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

    # Use window function to get total count with results
    query = f"""
        SELECT
            d.id,
            d.device_code,
            d.device_name,
            d.display_name,
            d.device_type,
            d.tenant_id,
            t.tenant_name,
            t.tenant_code,
            COUNT(*) OVER() AS total_count
        FROM devices d
        LEFT JOIN tenants t ON d.tenant_id = t.id
        WHERE {where_clause}
        ORDER BY {order_clause}
        LIMIT ${param_idx} OFFSET ${param_idx + 1}
    """
    params.extend([limit, offset])

    rows = await db.fetch_all(query, *params)

    # Extract total from first row (all rows have same total_count)
    total = rows[0]["total_count"] if rows else 0
    # Remove total_count from device dicts
    devices = [{k: v for k, v in row.items() if k != "total_count"} for row in rows]

    return {
        "devices": devices,
        "total": total,
        "limit": limit,
        "offset": offset,
        "has_more": offset + len(devices) < total,
    }


def format_devices_response(result: dict, search: str | None = None) -> str:
    """Format devices list for human-readable output with pagination."""
    devices = result.get("devices", [])
    total = result.get("total", 0)
    limit = result.get("limit", 20)
    offset = result.get("offset", 0)
    has_more = result.get("has_more", False)

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

    # Header with pagination info
    start = offset + 1
    end = offset + len(devices)
    if total > limit:
        lines = [f"Found {total} device(s) (showing {start}-{end}):\n"]
    else:
        lines = [f"Found {total} device(s):\n"]

    for tenant in sorted(by_tenant.keys()):
        items = by_tenant[tenant]
        lines.append(f"\n## {tenant}")
        lines.append("")

        for d in items:
            name = d.get("display_name") or d.get("device_name")
            device_type = d.get("device_type") or "-"
            lines.append(f"- **{name}** (ID: {d['id']})")
            lines.append(f"  Type: {device_type} | Code: `{d['device_code']}`")

    # Pagination footer
    if has_more:
        next_offset = offset + limit
        lines.append(f"\n---\n*More results available. Use offset={next_offset} for next page.*")

    return "\n".join(lines)
