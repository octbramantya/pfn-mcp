"""Aggregations tool - list available meter aggregations (departments, facility totals)."""

import logging

from pfn_mcp import db
from pfn_mcp.tools.devices import resolve_tenant

logger = logging.getLogger(__name__)


async def list_aggregations(
    tenant: str,
    aggregation_type: str | None = None,
) -> dict:
    """
    List available meter aggregations for a tenant.

    Aggregations are named formulas for calculating facility/department totals.
    Example: "facility" = 94+11+27 (Main + Genset + Solar)

    Args:
        tenant: Tenant name or code (required)
        aggregation_type: Filter by type: facility, department, sub_panel, custom

    Returns:
        dict with tenant info and aggregations grouped by type
    """
    # Resolve tenant
    tenant_info = await resolve_tenant(tenant)
    if not tenant_info:
        return {"error": f"Tenant not found: {tenant}"}

    tenant_id = tenant_info["id"]
    tenant_name = tenant_info["tenant_name"]

    # Build query
    query = """
        SELECT
            id,
            name,
            aggregation_type,
            formula,
            description
        FROM meter_aggregations
        WHERE tenant_id = $1
          AND is_active = true
    """
    params = [tenant_id]

    if aggregation_type:
        query += " AND aggregation_type = $2"
        params.append(aggregation_type)

    query += " ORDER BY aggregation_type, name"

    rows = await db.fetch_all(query, *params)

    # Group by type
    by_type: dict[str, list[dict]] = {}
    for row in rows:
        agg_type = row["aggregation_type"]
        if agg_type not in by_type:
            by_type[agg_type] = []
        by_type[agg_type].append({
            "id": row["id"],
            "name": row["name"],
            "formula": row["formula"],
            "description": row["description"],
        })

    return {
        "tenant": tenant_name,
        "tenant_id": tenant_id,
        "aggregation_type_filter": aggregation_type,
        "total_count": len(rows),
        "by_type": by_type,
    }


def format_list_aggregations_response(result: dict) -> str:
    """Format list_aggregations result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    tenant = result["tenant"]
    total = result["total_count"]
    by_type = result["by_type"]
    filter_type = result.get("aggregation_type_filter")

    if total == 0:
        if filter_type:
            return f"No {filter_type} aggregations found for {tenant}."
        return f"No aggregations found for {tenant}."

    lines = []
    if filter_type:
        lines.append(f"**{tenant}** - {total} {filter_type} aggregation(s):\n")
    else:
        lines.append(f"**{tenant}** - {total} aggregation(s):\n")

    # Order types for consistent display
    type_order = ["facility", "department", "sub_panel", "custom"]
    sorted_types = sorted(by_type.keys(), key=lambda t: (
        type_order.index(t) if t in type_order else len(type_order),
        t
    ))

    for agg_type in sorted_types:
        aggregations = by_type[agg_type]
        lines.append(f"### {agg_type.title()} ({len(aggregations)})")
        for agg in aggregations:
            lines.append(f"- **{agg['name']}**: `{agg['formula']}`")
            if agg.get("description"):
                lines.append(f"  {agg['description']}")
        lines.append("")

    return "\n".join(lines)
