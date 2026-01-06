"""Group telemetry tools - Query aggregated data by device tags or asset groups."""

import logging
from datetime import datetime, timedelta
from typing import Literal

from pfn_mcp import db
from pfn_mcp.tools.electricity_cost import parse_period
from pfn_mcp.tools.telemetry import _resolve_quantity_id

logger = logging.getLogger(__name__)

# Active Energy Delivered quantity ID
ACTIVE_ENERGY_QTY_ID = 124

# Aggregation methods for different quantity types
# "SUM" for cumulative quantities (energy), "AVG" for instantaneous (power, voltage)
CUMULATIVE_METHODS = {"sum", "total", "cumulative"}
INSTANTANEOUS_METHODS = {"avg", "average", "mean", "instantaneous"}


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
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    breakdown: Literal["none", "device", "daily"] = "none",
) -> dict:
    """
    Get aggregated telemetry for a group of devices.

    Group by tag (tag_key + tag_value) or asset hierarchy (asset_id).
    Default: electricity consumption/cost from daily_energy_cost_summary.
    With quantity specified: any WAGE metric from telemetry_15min_agg.

    Args:
        tag_key: Tag key for grouping (e.g., "process", "building")
        tag_value: Tag value to match (e.g., "Waterjet", "Factory A")
        asset_id: Asset ID for hierarchy-based grouping
        quantity_id: Quantity ID for non-electricity metrics
        quantity_search: Quantity search term (e.g., "power", "water flow")
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

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    # Determine if using custom quantity or default electricity
    use_custom_quantity = quantity_id is not None or quantity_search is not None

    if use_custom_quantity:
        # Resolve quantity for WAGE telemetry
        resolved_qty_id, qty_info, error = await _resolve_quantity_id(
            quantity_id, quantity_search
        )
        if error:
            return {"error": error}

        return await _get_telemetry_group_summary(
            device_ids=device_ids,
            device_names=device_names,
            device_count=device_count,
            result_type=result_type,
            group_type=group_type,
            group_label=group_label,
            quantity_id=resolved_qty_id,
            quantity_info=qty_info,
            query_start=query_start,
            query_end=query_end,
            start_str=start_str,
            end_str=end_str,
            breakdown=breakdown,
        )
    else:
        # Default: electricity consumption/cost
        return await _get_electricity_group_summary(
            device_ids=device_ids,
            device_names=device_names,
            device_count=device_count,
            result_type=result_type,
            group_type=group_type,
            group_label=group_label,
            query_start=query_start,
            query_end=query_end,
            start_str=start_str,
            end_str=end_str,
            breakdown=breakdown,
        )


async def _get_electricity_group_summary(
    device_ids: list[int],
    device_names: list[str],
    device_count: int,
    result_type: str,
    group_type: str,
    group_label: str,
    query_start: datetime,
    query_end: datetime,
    start_str: str,
    end_str: str,
    breakdown: str,
) -> dict:
    """Get electricity consumption/cost summary from daily_energy_cost_summary."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

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

    avg_rate = total_cost / total_consumption if total_consumption > 0 else 0

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


