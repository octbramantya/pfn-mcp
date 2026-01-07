"""Telemetry tools - Phase 2 time-series data access."""

import logging
import re
from datetime import UTC, datetime, timedelta

from pfn_mcp import db
from pfn_mcp.tools.datetime_utils import format_display_datetime
from pfn_mcp.tools.quantities import QUANTITY_ALIASES
from pfn_mcp.tools.resolve import resolve_tenant

logger = logging.getLogger(__name__)


# Period string patterns (e.g., "1h", "24h", "7d", "30d", "3M", "1Y")
PERIOD_PATTERN = re.compile(r"^(\d+)\s*([hHdDwWmMyY])$")

# Map period units to timedelta kwargs or special handling
PERIOD_UNITS = {
    "h": "hours",
    "d": "days",
    "w": "weeks",
    "m": "days",  # months approximated as 30 days
    "y": "days",  # years approximated as 365 days
}

# Bucket sizes in minutes for comparison
BUCKET_MINUTES = {
    "15min": 15,
    "1hour": 60,
    "4hour": 240,
    "1day": 1440,
    "1week": 10080,
}

# TimescaleDB time_bucket intervals (as timedelta for asyncpg compatibility)
BUCKET_INTERVALS = {
    "15min": timedelta(minutes=15),
    "1hour": timedelta(hours=1),
    "4hour": timedelta(hours=4),
    "1day": timedelta(days=1),
    "1week": timedelta(weeks=1),
}

# Human-readable bucket interval labels for display
BUCKET_LABELS = {
    "15min": "15 minutes",
    "1hour": "1 hour",
    "4hour": "4 hours",
    "1day": "1 day",
    "1week": "1 week",
}


