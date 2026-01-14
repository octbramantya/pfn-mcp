"""Peak analysis tools - Find peak values with timestamps."""

import logging
from datetime import datetime, timedelta
from typing import Literal

from pfn_mcp import db
from pfn_mcp.tools.datetime_utils import format_display_datetime
from pfn_mcp.tools.electricity_cost import parse_period
from pfn_mcp.tools.group_telemetry import _resolve_asset_devices, _resolve_tag_devices
from pfn_mcp.tools.resolve import resolve_tenant
from pfn_mcp.tools.telemetry import _resolve_device_id, _resolve_quantity_id

logger = logging.getLogger(__name__)

# Bucket intervals for time_bucket (as timedelta for asyncpg compatibility)
BUCKET_INTERVALS = {
    "1hour": timedelta(hours=1),
    "1day": timedelta(days=1),
    "1week": timedelta(weeks=1),
}

# Human-readable bucket interval labels for display
BUCKET_LABELS = {
    "1hour": "1 hour",
    "1day": "1 day",
    "1week": "1 week",
}

BucketType = Literal["1hour", "1day", "1week"]


def _select_bucket(time_range: timedelta) -> BucketType:
    """Select bucket size based on time range."""
    days = time_range.total_seconds() / 86400

    if days <= 3:
        return "1hour"
    elif days <= 30:
        return "1day"
    else:
        return "1week"