async def _get_telemetry_group_summary(
    device_ids: list[int],
    device_names: list[str],
    device_count: int,
    result_type: str,
    group_type: str,
    group_label: str,
    quantity_id: int,
    quantity_info: dict,
    query_start: datetime,
    query_end: datetime,
    start_str: str,
    end_str: str,
    breakdown: str,
) -> dict:
    """Get WAGE telemetry summary from telemetry_15min_agg."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    # Determine aggregation method from quantity info
    agg_method = (quantity_info.get("aggregation_method") or "avg").lower()
    is_cumulative = agg_method in CUMULATIVE_METHODS

    # For cumulative quantities (energy), sum the values
    # For instantaneous quantities (power, voltage), average the values
    # Note: telemetry_15min_agg has aggregated_value column (no separate sum/avg/min/max)
    if is_cumulative:
        agg_func = "SUM(aggregated_value)"
        agg_label = "total"
    else:
        agg_func = "AVG(aggregated_value)"
        agg_label = "average"

    summary_query = f"""
        SELECT
            {agg_func} as agg_value,
            MIN(aggregated_value) as min_value,
            MAX(aggregated_value) as max_value,
            COUNT(DISTINCT bucket::date) as days_with_data,
            COUNT(DISTINCT device_id) as devices_with_data,
            COUNT(*) as data_points
        FROM telemetry_15min_agg
        WHERE quantity_id = $1
          AND bucket >= $2
          AND bucket < $3
          AND device_id IN ({device_placeholders})
    """

    summary = await db.fetch_one(
        summary_query,
        quantity_id,
        query_start,
        query_end,
        *device_ids,
    )

    agg_value = float(summary["agg_value"] or 0)
    min_value = float(summary["min_value"]) if summary["min_value"] else None
    max_value = float(summary["max_value"]) if summary["max_value"] else None
    days_with_data = summary["days_with_data"] or 0
    devices_with_data = summary["devices_with_data"] or 0
    data_points = summary["data_points"] or 0

    unit = quantity_info.get("unit") or ""

    result_dict = {
        "group": {
            "type": group_type,
            "label": group_label,
            "result_type": result_type,
            "device_count": device_count,
            "devices_with_data": devices_with_data,
            "devices": device_names,
        },
        "quantity": {
            "id": quantity_id,
            "name": quantity_info["quantity_name"],
            "unit": unit,
            "aggregation": agg_label,
        },
        "summary": {
            f"{agg_label}_value": round(agg_value, 2),
            "min_value": round(min_value, 2) if min_value else None,
            "max_value": round(max_value, 2) if max_value else None,
            "unit": unit,
            "period": f"{start_str} to {end_str}",
            "days_with_data": days_with_data,
            "data_points": data_points,
        },
    }

    if breakdown == "device":
        breakdown_data = await _get_telemetry_device_breakdown(
            device_ids, quantity_id, query_start, query_end, agg_value, is_cumulative
        )
        result_dict["breakdown"] = breakdown_data
    elif breakdown == "daily":
        breakdown_data = await _get_telemetry_daily_breakdown(
            device_ids, quantity_id, query_start, query_end, is_cumulative
        )
        result_dict["breakdown"] = breakdown_data

    return result_dict


async def _get_telemetry_device_breakdown(
    device_ids: list[int],
    quantity_id: int,
    start_dt: datetime,
    end_dt: datetime,
    total_value: float,
    is_cumulative: bool,
) -> list[dict]:
    """Get per-device breakdown for telemetry data."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    if is_cumulative:
        agg_func = "SUM(aggregated_value)"
    else:
        agg_func = "AVG(aggregated_value)"

    query = f"""
        SELECT
            d.id as device_id,
            d.display_name as device,
            {agg_func} as agg_value,
            MIN(t.aggregated_value) as min_value,
            MAX(t.aggregated_value) as max_value
        FROM devices d
        LEFT JOIN telemetry_15min_agg t ON d.id = t.device_id
            AND t.quantity_id = $1
            AND t.bucket >= $2
            AND t.bucket < $3
        WHERE d.id IN ({device_placeholders})
        GROUP BY d.id, d.display_name
        ORDER BY agg_value DESC NULLS LAST
    """

    rows = await db.fetch_all(
        query,
        quantity_id,
        start_dt,
        end_dt,
        *device_ids,
    )

    breakdown = []
    for row in rows:
        agg_value = float(row.get("agg_value", 0) or 0)
        min_val = float(row.get("min_value", 0) or 0) if row.get("min_value") else None
        max_val = float(row.get("max_value", 0) or 0) if row.get("max_value") else None
        pct = 100 * agg_value / total_value if total_value > 0 else 0

        breakdown.append({
            "device": row.get("device"),
            "device_id": row.get("device_id"),
            "value": round(agg_value, 2),
            "min": round(min_val, 2) if min_val else None,
            "max": round(max_val, 2) if max_val else None,
            "percentage": round(pct, 1),
        })

    return breakdown


