"""Tenants tool - list available tenants."""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)


async def list_tenants() -> list[dict]:
    """
    List all active tenants with device counts.

    Returns:
        List of tenant dictionaries with id, name, code, type, and device count
    """
    query = """
        SELECT
            t.id,
            t.tenant_code,
            t.tenant_name,
            t.tenant_type,
            t.description,
            COUNT(d.id) FILTER (WHERE d.is_active = true) as device_count
        FROM tenants t
        LEFT JOIN devices d ON d.tenant_id = t.id
        WHERE t.is_active = true
        GROUP BY t.id, t.tenant_code, t.tenant_name, t.tenant_type, t.description
        ORDER BY t.tenant_name
    """
    return await db.fetch_all(query)


def format_tenants_response(tenants: list[dict]) -> str:
    """Format tenants list for human-readable output."""
    if not tenants:
        return "No tenants found."

    lines = [f"Found {len(tenants)} tenant(s):\n"]

    for t in tenants:
        lines.append(f"- **{t['tenant_name']}** (ID: {t['id']})")
        lines.append(f"  Code: `{t['tenant_code']}` | Type: {t['tenant_type']}")
        lines.append(f"  Devices: {t['device_count']}")
        if t.get("description"):
            lines.append(f"  {t['description']}")
        lines.append("")

    return "\n".join(lines)
