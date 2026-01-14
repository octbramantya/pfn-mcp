"""Quantities tool - browse available measurement metrics."""

import logging

from pfn_mcp import db

logger = logging.getLogger(__name__)

# Semantic aliases for natural language queries
# Patterns are matched against quantity_code using ILIKE '%pattern%'
# More specific patterns listed first for priority matching
QUANTITY_ALIASES = {
    # Current - default to average across phases (ID: 3324)
    "current": ["100MS_CURRENT_AVG", "CURRENT_AVG", "CURRENT_PHASE"],
    "amp": ["100MS_CURRENT_AVG", "CURRENT_AVG", "CURRENT_PHASE"],
    "neutral current": ["CURRENT_N"],
    # Voltage - default to L-N average (ID: 3332)
    "voltage": ["VOLTAGE_L-N_AV", "VOLTAGE_L-N_AVG", "VOLTAGE_L-N"],
    "volt": ["VOLTAGE_L-N_AV", "VOLTAGE_L-N_AVG", "VOLTAGE_L-N"],
    "line voltage": ["VOLTAGE_L-L_AV", "VOLTAGE_L-L"],
    # Power factor - default to true PF total (ID: 1072)
    "power factor": ["TRUE_POWER_FAC", "POWER_FACTOR_TOTAL", "POWER_FACTOR"],
    "pf": ["TRUE_POWER_FAC", "POWER_FACTOR_TOTAL", "POWER_FACTOR"],
    "displacement power factor": ["DISPLACEMENT_POWER_F"],
    # Power - default to active power (ID: 185)
    "power": ["ACTIVE_POWER"],
    "kw": ["ACTIVE_POWER"],
    "reactive power": ["REACTIVE_POWER"],
    "kvar": ["REACTIVE_POWER"],
    "apparent power": ["APPARENT_POWER"],
    "kva": ["APPARENT_POWER"],
    # Energy - default to active energy delivered (ID: 124)
    "energy": ["ACTIVE_ENERGY_DELIVE"],
    "kwh": ["ACTIVE_ENERGY_DELIVE"],
    "consumption": ["ACTIVE_ENERGY_DELIVE"],
    "reactive energy": ["REACTIVE_ENERGY_DELI"],
    "apparent energy": ["APPARENT_ENERGY_DELI"],
    # Frequency (ID: 526)
    "frequency": ["FREQUENCY"],
    "hz": ["FREQUENCY"],
    # THD - default to voltage L-N (ID: 1119)
    "thd": ["THD_VOLTAGE_L-N", "THD_VOLTAGE", "THD"],
    "harmonic": ["THD_VOLTAGE_L-N", "THD_VOLTAGE", "THD"],
    "thd voltage": ["THD_VOLTAGE_L-N", "THD_VOLTAGE"],
    "thd current": ["THD_RMS_CURRENT"],
    # Unbalance - default to voltage L-N (ID: 1117)
    "unbalance": ["VOLTAGE_UNBALANCE_L-N", "UNBALANCE"],
    "voltage unbalance": ["VOLTAGE_UNBALANCE_L-N"],
    "current unbalance": ["CURRENT_UNBALANCE_WO", "CURRENT_UNBALANCE"],
    # Water
    "water": ["WATER"],
    "water flow": ["WATER_VOLUME_FLOW"],
    "water volume": ["WATER_VOLUME_SUPPLY", "WATER_VOLUME"],
    "water temperature": ["WATER_TEMPERATURE_SU", "WATER_TEMPERATURE"],
    # Air
    "air": ["AIR"],
    "air velocity": ["AIR_VELOCITY"],
    # Generic
    "temperature": ["TEMPERATURE"],
    "flow": ["FLOW", "VOLUME_FLOW"],
    "volume": ["VOLUME"],
}

# Category aliases - map user input to actual database values
CATEGORY_ALIASES = {
    "electrical": "Electricity",
    "electricity": "Electricity",
    "electric": "Electricity",
    "power": "Electricity",
    "water": "Water",
    "air": "Air",
    "gas": "Gas",
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

    # Category filter - normalize using aliases
    if category:
        normalized_category = CATEGORY_ALIASES.get(category.lower(), category)
        conditions.append(f"q.category ILIKE ${param_idx}")
        params.append(normalized_category)
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