async def _get_telemetry_daily_breakdown(
    device_ids: list[int],
    quantity_id: int,
    start_dt: datetime,
    end_dt: datetime,
    is_cumulative: bool,
) -> list[dict]:
    """Get daily breakdown for telemetry data."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    if is_cumulative:
        agg_func = "SUM(aggregated_value)"
    else:
        agg_func = "AVG(aggregated_value)"

    query = f"""
        SELECT
            bucket::date as date,
            {agg_func} as agg_value,
            MIN(aggregated_value) as min_value,
            MAX(aggregated_value) as max_value,
            COUNT(DISTINCT device_id) as device_count
        FROM telemetry_15min_agg
        WHERE quantity_id = $1
          AND bucket >= $2
          AND bucket < $3
          AND device_id IN ({device_placeholders})
        GROUP BY bucket::date
        ORDER BY date
    """

    rows = await db.fetch_all(
        query,
        quantity_id,
        start_dt,
        end_dt,
        *device_ids,
    )

    breakdown = []
    for row in rows:
        agg_value = float(row.get("agg_value", 0) or 0)
        min_val = float(row.get("min_value", 0) or 0) if row.get("min_value") else None
        max_val = float(row.get("max_value", 0) or 0) if row.get("max_value") else None
        date_val = row.get("date")

        breakdown.append({
            "date": date_val.strftime("%Y-%m-%d") if date_val else None,
            "value": round(agg_value, 2),
            "min": round(min_val, 2) if min_val else None,
            "max": round(max_val, 2) if max_val else None,
            "device_count": row.get("device_count", 0),
        })

    return breakdown


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

    # Check if this is WAGE telemetry (has quantity info)
    is_wage = "quantity" in result

    # Format header based on result type
    if result_type == "single_meter":
        header = f"## {group['label']} (single meter: {devices[0]})"
    elif result_type == "combined_meters":
        device_list = " + ".join(devices)
        header = f"## {group['label']} (combined: {device_list})"
    else:
        header = f"## {group['label']} ({group['device_count']} devices)"

    lines = [header]

    # Add quantity info for WAGE telemetry
    if is_wage:
        qty = result["quantity"]
        lines.append(f"**Quantity**: {qty['name']} ({qty['unit']})")

    lines.extend([
        f"**Period**: {summary['period']}",
        f"**Days with data**: {summary['days_with_data']}",
    ])

    # Only show device count details for aggregated groups
    if result_type == "aggregated_group":
        with_data = group['devices_with_data']
        total = group['device_count']
        lines.append(f"**Devices reporting**: {with_data} of {total}")

    lines.extend(["", "### Summary"])

    if is_wage:
        # WAGE telemetry summary
        qty = result["quantity"]
        unit = qty.get("unit", "")
        agg = qty.get("aggregation", "value")

        # Get the aggregated value key (total_value or average_value)
        agg_key = f"{agg}_value"
        agg_value = summary.get(agg_key, 0)

        lines.append(f"- **{agg.title()}**: {agg_value:,.2f} {unit}")
        if summary.get("min_value") is not None:
            lines.append(f"- **Min**: {summary['min_value']:,.2f} {unit}")
        if summary.get("max_value") is not None:
            lines.append(f"- **Max**: {summary['max_value']:,.2f} {unit}")
        if summary.get("data_points"):
            lines.append(f"- **Data points**: {summary['data_points']:,}")
    else:
        # Electricity summary
        lines.extend([
            f"- **Consumption**: {summary['total_consumption_kwh']:,.2f} kWh",
            f"- **Cost**: Rp {summary['total_cost_rp']:,.0f}",
            f"- **Avg Rate**: Rp {summary['avg_rate_per_kwh']:,.2f}/kWh",
        ])

    # Add breakdown if present
    breakdown = result.get("breakdown", [])
    if breakdown:
        lines.extend(["", "### Breakdown", ""])

        # Detect breakdown type from first item
        first = breakdown[0]

        if is_wage:
            # WAGE telemetry breakdown
            qty = result["quantity"]
            unit = qty.get("unit", "")

            if "device" in first:
                for item in breakdown:
                    device = item.get("device", "?")
                    value = item["value"]
                    pct = item["percentage"]
                    lines.append(f"- **{device}**: {value:,.2f} {unit} ({pct}%)")
            elif "date" in first:
                for item in breakdown:
                    date = item.get("date", "?")
                    value = item["value"]
                    dev_count = item.get("device_count", 0)
                    lines.append(f"- {date}: {value:,.2f} {unit} ({dev_count} devices)")
        else:
            # Electricity breakdown
            if "device" in first:
                for item in breakdown:
                    device = item.get("device", "?")
                    kwh = item["consumption_kwh"]
                    rp = item["cost_rp"]
                    pct = item["percentage"]
                    lines.append(f"- **{device}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")
            elif "date" in first:
                for item in breakdown:
                    date = item.get("date", "?")
                    kwh = item["consumption_kwh"]
                    rp = item["cost_rp"]
                    dev_count = item.get("device_count", 0)
                    lines.append(f"- {date}: {kwh:,.2f} kWh, Rp {rp:,.0f} ({dev_count} devices)")

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