async def get_peak_analysis(
    tenant: str | None = None,
    device_id: int | None = None,
    device_name: str | None = None,
    tag_key: str | None = None,
    tag_value: str | None = None,
    asset_id: int | None = None,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    bucket: BucketType | None = None,
    top_n: int = 10,
    breakdown: Literal["none", "device_daily"] = "none",
) -> dict:
    """
    Find peak values with timestamps for a device or group.

    Supports single device or group (tag/asset). Returns peak values
    per bucket (hour/day/week) with timestamps.
    Auto-filters to devices in the user's tenant.

    Args:
        tenant: Tenant name or code to filter devices (optional)
        device_id: Single device ID
        device_name: Single device name (fuzzy search)
        tag_key: Tag key for group (e.g., "process", "building")
        tag_value: Tag value for group (e.g., "Waterjet")
        asset_id: Asset ID for hierarchy-based grouping
        quantity_id: Quantity ID (e.g., 185 for Active Power)
        quantity_search: Quantity search term (e.g., "power", "flow")
        period: Time period - "7d", "30d", "1M", "2025-12"
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        bucket: Bucket size - "1hour", "1day", "1week" (auto if None)
        top_n: Number of top peaks to return (default: 10)
        breakdown: "none" or "device_daily" for per-device peaks

    Returns:
        Dictionary with peaks, timestamps, and optional breakdown
    """
    # Resolve tenant first (if provided)
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Determine mode: single device or group
    is_single_device = device_id is not None or device_name is not None
    is_group = (tag_key and tag_value) or asset_id is not None

    if not is_single_device and not is_group:
        return {
            "error": "Either device (device_id/device_name) or group "
            "(tag_key+tag_value or asset_id) is required"
        }

    if is_single_device and is_group:
        return {"error": "Cannot specify both device and group parameters"}

    # Resolve quantity
    resolved_qty_id, qty_info, error = await _resolve_quantity_id(
        quantity_id, quantity_search
    )
    if error:
        return {"error": error}

    # Parse period
    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result
    time_range = query_end - query_start

    # Select bucket if not specified
    selected_bucket = bucket or _select_bucket(time_range)
    bucket_interval = BUCKET_INTERVALS[selected_bucket]

    # Resolve devices with tenant filter
    if is_single_device:
        resolved_dev_id, dev_info, error = await _resolve_device_id(
            device_id, device_name, tenant_id
        )
        if error:
            return {"error": error}
        device_ids = [resolved_dev_id]
        device_map = {resolved_dev_id: dev_info.get("display_name", str(resolved_dev_id))}
        group_label = dev_info.get("display_name", f"Device {resolved_dev_id}")
        group_type = "device"
    else:
        # Resolve group devices with tenant filter
        if tag_key and tag_value:
            devices, error = await _resolve_tag_devices(tag_key, tag_value, tenant_id)
            group_label = f"{tag_key}={tag_value}"
            group_type = "tag"
        else:
            devices, error = await _resolve_asset_devices(asset_id, tenant_id)
            asset = await db.fetch_one(
                "SELECT asset_name FROM assets WHERE id = $1",
                asset_id,
            )
            group_label = asset["asset_name"] if asset else f"Asset {asset_id}"
            group_type = "asset"

        if error:
            return {"error": error}

        device_ids = [d["id"] for d in devices]
        device_map = {d["id"]: d["name"] for d in devices}

    # Query for peaks
    device_placeholders = ", ".join(f"${i+5}" for i in range(len(device_ids)))

    # Query using CTE to find peaks per bucket and which device caused them
    # Note: telemetry_15min_agg has aggregated_value column (no separate max_value)
    simple_peak_query = f"""
        WITH bucketed AS (
            SELECT
                time_bucket($1::interval, bucket) as time_bucket,
                device_id,
                MAX(aggregated_value) as device_max
            FROM telemetry_15min_agg
            WHERE quantity_id = $2
              AND bucket >= $3
              AND bucket < $4
              AND device_id IN ({device_placeholders})
            GROUP BY time_bucket($1::interval, bucket), device_id
        ),
        bucket_peaks AS (
            SELECT
                time_bucket,
                MAX(device_max) as peak_value
            FROM bucketed
            GROUP BY time_bucket
        )
        SELECT
            bp.time_bucket,
            bp.peak_value,
            b.device_id as peak_device_id
        FROM bucket_peaks bp
        LEFT JOIN LATERAL (
            SELECT device_id
            FROM bucketed
            WHERE bucketed.time_bucket = bp.time_bucket
              AND bucketed.device_max = bp.peak_value
            LIMIT 1
        ) b ON true
        ORDER BY bp.peak_value DESC NULLS LAST
        LIMIT ${len(device_ids) + 5}
    """

    rows = await db.fetch_all(
        simple_peak_query,
        bucket_interval,
        resolved_qty_id,
        query_start,
        query_end,
        *device_ids,
        top_n,
    )

    peaks = []
    for row in rows:
        peak_device_id = row.get("peak_device_id")
        peaks.append({
            "time": row["time_bucket"].isoformat() if row["time_bucket"] else None,
            "value": round(row["peak_value"], 2) if row["peak_value"] else None,
            "device_id": peak_device_id,
            "device_name": device_map.get(peak_device_id, f"Device {peak_device_id}"),
        })

    # Get overall stats (different placeholder positions - starts at $4)
    stats_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))
    stats_query = f"""
        SELECT
            MAX(aggregated_value) as overall_peak,
            AVG(aggregated_value) as overall_avg,
            COUNT(DISTINCT bucket) as data_points
        FROM telemetry_15min_agg
        WHERE quantity_id = $1
          AND bucket >= $2
          AND bucket < $3
          AND device_id IN ({stats_placeholders})
    """

    stats = await db.fetch_one(
        stats_query,
        resolved_qty_id,
        query_start,
        query_end,
        *device_ids,
    )

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    result_dict = {
        "group": {
            "type": group_type,
            "label": group_label,
            "device_count": len(device_ids),
        },
        "quantity": {
            "id": qty_info["id"],
            "name": qty_info["quantity_name"],
            "unit": qty_info.get("unit"),
        },
        "period": {
            "start": start_str,
            "end": end_str,
            "bucket": selected_bucket,
        },
        "stats": {
            "overall_peak": round(stats["overall_peak"], 2) if stats["overall_peak"] else None,
            "overall_avg": round(stats["overall_avg"], 2) if stats["overall_avg"] else None,
            "data_points": stats["data_points"] or 0,
        },
        "peaks": peaks,
        "peak_count": len(peaks),
    }

    # Add device breakdown if requested and is a group
    if breakdown == "device_daily" and is_group and len(device_ids) > 1:
        breakdown_data = await _get_device_daily_breakdown(
            device_ids, device_map, resolved_qty_id, query_start, query_end
        )
        result_dict["breakdown"] = breakdown_data

    return result_dict


