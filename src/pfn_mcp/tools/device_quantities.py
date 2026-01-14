"""Device quantities tools - correlate devices with available measurements."""

import logging

from pfn_mcp import db
from pfn_mcp.tools.quantities import QUANTITY_ALIASES

logger = logging.getLogger(__name__)


async def list_device_quantities(
    device_id: int | None = None,
    device_name: str | None = None,
    search: str | None = None,
) -> dict:
    """
    List quantities available for a specific device.

    Args:
        device_id: Device ID to query
        device_name: Device name (fuzzy search if device_id not provided)
        search: Optional filter for quantity type (uses semantic aliases)

    Returns:
        Dictionary with device info and list of available quantities
    """
    # First, resolve the device
    if device_id is None and device_name is None:
        return {"error": "Either device_id or device_name is required"}

    if device_id is None:
        # Find device by name
        device_query = """
            SELECT id, display_name, device_code, tenant_id
            FROM devices
            WHERE is_active = true
              AND LOWER(display_name) LIKE LOWER($1)
            ORDER BY
                CASE
                    WHEN LOWER(display_name) = LOWER($2) THEN 0
                    WHEN LOWER(display_name) LIKE LOWER($2) || '%' THEN 1
                    ELSE 2
                END
            LIMIT 1
        """
        device = await db.fetch_one(device_query, f"%{device_name}%", device_name)
        if not device:
            return {"error": f"Device not found: {device_name}"}
        device_id = device["id"]
    else:
        device = await db.fetch_one(
            "SELECT id, display_name, device_code, tenant_id FROM devices WHERE id = $1",
            device_id,
        )
        if not device:
            return {"error": f"Device ID not found: {device_id}"}

    # Build quantity filter
    quantity_conditions = ["1=1"]
    params = [device_id]
    param_idx = 2

    if search:
        search_upper = search.upper().strip()
        alias_patterns = []
        for alias, patterns in QUANTITY_ALIASES.items():
            if alias.upper() in search_upper or search_upper in alias.upper():
                alias_patterns.extend(patterns)

        if alias_patterns:
            pattern_conditions = []
            for pattern in alias_patterns:
                pattern_conditions.append(f"q.quantity_code ILIKE ${param_idx}")
                params.append(f"%{pattern}%")
                param_idx += 1
            quantity_conditions.append(f"({' OR '.join(pattern_conditions)})")
        else:
            quantity_conditions.append(
                f"(q.quantity_name ILIKE ${param_idx} OR q.quantity_code ILIKE ${param_idx})"
            )
            params.append(f"%{search}%")

    where_clause = " AND ".join(quantity_conditions)

    # Query available quantities for this device
    query = f"""
        SELECT DISTINCT
            q.id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            q.category,
            q.aggregation_method
        FROM telemetry_15min_agg t
        JOIN quantities q ON t.quantity_id = q.id
        WHERE t.device_id = $1
          AND {where_clause}
        ORDER BY q.category, q.quantity_name
    """

    quantities = await db.fetch_all(query, *params)

    return {
        "device": {
            "id": device["id"],
            "name": device["display_name"],
            "code": device["device_code"],
        },
        "quantities": quantities,
        "count": len(quantities),
    }