async def resolve_device(
    search: str,
    tenant: str | None = None,
    limit: int = 5,
) -> dict:
    """
    Resolve device search to ranked candidates with match confidence.

    Used before telemetry queries to confirm device selection when
    the search term could match multiple devices.

    Args:
        search: Device name search term
        tenant: Tenant name or code filter (None = all tenants/superuser)
        limit: Maximum candidates to return

    Returns:
        Dict with search term, candidates list, and match summary
    """
    search_term = search.strip()
    search_lower = search_term.lower()

    conditions = ["d.is_active = true"]
    params = []
    param_idx = 1

    # Tenant filter - resolve string to ID
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {
                "error": error,
                "search": search_term,
                "candidates": [],
                "count": 0,
                "needs_disambiguation": False,
                "exact_match": False,
            }
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    # Search filter - match display_name or device_name
    conditions.append(
        f"(d.display_name ILIKE ${param_idx} OR d.device_name ILIKE ${param_idx})"
    )
    params.append(f"%{search_term}%")
    param_idx += 1

    # Calculate match confidence in SQL for ranking
    # confidence: 0=exact, 1=starts_with, 2=word_boundary, 3=contains (fuzzy)
    confidence_case = f"""
        CASE
            WHEN LOWER(d.display_name) = ${param_idx} THEN 0
            WHEN LOWER(d.display_name) LIKE ${param_idx} || ' %' THEN 1
            WHEN LOWER(d.display_name) LIKE '% ' || ${param_idx} || ' %' THEN 2
            WHEN LOWER(d.display_name) LIKE '% ' || ${param_idx} THEN 2
            WHEN LOWER(d.display_name) LIKE ${param_idx} || '%' THEN 1
            ELSE 3
        END
    """
    params.append(search_lower)
    param_idx += 1

    where_clause = " AND ".join(conditions)

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
            {confidence_case} as match_confidence
        FROM devices d
        LEFT JOIN tenants t ON d.tenant_id = t.id
        WHERE {where_clause}
        ORDER BY match_confidence, d.display_name
        LIMIT ${param_idx}
    """
    params.append(limit)

    rows = await db.fetch_all(query, *params)

    # Convert confidence numbers to labels
    confidence_labels = {
        0: "exact",
        1: "partial",
        2: "partial",
        3: "fuzzy",
    }

    candidates = []
    for row in rows:
        conf_num = row.get("match_confidence", 3)
        conf_label = confidence_labels.get(conf_num, "fuzzy")
        candidates.append({
            "id": row["id"],
            "display_name": row.get("display_name") or row.get("device_name"),
            "device_code": row["device_code"],
            "device_type": row.get("device_type"),
            "tenant_id": row["tenant_id"],
            "tenant_name": row.get("tenant_name"),
            "confidence": conf_label,
            "match_type": conf_label,
        })

    # Determine if disambiguation is needed
    needs_disambiguation = (
        len(candidates) == 0
        or len(candidates) > 1
        or (len(candidates) == 1 and candidates[0]["confidence"] != "exact")
    )

    return {
        "search": search_term,
        "tenant_filter": tenant,
        "candidates": candidates,
        "count": len(candidates),
        "needs_disambiguation": needs_disambiguation,
        "exact_match": (
            len(candidates) == 1 and candidates[0]["confidence"] == "exact"
        ),
    }


def format_resolve_device_response(result: dict) -> str:
    """Format resolve_device response for human-readable output."""
    search = result["search"]
    candidates = result["candidates"]
    count = result["count"]

    if count == 0:
        return f"No devices found matching '{search}'."

    # Check for exact single match
    if result.get("exact_match"):
        device = candidates[0]
        return (
            f"Found exact match for '{search}':\n\n"
            f"**{device['display_name']}** (ID: {device['id']})\n"
            f"Tenant: {device['tenant_name']}\n"
            f"Type: {device['device_type'] or '-'}\n\n"
            f"Ready to query telemetry with device_id={device['id']}"
        )

    # Multiple matches - format for disambiguation
    lines = [f"Found {count} device(s) matching '{search}':\n"]

    for i, device in enumerate(candidates, 1):
        conf = device["confidence"].upper()
        tenant = device["tenant_name"] or "Unknown"
        lines.append(
            f"{i}. **{device['display_name']}** (ID: {device['id']}) "
            f"- {tenant} [{conf}]"
        )
        if device["device_type"]:
            lines.append(f"   Type: {device['device_type']}")

    lines.append("\nPlease specify which device you mean, or use the device ID directly.")

    return "\n".join(lines)


def parse_period(period: str) -> timedelta | None:
    """
    Parse period string like '1h', '24h', '7d', '30d', '3M', '1Y'.

    Returns timedelta or None if invalid.
    """
    match = PERIOD_PATTERN.match(period.strip())
    if not match:
        return None

    value = int(match.group(1))
    unit = match.group(2).lower()

    if unit == "m":  # months
        return timedelta(days=value * 30)
    elif unit == "y":  # years
        return timedelta(days=value * 365)
    else:
        unit_key = PERIOD_UNITS.get(unit, "days")
        return timedelta(**{unit_key: value})


def select_bucket(time_range: timedelta) -> str:
    """
    Select optimal bucket size based on time range.

    Adaptive bucketing logic:
    - ≤ 24 hours → 15min buckets (~96 points)
    - ≤ 7 days → 1hour buckets (~168 points)
    - ≤ 30 days → 4hour buckets (~180 points)
    - ≤ 90 days → 1day buckets (~90 points)
    - > 90 days → 1week buckets
    """
    hours = time_range.total_seconds() / 3600

    if hours <= 24:
        return "15min"
    elif hours <= 24 * 7:
        return "1hour"
    elif hours <= 24 * 30:
        return "4hour"
    elif hours <= 24 * 90:
        return "1day"
    else:
        return "1week"


async def _resolve_device_id(
    device_id: int | None, device_name: str | None
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve device from ID or name.

    Returns (device_id, device_info, error_message)
    """
    if device_id is None and device_name is None:
        return None, None, "Either device_id or device_name is required"

    if device_id is not None:
        device = await db.fetch_one(
            """SELECT id, display_name, device_code, tenant_id
               FROM devices WHERE id = $1 AND is_active = true""",
            device_id,
        )
        if not device:
            return None, None, f"Device ID not found: {device_id}"
        return device["id"], dict(device), None

    # Resolve by name - find best match
    device = await db.fetch_one(
        """SELECT id, display_name, device_code, tenant_id
           FROM devices
           WHERE is_active = true
             AND (display_name ILIKE $1 OR device_name ILIKE $1)
           ORDER BY
               CASE
                   WHEN LOWER(display_name) = LOWER($2) THEN 0
                   WHEN LOWER(display_name) LIKE LOWER($2) || '%' THEN 1
                   ELSE 2
               END
           LIMIT 1""",
        f"%{device_name}%",
        device_name,
    )
    if not device:
        return None, None, f"Device not found: {device_name}"
    return device["id"], dict(device), None


