"""Group telemetry tools - Query aggregated data by device tags or asset groups."""

import logging
from datetime import datetime, timedelta
from typing import Literal

from pfn_mcp import db
from pfn_mcp.tools.electricity_cost import parse_period

logger = logging.getLogger(__name__)

# Active Energy Delivered quantity ID
ACTIVE_ENERGY_QTY_ID = 124


async def list_tags(
    tag_key: str | None = None,
    tag_category: str | None = None,
) -> dict:
    """
    List available device tags for grouping.

    Args:
        tag_key: Filter by specific tag key
        tag_category: Filter by tag category

    Returns:
        Dictionary with tags grouped by category
    """
    conditions = ["is_active = true"]
    params = []
    param_idx = 1

    if tag_key:
        conditions.append(f"tag_key ILIKE ${param_idx}")
        params.append(f"%{tag_key}%")
        param_idx += 1

    if tag_category:
        conditions.append(f"tag_category ILIKE ${param_idx}")
        params.append(f"%{tag_category}%")
        param_idx += 1

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            tag_category,
            tag_key,
            tag_value,
            COUNT(DISTINCT device_id) as device_count
        FROM device_tags
        WHERE {where_clause}
        GROUP BY tag_category, tag_key, tag_value
        ORDER BY tag_category NULLS LAST, tag_key, device_count DESC
    """

    rows = await db.fetch_all(query, *params)

    # Group by category
    by_category: dict[str, list[dict]] = {}
    for row in rows:
        category = row["tag_category"] or "uncategorized"
        if category not in by_category:
            by_category[category] = []
        by_category[category].append({
            "key": row["tag_key"],
            "value": row["tag_value"],
            "device_count": row["device_count"],
        })

    return {
        "categories": list(by_category.keys()),
        "tags_by_category": by_category,
        "total_tags": len(rows),
    }


def format_list_tags_response(result: dict) -> str:
    """Format list_tags response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    tags_by_category = result["tags_by_category"]
    total = result["total_tags"]

    if total == 0:
        return "No device tags found.\n\nUse device_tags table to create groupings."

    lines = [f"## Device Tags ({total} total)", ""]

    for category, tags in tags_by_category.items():
        lines.append(f"### {category.title()}")
        for tag in tags:
            lines.append(f"- **{tag['key']}**: {tag['value']} ({tag['device_count']} devices)")
        lines.append("")

    return "\n".join(lines)


async def list_tag_values(
    tag_key: str,
) -> dict:
    """
    List all values for a specific tag key with device counts.

    Args:
        tag_key: The tag key to list values for

    Returns:
        Dictionary with tag values and device counts
    """
    query = """
        SELECT
            tag_value,
            tag_category,
            COUNT(DISTINCT device_id) as device_count,
            array_agg(DISTINCT d.display_name ORDER BY d.display_name) as devices
        FROM device_tags dt
        JOIN devices d ON dt.device_id = d.id
        WHERE dt.tag_key ILIKE $1
          AND dt.is_active = true
        GROUP BY dt.tag_value, dt.tag_category
        ORDER BY device_count DESC
    """

    rows = await db.fetch_all(query, tag_key)

    if not rows:
        return {"error": f"No tags found with key: {tag_key}"}

    values = []
    for row in rows:
        devices = row["devices"] or []
        values.append({
            "value": row["tag_value"],
            "category": row["tag_category"],
            "device_count": row["device_count"],
            "devices": devices[:10],  # Limit to first 10
            "has_more_devices": len(devices) > 10,
        })

    return {
        "tag_key": tag_key,
        "values": values,
        "total_values": len(values),
    }