async def compare_device_quantities(
    device_ids: list[int] | None = None,
    device_names: list[str] | None = None,
    search: str | None = None,
) -> dict:
    """
    Compare quantities available across multiple devices.

    Args:
        device_ids: List of device IDs to compare
        device_names: List of device names (fuzzy search)
        search: Optional filter for quantity type (uses semantic aliases)

    Returns:
        Dictionary with devices info, shared quantities, and per-device quantities
    """
    resolved_devices = []

    # Resolve device IDs
    if device_ids:
        for did in device_ids:
            device = await db.fetch_one(
                "SELECT id, display_name, device_code FROM devices WHERE id = $1",
                did,
            )
            if device:
                resolved_devices.append(device)

    if device_names:
        for name in device_names:
            device_query = """
                SELECT id, display_name, device_code
                FROM devices
                WHERE is_active = true
                  AND LOWER(display_name) LIKE LOWER($1)
                ORDER BY
                    CASE
                        WHEN LOWER(display_name) = LOWER($2) THEN 0
                        WHEN LOWER(display_name) LIKE LOWER($2) || '%' THEN 1
                        ELSE 2
                    END
                LIMIT 1
            """
            device = await db.fetch_one(device_query, f"%{name}%", name)
            if device:
                # Avoid duplicates
                if not any(d["id"] == device["id"] for d in resolved_devices):
                    resolved_devices.append(device)

    if len(resolved_devices) < 2:
        return {"error": "At least 2 devices are required for comparison"}

    device_ids_resolved = [d["id"] for d in resolved_devices]

    # Build quantity filter
    quantity_conditions = ["1=1"]
    base_params = []
    param_offset = len(device_ids_resolved) + 1

    if search:
        search_upper = search.upper().strip()
        alias_patterns = []
        for alias, patterns in QUANTITY_ALIASES.items():
            if alias.upper() in search_upper or search_upper in alias.upper():
                alias_patterns.extend(patterns)

        if alias_patterns:
            pattern_conditions = []
            for pattern in alias_patterns:
                pattern_conditions.append(f"q.quantity_code ILIKE ${param_offset}")
                base_params.append(f"%{pattern}%")
                param_offset += 1
            quantity_conditions.append(f"({' OR '.join(pattern_conditions)})")
        else:
            quantity_conditions.append(
                f"(q.quantity_name ILIKE ${param_offset} OR q.quantity_code ILIKE ${param_offset})"
            )
            base_params.append(f"%{search}%")

    where_clause = " AND ".join(quantity_conditions)

    # Build device ID placeholders
    device_placeholders = ", ".join(f"${i+1}" for i in range(len(device_ids_resolved)))

    # Query quantities shared by ALL devices
    shared_query = f"""
        SELECT
            q.id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            q.category
        FROM quantities q
        WHERE q.id IN (
            SELECT quantity_id
            FROM telemetry_15min_agg
            WHERE device_id IN ({device_placeholders})
            GROUP BY quantity_id
            HAVING COUNT(DISTINCT device_id) = {len(device_ids_resolved)}
        )
        AND {where_clause}
        ORDER BY q.category, q.quantity_name
    """

    shared_quantities = await db.fetch_all(
        shared_query, *device_ids_resolved, *base_params
    )

    # Query per-device quantities
    per_device = {}
    # Adjust where clause for per-device query (params start at $2)
    if base_params:
        per_device_where = where_clause
        for i in range(len(base_params)):
            per_device_where = per_device_where.replace(
                f"${param_offset - len(base_params) + i}", f"${i + 2}"
            )
    else:
        per_device_where = where_clause

    for device in resolved_devices:
        device_query = f"""
            SELECT DISTINCT
                q.id,
                q.quantity_code,
                q.quantity_name,
                q.category
            FROM telemetry_15min_agg t
            JOIN quantities q ON t.quantity_id = q.id
            WHERE t.device_id = $1
              AND {per_device_where}
            ORDER BY q.category, q.quantity_name
        """
        if base_params:
            quantities = await db.fetch_all(device_query, device["id"], *base_params)
        else:
            quantities = await db.fetch_all(device_query, device["id"])
        per_device[device["display_name"]] = {
            "device_id": device["id"],
            "quantities": quantities,
            "count": len(quantities),
        }

    return {
        "devices": [
            {"id": d["id"], "name": d["display_name"], "code": d["device_code"]}
            for d in resolved_devices
        ],
        "shared_quantities": shared_quantities,
        "shared_count": len(shared_quantities),
        "per_device": per_device,
    }


def format_device_quantities_response(result: dict) -> str:
    """Format device quantities result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    quantities = result["quantities"]

    lines = [
        f"# Quantities for {device['name']}",
        f"Device ID: {device['id']} | Code: {device['code']}",
        f"Total quantities: {result['count']}",
        "",
    ]

    # Group by category
    by_category: dict[str, list] = {}
    for q in quantities:
        cat = q.get("category") or "Unknown"
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(q)

    for category in sorted(by_category.keys()):
        items = by_category[category]
        lines.append(f"## {category} ({len(items)})")
        for q in items:
            unit = q.get("unit") or "-"
            lines.append(f"- {q['quantity_name']} (ID: {q['id']}) [{unit}]")
        lines.append("")

    return "\n".join(lines)


def format_compare_quantities_response(result: dict) -> str:
    """Format compare quantities result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    devices = result["devices"]
    shared = result["shared_quantities"]

    lines = [
        "# Device Quantities Comparison",
        "",
        "## Devices Compared",
    ]
    for d in devices:
        lines.append(f"- {d['name']} (ID: {d['id']})")

    lines.extend([
        "",
        f"## Shared Quantities ({result['shared_count']})",
        "Quantities available on ALL devices:",
        "",
    ])

    if shared:
        by_category: dict[str, list] = {}
        for q in shared:
            cat = q.get("category") or "Unknown"
            if cat not in by_category:
                by_category[cat] = []
            by_category[cat].append(q)

        for category in sorted(by_category.keys()):
            items = by_category[category]
            lines.append(f"### {category} ({len(items)})")
            for q in items:
                lines.append(f"- {q['quantity_name']} (ID: {q['id']})")
            lines.append("")
    else:
        lines.append("No shared quantities found.")
        lines.append("")

    lines.append("## Per-Device Summary")
    for name, data in result["per_device"].items():
        lines.append(f"- **{name}**: {data['count']} quantities")

    return "\n".join(lines)
