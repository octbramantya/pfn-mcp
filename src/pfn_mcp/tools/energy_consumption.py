"""Energy consumption tools - Query actual consumption from cumulative meter data."""

import logging
from datetime import UTC, datetime, timedelta

from pfn_mcp import db
from pfn_mcp.tools.datetime_utils import format_display_datetime
from pfn_mcp.tools.telemetry import (
    BUCKET_INTERVALS,
    BUCKET_LABELS,
    _resolve_device_id,
    parse_period,
    select_bucket,
)

logger = logging.getLogger(__name__)

# Must match telemetry_intervals_cumulative view
CUMULATIVE_QUANTITY_IDS = {62, 89, 96, 124, 130, 131, 481}

# Active Energy = default for "energy" queries
# 124 = Active Energy Delivered, 131 = Active Energy Received
# Device-specific: some use 124, some use 131 based on modbus setup
ACTIVE_ENERGY_IDS = {124, 131}

# Energy quantity aliases for search
ENERGY_ALIASES = {
    "energy": ACTIVE_ENERGY_IDS,
    "active energy": ACTIVE_ENERGY_IDS,
    "reactive energy": {89, 96},
    "apparent energy": {62, 481},
}

# Quantity names for display
ENERGY_QUANTITY_NAMES = {
    62: "Apparent Energy Delivered + Received",
    89: "Reactive Energy Delivered",
    96: "Reactive Energy Received",
    124: "Active Energy Delivered",
    130: "Active Energy Delivered-Received",
    131: "Active Energy Received",
    481: "Apparent Energy Delivered",
}


def is_energy_quantity(quantity_id: int) -> bool:
    """Check if a quantity ID is an energy/cumulative quantity."""
    return quantity_id in CUMULATIVE_QUANTITY_IDS


def select_energy_data_source(bucket: str) -> str:
    """
    Select data source based on bucket size.

    - 1day, 1week: daily_energy_cost_summary (pre-calculated, fast)
    - 15min, 1hour, 4hour: telemetry_intervals_cumulative (view, calculates on-the-fly)
    """
    if bucket in ("1day", "1week"):
        return "daily_energy_cost_summary"
    return "telemetry_intervals_cumulative"


async def _detect_energy_quantity(device_id: int) -> int | None:
    """
    Find which active energy quantity ID this device uses.

    Different devices may use 124 (Active Energy Delivered) or 131 (Active Energy Received)
    depending on their modbus configuration.
    """
    # Check daily_energy_cost_summary first (faster)
    row = await db.fetch_one(
        """
        SELECT DISTINCT quantity_id
        FROM daily_energy_cost_summary
        WHERE device_id = $1 AND quantity_id IN (124, 131)
        LIMIT 1
        """,
        device_id,
    )
    if row:
        return row["quantity_id"]

    # Fall back to telemetry_intervals_cumulative
    row = await db.fetch_one(
        """
        SELECT DISTINCT quantity_id
        FROM telemetry_intervals_cumulative
        WHERE device_id = $1 AND quantity_id IN (124, 131)
        LIMIT 1
        """,
        device_id,
    )
    return row["quantity_id"] if row else None