def format_list_tag_values_response(result: dict) -> str:
    """Format list_tag_values response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    tag_key = result["tag_key"]
    values = result["values"]
    total = result["total_values"]

    lines = [f"## Tag Values for '{tag_key}' ({total} values)", ""]

    for val in values:
        lines.append(f"### {val['value']} ({val['device_count']} devices)")
        if val["category"]:
            lines.append(f"Category: {val['category']}")

        # List devices
        for device in val["devices"]:
            lines.append(f"  - {device}")
        if val["has_more_devices"]:
            lines.append("  - ... and more")
        lines.append("")

    return "\n".join(lines)


GroupByType = Literal["tag", "asset"]


async def _resolve_tag_devices(
    tag_key: str, tag_value: str
) -> tuple[list[dict], str | None]:
    """Get device IDs and names for a tag key-value pair."""
    query = """
        SELECT DISTINCT dt.device_id, d.display_name
        FROM device_tags dt
        JOIN devices d ON dt.device_id = d.id
        WHERE dt.tag_key ILIKE $1
          AND dt.tag_value ILIKE $2
          AND dt.is_active = true
          AND d.is_active = true
        ORDER BY d.display_name
    """
    rows = await db.fetch_all(query, tag_key, tag_value)
    if not rows:
        return [], f"No devices found with tag {tag_key}={tag_value}"
    return [{"id": row["device_id"], "name": row["display_name"]} for row in rows], None


async def _resolve_asset_devices(asset_id: int) -> tuple[list[dict], str | None]:
    """Get device IDs and names for an asset hierarchy using database function."""
    # First check if the asset exists
    asset = await db.fetch_one(
        "SELECT id, asset_name FROM assets WHERE id = $1",
        asset_id,
    )
    if not asset:
        return [], f"Asset not found: {asset_id}"

    # Get all downstream devices using the database function
    query = """
        SELECT DISTINCT d.id as device_id, d.display_name
        FROM get_all_downstream_assets($1, 'ELECTRICITY') da
        JOIN devices d ON d.asset_id = da.asset_id
        WHERE d.is_active = true
    """
    rows = await db.fetch_all(query, asset_id)

    # Also include devices directly attached to this asset
    direct_query = """
        SELECT id as device_id, display_name
        FROM devices
        WHERE asset_id = $1 AND is_active = true
    """
    direct_rows = await db.fetch_all(direct_query, asset_id)

    # Combine and deduplicate by device_id
    device_map = {}
    for row in rows:
        device_map[row["device_id"]] = row["display_name"]
    for row in direct_rows:
        device_map[row["device_id"]] = row["display_name"]

    if not device_map:
        return [], f"No devices found under asset: {asset['asset_name']}"

    # Sort by name for consistent ordering
    devices = [
        {"id": did, "name": name}
        for did, name in sorted(device_map.items(), key=lambda x: x[1])
    ]

    return devices, None


async def get_group_telemetry(
    tag_key: str | None = None,
    tag_value: str | None = None,
    asset_id: int | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    breakdown: Literal["none", "device", "daily"] = "none",
) -> dict:
    """
    Get aggregated electricity consumption and cost for a group of devices.

    Group by tag (tag_key + tag_value) or asset hierarchy (asset_id).
    Uses daily_energy_cost_summary for pre-calculated consumption/cost.

    Args:
        tag_key: Tag key for grouping (e.g., "process", "building")
        tag_value: Tag value to match (e.g., "Waterjet", "Factory A")
        asset_id: Asset ID for hierarchy-based grouping
        period: Time period - "7d", "1M", "2025-12", etc.
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        breakdown: Breakdown type - "none", "device", "daily"

    Returns:
        Dictionary with group summary and optional breakdown
    """
    # Validate grouping parameters
    if tag_key and tag_value:
        devices, error = await _resolve_tag_devices(tag_key, tag_value)
        group_type = "tag"
        group_label = f"{tag_key}={tag_value}"
    elif asset_id:
        devices, error = await _resolve_asset_devices(asset_id)
        group_type = "asset"
        # Get asset name for label
        asset = await db.fetch_one(
            "SELECT asset_name FROM assets WHERE id = $1",
            asset_id,
        )
        group_label = asset["asset_name"] if asset else f"Asset {asset_id}"
    else:
        return {"error": "Either (tag_key + tag_value) or asset_id is required"}

    if error:
        return {"error": error}

    # Extract device IDs and names
    device_ids = [d["id"] for d in devices]
    device_names = [d["name"] for d in devices]

    # Determine result type based on device count
    device_count = len(devices)
    if device_count == 1:
        result_type = "single_meter"
    elif device_count <= 3:
        result_type = "combined_meters"
    else:
        result_type = "aggregated_group"

    # Parse period
    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result

    # Build device list for query
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    # Get summary totals
    summary_query = f"""
        SELECT
            COALESCE(SUM(total_consumption), 0) as total_consumption_kwh,
            COALESCE(SUM(total_cost), 0) as total_cost_rp,
            COUNT(DISTINCT daily_bucket) as days_with_data,
            COUNT(DISTINCT device_id) as devices_with_data
        FROM daily_energy_cost_summary
        WHERE quantity_id = $1
          AND daily_bucket >= $2
          AND daily_bucket < $3
          AND device_id IN ({device_placeholders})
    """

    summary = await db.fetch_one(
        summary_query,
        ACTIVE_ENERGY_QTY_ID,
        query_start,
        query_end,
        *device_ids,
    )

    total_consumption = float(summary["total_consumption_kwh"] or 0)
    total_cost = float(summary["total_cost_rp"] or 0)
    days_with_data = summary["days_with_data"] or 0
    devices_with_data = summary["devices_with_data"] or 0

    # Calculate average rate
    avg_rate = total_cost / total_consumption if total_consumption > 0 else 0

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    result_dict = {
        "group": {
            "type": group_type,
            "label": group_label,
            "result_type": result_type,
            "device_count": device_count,
            "devices_with_data": devices_with_data,
            "devices": device_names,
        },
        "summary": {
            "total_consumption_kwh": round(total_consumption, 2),
            "total_cost_rp": round(total_cost, 2),
            "avg_rate_per_kwh": round(avg_rate, 2),
            "period": f"{start_str} to {end_str}",
            "days_with_data": days_with_data,
        },
    }

    # Get breakdown if requested
    if breakdown == "device":
        breakdown_data = await _get_device_breakdown(
            device_ids, query_start, query_end, total_consumption
        )
        result_dict["breakdown"] = breakdown_data
    elif breakdown == "daily":
        breakdown_data = await _get_daily_breakdown(
            device_ids, query_start, query_end
        )
        result_dict["breakdown"] = breakdown_data

    return result_dict


async def _get_device_breakdown(
    device_ids: list[int],
    start_dt: datetime,
    end_dt: datetime,
    total_consumption: float,
) -> list[dict]:
    """Get per-device breakdown."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    query = f"""
        SELECT
            d.id as device_id,
            d.display_name as device,
            COALESCE(SUM(decs.total_consumption), 0) as consumption_kwh,
            COALESCE(SUM(decs.total_cost), 0) as cost_rp
        FROM devices d
        LEFT JOIN daily_energy_cost_summary decs ON d.id = decs.device_id
            AND decs.quantity_id = $1
            AND decs.daily_bucket >= $2
            AND decs.daily_bucket < $3
        WHERE d.id IN ({device_placeholders})
        GROUP BY d.id, d.display_name
        ORDER BY consumption_kwh DESC
    """

    rows = await db.fetch_all(
        query,
        ACTIVE_ENERGY_QTY_ID,
        start_dt,
        end_dt,
        *device_ids,
    )

    breakdown = []
    for row in rows:
        consumption = float(row.get("consumption_kwh", 0) or 0)
        cost = float(row.get("cost_rp", 0) or 0)
        pct = 100 * consumption / total_consumption if total_consumption > 0 else 0

        breakdown.append({
            "device": row.get("device"),
            "device_id": row.get("device_id"),
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
            "percentage": round(pct, 1),
        })

    return breakdown


async def _get_daily_breakdown(
    device_ids: list[int],
    start_dt: datetime,
    end_dt: datetime,
) -> list[dict]:
    """Get daily breakdown."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    query = f"""
        SELECT
            daily_bucket::date as date,
            COALESCE(SUM(total_consumption), 0) as consumption_kwh,
            COALESCE(SUM(total_cost), 0) as cost_rp,
            COUNT(DISTINCT device_id) as device_count
        FROM daily_energy_cost_summary
        WHERE quantity_id = $1
          AND daily_bucket >= $2
          AND daily_bucket < $3
          AND device_id IN ({device_placeholders})
        GROUP BY daily_bucket::date
        ORDER BY date
    """

    rows = await db.fetch_all(
        query,
        ACTIVE_ENERGY_QTY_ID,
        start_dt,
        end_dt,
        *device_ids,
    )

    breakdown = []
    for row in rows:
        consumption = float(row.get("consumption_kwh", 0) or 0)
        cost = float(row.get("cost_rp", 0) or 0)
        date_val = row.get("date")

        breakdown.append({
            "date": date_val.strftime("%Y-%m-%d") if date_val else None,
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
            "device_count": row.get("device_count", 0),
        })

    return breakdown


def format_group_telemetry_response(result: dict) -> str:
    """Format get_group_telemetry response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    group = result["group"]
    summary = result["summary"]
    result_type = group.get("result_type", "aggregated_group")
    devices = group.get("devices", [])

    # Format header based on result type
    if result_type == "single_meter":
        header = f"## {group['label']} (single meter: {devices[0]})"
    elif result_type == "combined_meters":
        device_list = " + ".join(devices)
        header = f"## {group['label']} (combined: {device_list})"
    else:
        header = f"## {group['label']} ({group['device_count']} devices)"

    lines = [
        header,
        f"**Period**: {summary['period']}",
        f"**Days with data**: {summary['days_with_data']}",
    ]

    # Only show device count details for aggregated groups
    if result_type == "aggregated_group":
        with_data = group['devices_with_data']
        total = group['device_count']
        lines.append(f"**Devices reporting**: {with_data} of {total}")

    lines.extend([
        "",
        "### Summary",
        f"- **Consumption**: {summary['total_consumption_kwh']:,.2f} kWh",
        f"- **Cost**: Rp {summary['total_cost_rp']:,.0f}",
        f"- **Avg Rate**: Rp {summary['avg_rate_per_kwh']:,.2f}/kWh",
    ])

    # Add breakdown if present
    breakdown = result.get("breakdown", [])
    if breakdown:
        lines.append("")
        lines.append("### Breakdown")
        lines.append("")

        # Detect breakdown type from first item
        first = breakdown[0]
        if "device" in first:
            # Device breakdown
            for item in breakdown:
                device = item.get("device", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                pct = item["percentage"]
                lines.append(f"- **{device}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")
        elif "date" in first:
            # Daily breakdown
            for item in breakdown:
                date = item.get("date", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                devices = item.get("device_count", 0)
                lines.append(f"- {date}: {kwh:,.2f} kWh, Rp {rp:,.0f} ({devices} devices)")

    return "\n".join(lines)


async def compare_groups(
    groups: list[dict],
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
) -> dict:
    """
    Compare electricity consumption across multiple groups.

    Args:
        groups: List of group definitions, each with either:
            - {"tag_key": "...", "tag_value": "..."} for tag-based groups
            - {"asset_id": 123} for asset-based groups
        period: Time period - "7d", "1M", "2025-12", etc.
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)

    Returns:
        Dictionary with comparison of groups
    """
    if not groups or len(groups) < 2:
        return {"error": "At least 2 groups required for comparison"}

    # Parse period
    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result

    # Collect data for each group
    group_results = []
    total_consumption = 0

    for group_def in groups:
        tag_key = group_def.get("tag_key")
        tag_value = group_def.get("tag_value")
        asset_id = group_def.get("asset_id")

        # Resolve devices
        if tag_key and tag_value:
            devices, error = await _resolve_tag_devices(tag_key, tag_value)
            group_label = f"{tag_key}={tag_value}"
        elif asset_id:
            devices, error = await _resolve_asset_devices(asset_id)
            asset = await db.fetch_one(
                "SELECT asset_name FROM assets WHERE id = $1",
                asset_id,
            )
            group_label = asset["asset_name"] if asset else f"Asset {asset_id}"
        else:
            continue  # Skip invalid group definitions

        if error or not devices:
            group_results.append({
                "label": group_label,
                "device_count": 0,
                "consumption_kwh": 0,
                "cost_rp": 0,
                "percentage": 0,
                "error": error,
            })
            continue

        # Extract device IDs from resolved devices
        device_ids = [d["id"] for d in devices]

        # Query consumption for this group
        device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))
        query = f"""
            SELECT
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary
            WHERE quantity_id = $1
              AND daily_bucket >= $2
              AND daily_bucket < $3
              AND device_id IN ({device_placeholders})
        """

        row = await db.fetch_one(
            query,
            ACTIVE_ENERGY_QTY_ID,
            query_start,
            query_end,
            *device_ids,
        )

        consumption = float(row["consumption_kwh"] or 0)
        cost = float(row["cost_rp"] or 0)
        total_consumption += consumption

        group_results.append({
            "label": group_label,
            "device_count": len(devices),
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
        })

    # Calculate percentages
    for group in group_results:
        if "error" not in group:
            pct = 100 * group["consumption_kwh"] / total_consumption if total_consumption > 0 else 0
            group["percentage"] = round(pct, 1)

    # Sort by consumption descending
    group_results.sort(key=lambda x: x.get("consumption_kwh", 0), reverse=True)

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    return {
        "period": f"{start_str} to {end_str}",
        "total_consumption_kwh": round(total_consumption, 2),
        "groups": group_results,
    }


def format_compare_groups_response(result: dict) -> str:
    """Format compare_groups response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    period = result["period"]
    total = result["total_consumption_kwh"]
    groups = result["groups"]

    lines = [
        "## Group Comparison",
        f"**Period**: {period}",
        f"**Total**: {total:,.2f} kWh",
        "",
        "### Groups",
        "",
    ]

    for i, group in enumerate(groups, 1):
        label = group["label"]
        kwh = group["consumption_kwh"]
        rp = group["cost_rp"]
        pct = group.get("percentage", 0)
        devices = group["device_count"]

        if "error" in group:
            lines.append(f"{i}. **{label}**: _{group['error']}_")
        else:
            lines.append(
                f"{i}. **{label}** ({devices} devices): "
                f"{kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}"
            )

    return "\n".join(lines)