async def _get_device_daily_breakdown(
    device_ids: list[int],
    device_map: dict[int, str],
    quantity_id: int,
    start_dt: datetime,
    end_dt: datetime,
) -> list[dict]:
    """Get per-device daily peak breakdown."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    query = f"""
        SELECT
            device_id,
            bucket::date as date,
            MAX(aggregated_value) as daily_peak,
            AVG(aggregated_value) as daily_avg
        FROM telemetry_15min_agg
        WHERE quantity_id = $1
          AND bucket >= $2
          AND bucket < $3
          AND device_id IN ({device_placeholders})
        GROUP BY device_id, bucket::date
        ORDER BY device_id, date
    """

    rows = await db.fetch_all(
        query,
        quantity_id,
        start_dt,
        end_dt,
        *device_ids,
    )

    # Group by device
    by_device: dict[int, list[dict]] = {}
    for row in rows:
        dev_id = row["device_id"]
        if dev_id not in by_device:
            by_device[dev_id] = []
        by_device[dev_id].append({
            "date": row["date"].strftime("%Y-%m-%d") if row["date"] else None,
            "peak": round(row["daily_peak"], 2) if row["daily_peak"] else None,
            "avg": round(row["daily_avg"], 2) if row["daily_avg"] else None,
        })

    breakdown = []
    for dev_id, daily_data in by_device.items():
        # Find max peak for this device
        max_peak = max((d["peak"] or 0) for d in daily_data)
        breakdown.append({
            "device_id": dev_id,
            "device_name": device_map.get(dev_id, f"Device {dev_id}"),
            "max_peak": max_peak,
            "daily_data": daily_data,
        })

    # Sort by max peak descending
    breakdown.sort(key=lambda x: x.get("max_peak", 0) or 0, reverse=True)
    return breakdown


def format_peak_analysis_response(result: dict) -> str:
    """Format get_peak_analysis response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    group = result["group"]
    quantity = result["quantity"]
    period = result["period"]
    stats = result["stats"]
    peaks = result["peaks"]
    peak_count = result["peak_count"]

    unit = quantity.get("unit") or ""

    # Format period timestamps in display timezone (WIB)
    start_str = format_display_datetime(period["start"]) or period["start"][:16]
    end_str = format_display_datetime(period["end"]) or period["end"][:16]

    lines = [
        f"## Peak Analysis: {group['label']}",
        f"**Quantity**: {quantity['name']} ({unit})",
        f"**Period**: {start_str} to {end_str} (WIB)",
        f"**Bucket**: {period['bucket']}",
    ]

    if group["device_count"] > 1:
        lines.append(f"**Devices**: {group['device_count']}")

    lines.extend([
        "",
        "### Summary",
        f"- **Overall Peak**: {stats['overall_peak']} {unit}",
        f"- **Overall Average**: {stats['overall_avg']} {unit}",
        f"- **Data Points**: {stats['data_points']:,}",
        "",
    ])

    if peak_count == 0:
        lines.append("No peaks found for this period.")
        return "\n".join(lines)

    lines.append(f"### Top {peak_count} Peaks")
    lines.append("")

    for i, peak in enumerate(peaks, 1):
        peak_time = peak["time"]
        time_str = format_display_datetime(peak_time) or (peak_time[:16] if peak_time else "?")
        val = peak["value"]
        device = peak["device_name"]

        if group["device_count"] == 1:
            lines.append(f"{i}. **{val} {unit}** at {time_str}")
        else:
            lines.append(f"{i}. **{val} {unit}** at {time_str} ({device})")

    # Add breakdown if present
    breakdown = result.get("breakdown", [])
    if breakdown:
        lines.extend([
            "",
            "### Per-Device Breakdown",
            "",
        ])
        for item in breakdown[:5]:  # Limit to top 5 devices
            dev_name = item["device_name"]
            max_peak = item["max_peak"]
            lines.append(f"**{dev_name}** - Peak: {max_peak} {unit}")

            # Show recent daily data (last 5 days)
            daily = item.get("daily_data", [])[-5:]
            for d in daily:
                lines.append(f"  - {d['date']}: peak={d['peak']}, avg={d['avg']}")

    return "\n".join(lines)