async def _resolve_energy_quantity(
    device_id: int,
    quantity_id: int | None,
    quantity_search: str | None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve energy quantity from ID, search term, or auto-detect.

    Returns (quantity_id, quantity_info, error_message)
    """
    # If explicit ID provided, validate it
    if quantity_id is not None:
        if quantity_id not in CUMULATIVE_QUANTITY_IDS:
            return (
                None,
                None,
                f"Quantity {quantity_id} is not an energy quantity. "
                f"Supported IDs: {sorted(CUMULATIVE_QUANTITY_IDS)}",
            )
        quantity = await db.fetch_one(
            """SELECT id, quantity_code, quantity_name, unit, aggregation_method
               FROM quantities WHERE id = $1 AND is_active = true""",
            quantity_id,
        )
        if not quantity:
            return None, None, f"Quantity ID not found: {quantity_id}"
        return quantity["id"], dict(quantity), None

    # If search term provided, check energy aliases
    if quantity_search:
        search_lower = quantity_search.lower().strip()
        for alias, qty_ids in ENERGY_ALIASES.items():
            if alias in search_lower or search_lower in alias:
                # Find which of these quantities the device has
                for qty_id in qty_ids:
                    row = await db.fetch_one(
                        """SELECT DISTINCT quantity_id
                           FROM daily_energy_cost_summary
                           WHERE device_id = $1 AND quantity_id = $2
                           LIMIT 1""",
                        device_id,
                        qty_id,
                    )
                    if row:
                        quantity = await db.fetch_one(
                            """SELECT id, quantity_code, quantity_name, unit, aggregation_method
                               FROM quantities WHERE id = $1""",
                            qty_id,
                        )
                        if quantity:
                            return quantity["id"], dict(quantity), None

        return None, None, f"No energy data found for search: {quantity_search}"

    # Default: auto-detect active energy quantity for device
    detected_id = await _detect_energy_quantity(device_id)
    if detected_id is None:
        return None, None, "No active energy data found for this device"

    quantity = await db.fetch_one(
        """SELECT id, quantity_code, quantity_name, unit, aggregation_method
           FROM quantities WHERE id = $1""",
        detected_id,
    )
    if not quantity:
        return None, None, f"Quantity ID not found: {detected_id}"
    return quantity["id"], dict(quantity), None


async def _query_daily_consumption(
    device_id: int,
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
    bucket_interval: timedelta,
) -> list[dict]:
    """
    Query energy consumption from daily_energy_cost_summary.

    Fast, pre-calculated data with cost included.
    """
    query = """
        SELECT
            time_bucket($1::interval, daily_bucket) as time_bucket,
            SUM(total_consumption) as consumption,
            SUM(total_cost) as cost,
            COUNT(DISTINCT shift_period) as shift_count,
            COUNT(DISTINCT rate_code) as rate_count,
            array_agg(DISTINCT rate_code) as rate_codes
        FROM daily_energy_cost_summary
        WHERE device_id = $2
          AND quantity_id = $3
          AND daily_bucket >= $4
          AND daily_bucket < $5
        GROUP BY time_bucket($1::interval, daily_bucket)
        ORDER BY time_bucket
    """
    return await db.fetch_all(
        query, bucket_interval, device_id, quantity_id, query_start, query_end
    )


async def _query_subdaily_consumption(
    device_id: int,
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
    bucket_interval: timedelta,
) -> list[dict]:
    """
    Query energy consumption from telemetry_intervals_cumulative view.

    Calculates consumption deltas and costs inline using get_utility_rate().
    """
    query = """
        WITH interval_data AS (
            SELECT
                time_bucket($1::interval, tic.bucket) as time_bucket,
                tic.bucket as timestamp_sample,
                tic.tenant_id,
                tic.device_id,
                tic.interval_value
            FROM telemetry_intervals_cumulative tic
            WHERE tic.device_id = $2
              AND tic.quantity_id = $3
              AND tic.bucket >= $4
              AND tic.bucket < $5
              AND tic.data_quality_flag = 'NORMAL'
        ),
        with_rates AS (
            SELECT
                id.*,
                (SELECT rate_per_unit
                 FROM get_utility_rate(id.tenant_id, id.device_id, id.timestamp_sample)
                 LIMIT 1) as rate_per_unit,
                (SELECT rate_code
                 FROM get_utility_rate(id.tenant_id, id.device_id, id.timestamp_sample)
                 LIMIT 1) as rate_code
            FROM interval_data id
        )
        SELECT
            time_bucket,
            SUM(interval_value) as consumption,
            SUM(interval_value * COALESCE(rate_per_unit, 0)) as cost,
            COUNT(*) as interval_count,
            array_agg(DISTINCT rate_code) as rate_codes
        FROM with_rates
        GROUP BY time_bucket
        ORDER BY time_bucket
    """
    return await db.fetch_all(
        query, bucket_interval, device_id, quantity_id, query_start, query_end
    )


async def _query_subdaily_consumption_no_cost(
    device_id: int,
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
    bucket_interval: timedelta,
) -> list[dict]:
    """
    Query energy consumption without cost calculation (faster fallback).

    Used when utility rate lookup fails or for non-priced quantities.
    """
    query = """
        SELECT
            time_bucket($1::interval, bucket) as time_bucket,
            SUM(interval_value) as consumption,
            COUNT(*) as interval_count
        FROM telemetry_intervals_cumulative
        WHERE device_id = $2
          AND quantity_id = $3
          AND bucket >= $4
          AND bucket < $5
          AND data_quality_flag = 'NORMAL'
        GROUP BY time_bucket($1::interval, bucket)
        ORDER BY time_bucket
    """
    return await db.fetch_all(
        query, bucket_interval, device_id, quantity_id, query_start, query_end
    )


async def _get_data_quality_summary(
    device_id: int,
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
) -> dict:
    """Get data quality breakdown for the query period."""
    query = """
        SELECT
            data_quality_flag,
            COUNT(*) as count,
            SUM(CASE WHEN interval_value > 0 THEN interval_value ELSE 0 END) as excluded_consumption
        FROM telemetry_intervals_cumulative
        WHERE device_id = $1
          AND quantity_id = $2
          AND bucket >= $3
          AND bucket < $4
        GROUP BY data_quality_flag
        ORDER BY count DESC
    """
    rows = await db.fetch_all(query, device_id, quantity_id, query_start, query_end)
    return {row["data_quality_flag"]: dict(row) for row in rows}


async def get_energy_consumption(
    device_id: int | None = None,
    device_name: str | None = None,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    bucket: str = "auto",
    include_quality_info: bool = False,
) -> dict:
    """
    Get energy consumption for a device.

    Returns actual consumption (not cumulative meter readings) calculated from
    interval deltas. Handles meter resets and data anomalies automatically.

    Args:
        device_id: Device ID (preferred)
        device_name: Device name (fuzzy search)
        quantity_id: Energy quantity ID (e.g., 124 for Active Energy Delivered)
        quantity_search: Quantity search: energy, active energy, reactive energy
        period: Time period like "1h", "24h", "7d", "30d", "3M", "1Y"
        start_date: Start date (ISO format, alternative to period)
        end_date: End date (ISO format, defaults to now)
        bucket: Bucket size: "15min", "1hour", "4hour", "1day", "1week", "auto"
        include_quality_info: Include data quality breakdown in response

    Returns:
        Dictionary with device, quantity, time range, consumption data, and optional cost
    """
    # Resolve device
    resolved_device_id, device_info, error = await _resolve_device_id(
        device_id, device_name
    )
    if error:
        return {"error": error}

    # Resolve energy quantity
    resolved_quantity_id, quantity_info, error = await _resolve_energy_quantity(
        resolved_device_id, quantity_id, quantity_search
    )
    if error:
        return {"error": error}

    # Determine time range
    now = datetime.now(UTC).replace(tzinfo=None)
    if period:
        delta = parse_period(period)
        if delta is None:
            return {"error": f"Invalid period format: {period}. Use e.g. 24h, 7d, 30d"}
        query_start = now - delta
        query_end = now
    elif start_date:
        try:
            query_start = datetime.fromisoformat(start_date.replace("Z", "+00:00"))
            if query_start.tzinfo:
                query_start = query_start.astimezone(UTC).replace(tzinfo=None)
        except ValueError:
            return {"error": f"Invalid start_date format: {start_date}"}

        if end_date:
            try:
                query_end = datetime.fromisoformat(end_date.replace("Z", "+00:00"))
                if query_end.tzinfo:
                    query_end = query_end.astimezone(UTC).replace(tzinfo=None)
            except ValueError:
                return {"error": f"Invalid end_date format: {end_date}"}
        else:
            query_end = now
    else:
        # Default to last 7 days for energy queries
        query_start = now - timedelta(days=7)
        query_end = now

    # Select bucket size
    time_range = query_end - query_start
    valid_buckets = ["15min", "1hour", "4hour", "1day", "1week"]

    if bucket == "auto":
        selected_bucket = select_bucket(time_range)
    elif bucket in valid_buckets:
        selected_bucket = bucket
    else:
        return {"error": f"Invalid bucket: {bucket}. Use: {', '.join(valid_buckets)}, auto"}

    bucket_interval = BUCKET_INTERVALS.get(selected_bucket, timedelta(minutes=15))

    # Select data source and query
    data_source = select_energy_data_source(selected_bucket)

    if data_source == "daily_energy_cost_summary":
        rows = await _query_daily_consumption(
            resolved_device_id,
            resolved_quantity_id,
            query_start,
            query_end,
            bucket_interval,
        )
        has_cost = True
    else:
        # Try with cost calculation first
        try:
            rows = await _query_subdaily_consumption(
                resolved_device_id,
                resolved_quantity_id,
                query_start,
                query_end,
                bucket_interval,
            )
            has_cost = True
        except Exception as e:
            # Fall back to no-cost query if utility rate lookup fails
            logger.warning(f"Cost calculation failed, falling back to no-cost: {e}")
            rows = await _query_subdaily_consumption_no_cost(
                resolved_device_id,
                resolved_quantity_id,
                query_start,
                query_end,
                bucket_interval,
            )
            has_cost = False

    # Format data points
    data_points = []
    total_consumption = 0
    total_cost = 0

    for row in rows:
        consumption = float(row["consumption"]) if row["consumption"] else 0
        total_consumption += consumption

        point = {
            "time": row["time_bucket"].isoformat() if row["time_bucket"] else None,
            "time_dt": row["time_bucket"],
            "consumption": round(consumption, 3),
        }

        if has_cost and row.get("cost") is not None:
            cost = float(row["cost"])
            total_cost += cost
            point["cost"] = round(cost, 2)

        if row.get("rate_codes"):
            # Filter out None values from rate_codes array
            rate_codes = [r for r in row["rate_codes"] if r]
            if rate_codes:
                point["rate_codes"] = rate_codes

        data_points.append(point)

    # Build result
    unit = quantity_info.get("unit") or "kWh"

    result = {
        "device": {
            "id": device_info["id"],
            "name": device_info.get("display_name") or device_info.get("device_code"),
        },
        "quantity": {
            "id": quantity_info["id"],
            "name": quantity_info["quantity_name"],
            "code": quantity_info["quantity_code"],
            "unit": unit,
        },
        "time_range": {
            "start": query_start.isoformat(),
            "end": query_end.isoformat(),
            "start_dt": query_start,
            "end_dt": query_end,
            "bucket": selected_bucket,
            "bucket_interval": BUCKET_LABELS.get(selected_bucket, selected_bucket),
            "data_source": data_source,
        },
        "summary": {
            "total_consumption": round(total_consumption, 3),
            "unit": unit,
        },
        "data": data_points,
        "point_count": len(data_points),
    }

    # Add cost to summary if available
    if has_cost and total_cost > 0:
        result["summary"]["total_cost"] = round(total_cost, 2)
        result["summary"]["currency"] = "IDR"

    # Add quality info if requested
    if include_quality_info:
        quality_summary = await _get_data_quality_summary(
            resolved_device_id,
            resolved_quantity_id,
            query_start,
            query_end,
        )
        result["data_quality"] = quality_summary

    return result


def format_energy_consumption_response(result: dict) -> str:
    """Format get_energy_consumption response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    quantity = result["quantity"]
    time_range = result["time_range"]
    summary = result["summary"]
    data = result["data"]
    point_count = result["point_count"]

    # Format timestamps in display timezone
    start_str = format_display_datetime(time_range.get("start_dt")) or time_range["start"][:16]
    end_str = format_display_datetime(time_range.get("end_dt")) or time_range["end"][:16]

    unit = quantity.get("unit") or "kWh"

    lines = [
        f"## Energy Consumption: {device['name']}",
        f"**Quantity**: {quantity['name']}",
        f"**Period**: {start_str} to {end_str} (WIB)",
        f"**Bucket**: {time_range['bucket']} ({point_count} points)",
        "",
    ]

    if point_count == 0:
        lines.append("No consumption data available for this period.")
        lines.append("\nTry using `get_device_data_range` to check data availability.")
        return "\n".join(lines)

    # Summary
    lines.append("### Summary")
    lines.append(f"- **Total Consumption**: {summary['total_consumption']:,.2f} {unit}")

    if "total_cost" in summary:
        lines.append(f"- **Total Cost**: Rp {summary['total_cost']:,.0f}")
    lines.append("")

    # Data quality info if present
    if "data_quality" in result:
        quality = result["data_quality"]
        lines.append("### Data Quality")
        for flag, info in quality.items():
            count = info.get("count", 0)
            lines.append(f"- {flag}: {count} intervals")
        lines.append("")

    # Data points table
    lines.append("### Consumption by Period")

    def format_point_time(p: dict) -> str:
        if p.get("time_dt"):
            return format_display_datetime(p["time_dt"])
        return p["time"][:16] if p.get("time") else "?"

    has_cost = any("cost" in p for p in data)

    if point_count <= 12:
        for p in data:
            time_str = format_point_time(p)
            if has_cost and "cost" in p:
                rate_str = f" ({', '.join(p.get('rate_codes', []))})" if p.get("rate_codes") else ""
                lines.append(
                    f"- {time_str}: {p['consumption']:,.2f} {unit} | Rp {p['cost']:,.0f}{rate_str}"
                )
            else:
                lines.append(f"- {time_str}: {p['consumption']:,.2f} {unit}")
    else:
        # Show first 4 and last 4
        for p in data[:4]:
            time_str = format_point_time(p)
            if has_cost and "cost" in p:
                lines.append(f"- {time_str}: {p['consumption']:,.2f} {unit} | Rp {p['cost']:,.0f}")
            else:
                lines.append(f"- {time_str}: {p['consumption']:,.2f} {unit}")

        lines.append(f"  ... ({point_count - 8} more points) ...")

        for p in data[-4:]:
            time_str = format_point_time(p)
            if has_cost and "cost" in p:
                lines.append(f"- {time_str}: {p['consumption']:,.2f} {unit} | Rp {p['cost']:,.0f}")
            else:
                lines.append(f"- {time_str}: {p['consumption']:,.2f} {unit}")

    return "\n".join(lines)
