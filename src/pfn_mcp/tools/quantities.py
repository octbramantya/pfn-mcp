"""Quantities tool - browse available measurement metrics."""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)

# Semantic aliases for natural language queries
QUANTITY_ALIASES = {
    "energy": ["ACTIVE_ENERGY", "APPARENT_ENERGY", "REACTIVE_ENERGY"],
    "power": ["ACTIVE_POWER", "APPARENT_POWER", "REACTIVE_POWER"],
    "voltage": ["VOLTAGE"],
    "current": ["CURRENT"],
    "power factor": ["POWER_FACTOR", "TRUE_POWER_FAC", "DISPLACEMENT_POWER_F"],
    "frequency": ["FREQUENCY"],
    "thd": ["THD"],
    "unbalance": ["UNBALANCE"],
    "water": ["WATER"],
    "air": ["AIR"],
    "temperature": ["TEMPERATURE"],
    "flow": ["FLOW"],
    "volume": ["VOLUME"],
}


async def list_quantities(
    category: str | None = None,
    search: str | None = None,
    in_use_only: bool = True,
) -> list[dict]:
    """
    List available measurement quantities.

    Args:
        category: Filter by WAGE category (WATER, AIR, GAS, ELECTRICAL)
        search: Search term for quantity name/code (supports semantic aliases)
        in_use_only: If True, only return quantities that exist in telemetry data

    Returns:
        List of quantity dictionaries with id, code, name, unit, category, etc.
    """
    # Build the query
    conditions = ["q.is_active = true"]
    params = []
    param_idx = 1

    # Filter to quantities in use (have telemetry data)
    if in_use_only:
        in_use_subquery = """
            q.id IN (SELECT DISTINCT quantity_id FROM telemetry_15min_agg)
        """
        conditions.append(in_use_subquery)

    # Category filter
    if category:
        conditions.append(f"UPPER(q.category) = ${param_idx}")
        params.append(category.upper())
        param_idx += 1

    # Search filter - check for semantic aliases first
    if search:
        search_upper = search.upper().strip()

        # Expand semantic aliases
        alias_patterns = []
        for alias, patterns in QUANTITY_ALIASES.items():
            if alias.upper() in search_upper or search_upper in alias.upper():
                alias_patterns.extend(patterns)

        if alias_patterns:
            # Use alias patterns for matching
            pattern_conditions = []
            for pattern in alias_patterns:
                pattern_conditions.append(f"q.quantity_code ILIKE ${param_idx}")
                params.append(f"%{pattern}%")
                param_idx += 1
            conditions.append(f"({' OR '.join(pattern_conditions)})")
        else:
            # Direct search on name and code
            conditions.append(
                f"(q.quantity_name ILIKE ${param_idx} OR q.quantity_code ILIKE ${param_idx})"
            )
            params.append(f"%{search}%")
            param_idx += 1

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            q.id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            q.category,
            q.aggregation_method,
            q.is_cumulative,
            q.description
        FROM quantities q
        WHERE {where_clause}
        ORDER BY q.category, q.quantity_name
    """

    rows = await db.fetch_all(query, *params)
    return rows


def format_quantities_response(quantities: list[dict]) -> str:
    """Format quantities list for human-readable output."""
    if not quantities:
        return "No quantities found matching the criteria."

    # Group by category
    by_category: dict[str, list[dict]] = {}
    for q in quantities:
        cat = q.get("category") or "Unknown"
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(q)

    lines = [f"Found {len(quantities)} quantities:\n"]

    for category in sorted(by_category.keys()):
        items = by_category[category]
        lines.append(f"\n## {category} ({len(items)} quantities)")
        lines.append("")

        for q in items:
            unit = q.get("unit") or "-"
            agg = q.get("aggregation_method") or "-"
            cumulative = "cumulative" if q.get("is_cumulative") else "instantaneous"
            lines.append(f"- **{q['quantity_name']}** (ID: {q['id']})")
            lines.append(f"  Code: `{q['quantity_code']}`")
            lines.append(f"  Unit: {unit} | Aggregation: {agg} | Type: {cumulative}")

    return "\n".join(lines)