async def _resolve_quantity_id(
    quantity_id: int | None, quantity_search: str | None
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve quantity from ID or search term.

    Returns (quantity_id, quantity_info, error_message)
    """
    if quantity_id is None and quantity_search is None:
        return None, None, "Either quantity_id or quantity_search is required"

    if quantity_id is not None:
        quantity = await db.fetch_one(
            """SELECT id, quantity_code, quantity_name, unit, aggregation_method
               FROM quantities WHERE id = $1 AND is_active = true""",
            quantity_id,
        )
        if not quantity:
            return None, None, f"Quantity ID not found: {quantity_id}"
        return quantity["id"], dict(quantity), None

    # Resolve by search - check semantic aliases first
    search_upper = quantity_search.upper().strip()
    alias_patterns = []
    for alias, patterns in QUANTITY_ALIASES.items():
        if alias.upper() in search_upper or search_upper in alias.upper():
            alias_patterns.extend(patterns)

    if alias_patterns:
        # Build OR conditions for alias patterns
        conditions = " OR ".join(
            f"quantity_code ILIKE '%{p}%'" for p in alias_patterns
        )
        quantity = await db.fetch_one(
            f"""SELECT id, quantity_code, quantity_name, unit, aggregation_method
                FROM quantities
                WHERE is_active = true AND ({conditions})
                ORDER BY quantity_name
                LIMIT 1"""
        )
    else:
        quantity = await db.fetch_one(
            """SELECT id, quantity_code, quantity_name, unit, aggregation_method
               FROM quantities
               WHERE is_active = true
                 AND (quantity_name ILIKE $1 OR quantity_code ILIKE $1)
               ORDER BY quantity_name
               LIMIT 1""",
            f"%{quantity_search}%",
        )

    if not quantity:
        return None, None, f"Quantity not found: {quantity_search}"
    return quantity["id"], dict(quantity), None


async def get_device_telemetry(
    device_id: int | None = None,
    device_name: str | None = None,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    bucket: str = "auto",
) -> dict:
    """
    Fetch aggregated telemetry data for a device.

    Args:
        device_id: Device ID (preferred)
        device_name: Device name (fuzzy search)
        quantity_id: Quantity ID (preferred)
        quantity_search: Quantity search term (uses semantic aliases)
        period: Time period like "1h", "24h", "7d", "30d", "3M", "1Y"
        start_date: Start date (ISO format, alternative to period)
        end_date: End date (ISO format, defaults to now)
        bucket: Bucket size: "15min", "1hour", "4hour", "1day", "1week", "auto"

    Returns:
        Dictionary with device, quantity, time range, and data points
    """
    # Resolve device
    resolved_device_id, device_info, error = await _resolve_device_id(
        device_id, device_name
    )
    if error:
        return {"error": error}

    # Resolve quantity
    resolved_quantity_id, quantity_info, error = await _resolve_quantity_id(
        quantity_id, quantity_search
    )
    if error:
        return {"error": error}

    # Determine time range (use naive UTC for database compatibility)
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
            # Convert to naive UTC for database
            if query_start.tzinfo:
                query_start = query_start.astimezone(UTC).replace(tzinfo=None)
        except ValueError:
            return {"error": f"Invalid start_date format: {start_date}"}

        if end_date:
            try:
                query_end = datetime.fromisoformat(end_date.replace("Z", "+00:00"))
                # Convert to naive UTC for database
                if query_end.tzinfo:
                    query_end = query_end.astimezone(UTC).replace(tzinfo=None)
            except ValueError:
                return {"error": f"Invalid end_date format: {end_date}"}
        else:
            query_end = now
    else:
        # Default to last 24 hours
        query_start = now - timedelta(hours=24)
        query_end = now

    # Select bucket size
    time_range = query_end - query_start
    if bucket == "auto":
        selected_bucket = select_bucket(time_range)
    elif bucket in BUCKET_INTERVALS:
        selected_bucket = bucket
    else:
        return {
            "error": f"Invalid bucket: {bucket}. Use: 15min, 1hour, 4hour, 1day, 1week, auto"
        }

    bucket_interval = BUCKET_INTERVALS[selected_bucket]

    # Query telemetry data with aggregation
    # Note: telemetry_15min_agg has aggregated_value and sample_count columns
    query = """
        SELECT
            time_bucket($1::interval, bucket) as time_bucket,
            AVG(aggregated_value) as avg,
            MIN(aggregated_value) as min,
            MAX(aggregated_value) as max,
            SUM(aggregated_value) as sum,
            SUM(sample_count) as count
        FROM telemetry_15min_agg
        WHERE device_id = $2
          AND quantity_id = $3
          AND bucket >= $4
          AND bucket < $5
        GROUP BY time_bucket($1::interval, bucket)
        ORDER BY time_bucket
    """

    rows = await db.fetch_all(
        query,
        bucket_interval,
        resolved_device_id,
        resolved_quantity_id,
        query_start,
        query_end,
    )

    # Format data points
    data_points = []
    for row in rows:
        point = {
            "time": row["time_bucket"].isoformat() if row["time_bucket"] else None,
            "time_dt": row["time_bucket"],  # datetime object for formatter
            "avg": round(row["avg"], 3) if row["avg"] is not None else None,
            "min": round(row["min"], 3) if row["min"] is not None else None,
            "max": round(row["max"], 3) if row["max"] is not None else None,
            "sum": round(row["sum"], 3) if row["sum"] is not None else None,
            "count": row["count"],
        }
        data_points.append(point)

    return {
        "device": {
            "id": device_info["id"],
            "name": device_info.get("display_name") or device_info.get("device_code"),
        },
        "quantity": {
            "id": quantity_info["id"],
            "name": quantity_info["quantity_name"],
            "code": quantity_info["quantity_code"],
            "unit": quantity_info.get("unit"),
            "aggregation_method": quantity_info.get("aggregation_method"),
        },
        "time_range": {
            "start": query_start.isoformat(),
            "end": query_end.isoformat(),
            "start_dt": query_start,  # datetime object for formatter
            "end_dt": query_end,  # datetime object for formatter
            "bucket": selected_bucket,
            "bucket_interval": BUCKET_LABELS[selected_bucket],
        },
        "data": data_points,
        "point_count": len(data_points),
    }


def format_telemetry_response(result: dict) -> str:
    """Format get_device_telemetry response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    quantity = result["quantity"]
    time_range = result["time_range"]
    data = result["data"]
    point_count = result["point_count"]

    # Format period timestamps in display timezone (UTC+7)
    start_str = format_display_datetime(time_range.get("start_dt")) or time_range["start"][:16]
    end_str = format_display_datetime(time_range.get("end_dt")) or time_range["end"][:16]

    lines = [
        f"## Telemetry: {device['name']}",
        f"**Quantity**: {quantity['name']} ({quantity['unit'] or '-'})",
        f"**Period**: {start_str} to {end_str} (WIB)",
        f"**Bucket**: {time_range['bucket']} ({point_count} points)",
        "",
    ]

    if point_count == 0:
        lines.append("No data available for this period.")
        lines.append("\nTry using `get_device_data_range` to check data availability.")
        return "\n".join(lines)

    # Calculate summary stats
    avg_values = [p["avg"] for p in data if p["avg"] is not None]
    min_values = [p["min"] for p in data if p["min"] is not None]
    max_values = [p["max"] for p in data if p["max"] is not None]

    if avg_values:
        overall_avg = sum(avg_values) / len(avg_values)
        overall_min = min(min_values) if min_values else None
        overall_max = max(max_values) if max_values else None

        lines.append("### Summary")
        lines.append(f"- **Average**: {overall_avg:.2f} {quantity['unit'] or ''}")
        if overall_min is not None:
            lines.append(f"- **Min**: {overall_min:.2f} {quantity['unit'] or ''}")
        if overall_max is not None:
            lines.append(f"- **Max**: {overall_max:.2f} {quantity['unit'] or ''}")
        lines.append("")

    # Show sample data points (first and last few)
    lines.append("### Data Points")

    def format_point_time(p: dict) -> str:
        """Format data point timestamp in display timezone."""
        if p.get("time_dt"):
            return format_display_datetime(p["time_dt"])
        return p["time"][:16] if p.get("time") else "?"

    if point_count <= 10:
        for p in data:
            time_str = format_point_time(p)
            lines.append(f"- {time_str}: avg={p['avg']}, min={p['min']}, max={p['max']}")
    else:
        # Show first 3 and last 3
        for p in data[:3]:
            time_str = format_point_time(p)
            lines.append(f"- {time_str}: avg={p['avg']}, min={p['min']}, max={p['max']}")
        lines.append(f"  ... ({point_count - 6} more points) ...")
        for p in data[-3:]:
            time_str = format_point_time(p)
            lines.append(f"- {time_str}: avg={p['avg']}, min={p['min']}, max={p['max']}")

    return "\n".join(lines)


async def get_quantity_stats(
    device_id: int,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str = "30d",
) -> dict:
    """
    Get quick stats about data availability before expensive telemetry query.

    Args:
        device_id: Device ID to query
        quantity_id: Quantity ID (preferred)
        quantity_search: Quantity search term (uses semantic aliases)
        period: Time period to check (default: 30d)

    Returns:
        Dictionary with device, quantity, period, and stats
    """
    # Validate device exists
    device = await db.fetch_one(
        """SELECT id, display_name, device_code, tenant_id
           FROM devices WHERE id = $1 AND is_active = true""",
        device_id,
    )
    if not device:
        return {"error": f"Device ID not found: {device_id}"}

    # Resolve quantity
    resolved_quantity_id, quantity_info, error = await _resolve_quantity_id(
        quantity_id, quantity_search
    )
    if error:
        return {"error": error}

    # Parse period
    delta = parse_period(period)
    if delta is None:
        return {"error": f"Invalid period format: {period}. Use e.g. 24h, 7d, 30d"}

    # Use naive UTC for database compatibility
    now = datetime.now(UTC).replace(tzinfo=None)
    query_start = now - delta
    query_end = now

    # Query stats from telemetry_15min_agg
    # Note: telemetry_15min_agg has aggregated_value column (no separate min/max/avg)
    stats_query = """
        SELECT
            COUNT(*) as data_points,
            MIN(aggregated_value) as min_value,
            MAX(aggregated_value) as max_value,
            AVG(aggregated_value) as avg_value,
            MIN(bucket) as first_reading,
            MAX(bucket) as last_reading
        FROM telemetry_15min_agg
        WHERE device_id = $1
          AND quantity_id = $2
          AND bucket >= $3
          AND bucket < $4
    """

    stats = await db.fetch_one(
        stats_query,
        device_id,
        resolved_quantity_id,
        query_start,
        query_end,
    )

    # Calculate expected readings (15-min intervals)
    expected_readings = int(delta.total_seconds() / 900)  # 900s = 15min
    actual_readings = stats["data_points"] if stats else 0
    gaps = max(0, expected_readings - actual_readings)

    return {
        "device": {
            "id": device["id"],
            "name": device.get("display_name") or device.get("device_code"),
        },
        "quantity": {
            "id": quantity_info["id"],
            "name": quantity_info["quantity_name"],
            "unit": quantity_info.get("unit"),
        },
        "period": {
            "start": query_start.isoformat(),
            "end": query_end.isoformat(),
            "requested": period,
        },
        "stats": {
            "data_points": actual_readings,
            "expected_points": expected_readings,
            "min": round(stats["min_value"], 3) if stats and stats["min_value"] else None,
            "max": round(stats["max_value"], 3) if stats and stats["max_value"] else None,
            "avg": round(stats["avg_value"], 3) if stats and stats["avg_value"] else None,
            "first_reading": (
                stats["first_reading"].isoformat()
                if stats and stats["first_reading"]
                else None
            ),
            "last_reading": (
                stats["last_reading"].isoformat()
                if stats and stats["last_reading"]
                else None
            ),
            "gaps": gaps,
            "completeness_pct": round(100 * actual_readings / expected_readings, 1)
            if expected_readings > 0
            else 0,
        },
    }


def format_quantity_stats_response(result: dict) -> str:
    """Format get_quantity_stats response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    quantity = result["quantity"]
    period = result["period"]
    stats = result["stats"]

    lines = [
        f"## Data Stats: {device['name']}",
        f"**Quantity**: {quantity['name']} ({quantity['unit'] or '-'})",
        f"**Period**: {period['requested']} ({period['start'][:10]} to {period['end'][:10]})",
        "",
    ]

    if stats["data_points"] == 0:
        lines.append("**No data available** for this period.")
        lines.append("\nTry using `get_device_data_range` to find when data exists.")
        return "\n".join(lines)

    lines.append("### Statistics")
    pts = f"{stats['data_points']:,} of {stats['expected_points']:,}"
    lines.append(f"- **Data points**: {pts} expected")
    lines.append(f"- **Completeness**: {stats['completeness_pct']}%")
    if stats["gaps"] > 0:
        lines.append(f"- **Gaps**: {stats['gaps']:,} missing readings")
    lines.append("")

    lines.append("### Value Range")
    lines.append(f"- **Average**: {stats['avg']} {quantity['unit'] or ''}")
    lines.append(f"- **Min**: {stats['min']} {quantity['unit'] or ''}")
    lines.append(f"- **Max**: {stats['max']} {quantity['unit'] or ''}")
    lines.append("")

    lines.append("### Time Range")
    if stats["first_reading"]:
        lines.append(f"- **First reading**: {stats['first_reading'][:19]}")
    if stats["last_reading"]:
        lines.append(f"- **Last reading**: {stats['last_reading'][:19]}")

    return "\n".join(lines)
