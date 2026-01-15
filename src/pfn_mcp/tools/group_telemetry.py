"""Group telemetry tools - Query aggregated data by device tags or asset groups."""

import logging
from datetime import datetime, timedelta
from typing import Literal

from pfn_mcp import db
from pfn_mcp.tools.electricity_cost import parse_period
from pfn_mcp.tools.resolve import resolve_tenant
from pfn_mcp.tools.telemetry import BUCKET_MINUTES, _resolve_quantity_id

logger = logging.getLogger(__name__)

# Active Energy Delivered quantity ID
ACTIVE_ENERGY_QTY_ID = 124

# Aggregation methods for different quantity types
# "SUM" for cumulative quantities (energy), "AVG" for instantaneous (power, voltage)
CUMULATIVE_METHODS = {"sum", "total", "cumulative"}
INSTANTANEOUS_METHODS = {"avg", "average", "mean", "instantaneous"}

# Output modes for get_group_telemetry
OutputMode = Literal["summary", "timeseries", "per_device"]

# Default max rows for timeseries output
DEFAULT_MAX_ROWS = 200


def select_group_bucket(
    time_range: timedelta,
    device_count: int,
    max_rows: int = DEFAULT_MAX_ROWS,
) -> str:
    """
    Select optimal bucket size to keep total rows under limit.

    Args:
        time_range: Duration of the query
        device_count: Number of devices in the group
        max_rows: Maximum rows to return (default: 200)

    Returns:
        Bucket size string (e.g., "15min", "1hour", "1day")

    Example:
        7 days, 5 devices, max 200 rows:
        - 15min: 672 buckets × 5 = 3360 rows (too many)
        - 1hour: 168 buckets × 5 = 840 rows (too many)
        - 4hour: 42 buckets × 5 = 210 rows (close)
        - 1day: 7 buckets × 5 = 35 rows (fits) ← selected
    """
    if device_count <= 0:
        device_count = 1

    target_buckets = max_rows // device_count
    total_minutes = time_range.total_seconds() / 60

    # Sorted bucket sizes from smallest to largest
    bucket_order = ["15min", "1hour", "4hour", "1day", "1week"]

    for bucket_name in bucket_order:
        bucket_minutes = BUCKET_MINUTES.get(bucket_name, 15)
        num_buckets = total_minutes / bucket_minutes
        if num_buckets <= target_buckets:
            return bucket_name

    # If even 1week is too fine, use 1week anyway
    return "1week"


def is_instantaneous_quantity(quantity_info: dict) -> bool:
    """
    Check if a quantity is instantaneous (not cumulative).

    Instantaneous quantities (voltage, power, current) should use nearest-value
    sampling when aggregating to larger buckets, not AVG.

    Cumulative quantities (energy) should use SUM.

    Args:
        quantity_info: Quantity info dict with aggregation_method field

    Returns:
        True if instantaneous, False if cumulative
    """
    agg_method = (quantity_info.get("aggregation_method") or "avg").lower()
    return agg_method not in CUMULATIVE_METHODS


async def _query_nearest_value_timeseries(
    device_ids: list[int],
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
    bucket_interval: timedelta,
) -> list[dict]:
    """
    Query time-series with nearest-value sampling for instantaneous quantities.

    Instead of AVG, picks the 15-min bucket value nearest to the START of each
    larger time bucket. This preserves actual readings at regular intervals.

    Args:
        device_ids: List of device IDs to query
        quantity_id: Quantity ID
        query_start: Start datetime
        query_end: End datetime
        bucket_interval: Target bucket size (e.g., timedelta(hours=1))

    Returns:
        List of dicts with time_bucket, device_id, device_name, value
    """
    # Params: $1=bucket_interval, $2=quantity_id, $3=start, $4=end, $5+=device_ids
    device_placeholders = ", ".join(f"${i+5}" for i in range(len(device_ids)))

    # DISTINCT ON picks one row per (device_id, time_bucket) combination
    # ORDER BY bucket ASC ensures we get the earliest 15-min bucket within each time bucket
    # (i.e., nearest to the bucket start)
    query = f"""
        SELECT DISTINCT ON (t.device_id, time_bucket($1::interval, t.bucket))
            time_bucket($1::interval, t.bucket) as time_bucket,
            t.device_id,
            d.display_name as device_name,
            t.aggregated_value as value
        FROM telemetry_15min_agg t
        JOIN devices d ON t.device_id = d.id
        WHERE t.quantity_id = $2
          AND t.bucket >= $3
          AND t.bucket < $4
          AND t.device_id IN ({device_placeholders})
        ORDER BY t.device_id, time_bucket($1::interval, t.bucket), t.bucket ASC
    """

    rows = await db.fetch_all(
        query,
        bucket_interval,
        quantity_id,
        query_start,
        query_end,
        *device_ids,
    )

    return [
        {
            "time_bucket": row["time_bucket"],
            "device_id": row["device_id"],
            "device_name": row["device_name"],
            "value": float(row["value"]) if row["value"] is not None else None,
        }
        for row in rows
    ]


async def _query_avg_value_timeseries(
    device_ids: list[int],
    quantity_id: int,
    query_start: datetime,
    query_end: datetime,
    bucket_interval: timedelta,
    is_cumulative: bool,
) -> list[dict]:
    """
    Query time-series with AVG/SUM aggregation for cumulative quantities.

    Args:
        device_ids: List of device IDs to query
        quantity_id: Quantity ID
        query_start: Start datetime
        query_end: End datetime
        bucket_interval: Target bucket size
        is_cumulative: If True, use SUM; otherwise use AVG

    Returns:
        List of dicts with time_bucket, device_id, device_name, value
    """
    # Params: $1=bucket_interval, $2=quantity_id, $3=start, $4=end, $5+=device_ids
    device_placeholders = ", ".join(f"${i+5}" for i in range(len(device_ids)))

    agg_func = "SUM(t.aggregated_value)" if is_cumulative else "AVG(t.aggregated_value)"

    query = f"""
        SELECT
            time_bucket($1::interval, t.bucket) as time_bucket,
            t.device_id,
            d.display_name as device_name,
            {agg_func} as value
        FROM telemetry_15min_agg t
        JOIN devices d ON t.device_id = d.id
        WHERE t.quantity_id = $2
          AND t.bucket >= $3
          AND t.bucket < $4
          AND t.device_id IN ({device_placeholders})
        GROUP BY time_bucket($1::interval, t.bucket), t.device_id, d.display_name
        ORDER BY time_bucket, t.device_id
    """

    rows = await db.fetch_all(
        query,
        bucket_interval,
        quantity_id,
        query_start,
        query_end,
        *device_ids,
    )

    return [
        {
            "time_bucket": row["time_bucket"],
            "device_id": row["device_id"],
            "device_name": row["device_name"],
            "value": float(row["value"]) if row["value"] is not None else None,
        }
        for row in rows
    ]


async def list_tags(
    tenant: str | None = None,
    tag_key: str | None = None,
    tag_category: str | None = None,
) -> dict:
    """
    List available device tags for grouping.

    Args:
        tenant: Tenant name or code to filter tags by devices (optional)
        tag_key: Filter by specific tag key
        tag_category: Filter by tag category

    Returns:
        Dictionary with tags grouped by category
    """
    # Resolve tenant first (if provided)
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    conditions = ["dt.is_active = true"]
    params = []
    param_idx = 1

    # Filter by tenant (join with devices table)
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    if tag_key:
        conditions.append(f"dt.tag_key ILIKE ${param_idx}")
        params.append(f"%{tag_key}%")
        param_idx += 1

    if tag_category:
        conditions.append(f"dt.tag_category ILIKE ${param_idx}")
        params.append(f"%{tag_category}%")
        param_idx += 1

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            dt.tag_category,
            dt.tag_key,
            dt.tag_value,
            COUNT(DISTINCT dt.device_id) as device_count
        FROM device_tags dt
        JOIN devices d ON dt.device_id = d.id AND d.is_active = true
        WHERE {where_clause}
        GROUP BY dt.tag_category, dt.tag_key, dt.tag_value
        ORDER BY dt.tag_category NULLS LAST, dt.tag_key, device_count DESC
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
    tenant: str | None = None,
    tag_key: str = "",
) -> dict:
    """
    List all values for a specific tag key with device counts.

    Args:
        tenant: Tenant name or code to filter tags by devices (optional)
        tag_key: The tag key to list values for

    Returns:
        Dictionary with tag values and device counts
    """
    if not tag_key:
        return {"error": "tag_key is required"}

    # Resolve tenant first (if provided)
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Build query with optional tenant filter
    if tenant_id is not None:
        query = """
            SELECT
                dt.tag_value,
                dt.tag_category,
                COUNT(DISTINCT dt.device_id) as device_count,
                array_agg(DISTINCT d.display_name ORDER BY d.display_name) as devices
            FROM device_tags dt
            JOIN devices d ON dt.device_id = d.id AND d.is_active = true
            WHERE dt.tag_key ILIKE $1
              AND dt.is_active = true
              AND d.tenant_id = $2
            GROUP BY dt.tag_value, dt.tag_category
            ORDER BY device_count DESC
        """
        rows = await db.fetch_all(query, tag_key, tenant_id)
    else:
        query = """
            SELECT
                dt.tag_value,
                dt.tag_category,
                COUNT(DISTINCT dt.device_id) as device_count,
                array_agg(DISTINCT d.display_name ORDER BY d.display_name) as devices
            FROM device_tags dt
            JOIN devices d ON dt.device_id = d.id AND d.is_active = true
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


async def search_tags(
    search: str,
    limit: int = 10,
) -> dict:
    """
    Search for device tags by value or key.

    Finds tags where tag_value or tag_key matches the search term.
    Returns matching tag key/value pairs ranked by match quality.

    Args:
        search: Search term to match against tag_value and tag_key
        limit: Maximum number of results (default: 10)

    Returns:
        Dictionary with matching tags and device info
    """
    if not search or not search.strip():
        return {"error": "Search term is required"}

    search = search.strip()

    query = """
        SELECT
            dt.tag_key,
            dt.tag_value,
            dt.tag_category,
            COUNT(DISTINCT dt.device_id) as device_count,
            array_agg(DISTINCT d.display_name ORDER BY d.display_name) as devices,
            CASE
                WHEN LOWER(dt.tag_value) = LOWER($1) THEN 0
                WHEN LOWER(dt.tag_value) LIKE LOWER($1) || '%' THEN 1
                WHEN LOWER(dt.tag_value) LIKE '%' || LOWER($1) || '%' THEN 2
                WHEN LOWER(dt.tag_key) = LOWER($1) THEN 3
                WHEN LOWER(dt.tag_key) LIKE LOWER($1) || '%' THEN 4
                WHEN LOWER(dt.tag_key) LIKE '%' || LOWER($1) || '%' THEN 5
                ELSE 6
            END as match_rank
        FROM device_tags dt
        JOIN devices d ON dt.device_id = d.id
        WHERE dt.is_active = true
          AND d.is_active = true
          AND (
              dt.tag_value ILIKE '%' || $1 || '%'
              OR dt.tag_key ILIKE '%' || $1 || '%'
          )
        GROUP BY dt.tag_key, dt.tag_value, dt.tag_category
        ORDER BY match_rank, device_count DESC, dt.tag_value
        LIMIT $2
    """

    rows = await db.fetch_all(query, search, limit)

    matches = []
    for row in rows:
        devices = row["devices"] or []
        match_rank = row["match_rank"]

        # Determine match type and quality from rank
        if match_rank <= 2:
            match_type = "value"
        else:
            match_type = "key"

        if match_rank in (0, 3):
            match_quality = "exact"
        elif match_rank in (1, 4):
            match_quality = "starts_with"
        else:
            match_quality = "contains"

        matches.append({
            "tag_key": row["tag_key"],
            "tag_value": row["tag_value"],
            "category": row["tag_category"],
            "device_count": row["device_count"],
            "devices": devices[:10],
            "has_more_devices": len(devices) > 10,
            "match_type": match_type,
            "match_quality": match_quality,
        })

    return {
        "search_term": search,
        "total_matches": len(matches),
        "matches": matches,
    }


def format_search_tags_response(result: dict) -> str:
    """Format search_tags response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    search_term = result["search_term"]
    matches = result["matches"]
    total = result["total_matches"]

    if total == 0:
        return f"No tags found matching '{search_term}'."

    lines = [f"## Tag Search Results for '{search_term}' ({total} found)", ""]

    for match in matches:
        key = match["tag_key"]
        value = match["tag_value"]
        device_count = match["device_count"]
        match_type = match.get("match_type", "value")
        quality = match.get("match_quality", "contains")

        # Show match indicator
        if quality == "exact":
            match_indicator = "[exact]"
        else:
            match_indicator = f"[{match_type}:{quality}]"

        lines.append(f"### {key}={value} {match_indicator}")
        lines.append(f"**Devices**: {device_count}")
        if match.get("category"):
            lines.append(f"**Category**: {match['category']}")

        # List sample devices
        devices = match.get("devices", [])
        if devices:
            for device in devices[:5]:
                lines.append(f"  - {device}")
            if match.get("has_more_devices") or len(devices) > 5:
                lines.append("  - ... and more")
        lines.append("")

    # Hint for using the result
    if matches:
        first = matches[0]
        lines.append("---")
        lines.append(
            f"**Tip**: Use `get_group_telemetry(tag_key=\"{first['tag_key']}\", "
            f"tag_value=\"{first['tag_value']}\")` to query this group."
        )

    return "\n".join(lines)


GroupByType = Literal["tag", "asset"]


async def _resolve_tag_devices(
    tag_key: str,
    tag_value: str,
    tenant_id: int | None = None,
) -> tuple[list[dict], str | None]:
    """Get device IDs and names for a tag key-value pair with optional tenant filter."""
    if tenant_id is not None:
        query = """
            SELECT DISTINCT dt.device_id, d.display_name
            FROM device_tags dt
            JOIN devices d ON dt.device_id = d.id
            WHERE dt.tag_key ILIKE $1
              AND dt.tag_value ILIKE $2
              AND dt.is_active = true
              AND d.is_active = true
              AND d.tenant_id = $3
            ORDER BY d.display_name
        """
        rows = await db.fetch_all(query, tag_key, tag_value, tenant_id)
    else:
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


async def _resolve_multi_tag_devices(
    tags: list[dict],
    tenant_id: int | None = None,
) -> tuple[list[dict], str | None]:
    """
    Get device IDs and names for devices matching ALL specified tags (AND logic).

    Args:
        tags: List of {"key": "...", "value": "..."} dicts
        tenant_id: Optional tenant ID to filter devices

    Returns:
        Tuple of (devices list, error message or None)
    """
    if not tags:
        return [], "At least one tag is required"

    # Validate tag structure
    for i, tag in enumerate(tags):
        if not tag.get("key") or not tag.get("value"):
            return [], f"Tag {i+1} missing 'key' or 'value'"

    # Build query with multiple JOIN conditions for AND logic
    # Each tag requires a separate JOIN to device_tags
    joins = []
    conditions = ["d.is_active = true"]
    params = []
    param_idx = 1

    # Add tenant filter if provided
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    for i, tag in enumerate(tags):
        alias = f"dt{i}"
        joins.append(f"JOIN device_tags {alias} ON d.id = {alias}.device_id")
        conditions.append(f"{alias}.tag_key ILIKE ${param_idx}")
        params.append(tag["key"])
        param_idx += 1
        conditions.append(f"{alias}.tag_value ILIKE ${param_idx}")
        params.append(tag["value"])
        param_idx += 1
        conditions.append(f"{alias}.is_active = true")

    joins_sql = "\n        ".join(joins)
    where_sql = "\n          AND ".join(conditions)

    query = f"""
        SELECT DISTINCT d.id as device_id, d.display_name
        FROM devices d
        {joins_sql}
        WHERE {where_sql}
        ORDER BY d.display_name
    """

    rows = await db.fetch_all(query, *params)

    if not rows:
        tag_str = " AND ".join(f"{t['key']}={t['value']}" for t in tags)
        return [], f"No devices found matching all tags: {tag_str}"

    return [{"id": row["device_id"], "name": row["display_name"]} for row in rows], None


async def _resolve_asset_devices(
    asset_id: int,
    tenant_id: int | None = None,
) -> tuple[list[dict], str | None]:
    """Get device IDs and names for an asset hierarchy using database function."""
    # First check if the asset exists
    asset = await db.fetch_one(
        "SELECT id, asset_name FROM assets WHERE id = $1",
        asset_id,
    )
    if not asset:
        return [], f"Asset not found: {asset_id}"

    # Get all downstream devices using the database function
    if tenant_id is not None:
        query = """
            SELECT DISTINCT d.id as device_id, d.display_name
            FROM get_all_downstream_assets($1, 'ELECTRICITY') da
            JOIN devices d ON d.asset_id = da.asset_id
            WHERE d.is_active = true AND d.tenant_id = $2
        """
        rows = await db.fetch_all(query, asset_id, tenant_id)
    else:
        query = """
            SELECT DISTINCT d.id as device_id, d.display_name
            FROM get_all_downstream_assets($1, 'ELECTRICITY') da
            JOIN devices d ON d.asset_id = da.asset_id
            WHERE d.is_active = true
        """
        rows = await db.fetch_all(query, asset_id)

    # Also include devices directly attached to this asset
    if tenant_id is not None:
        direct_query = """
            SELECT id as device_id, display_name
            FROM devices
            WHERE asset_id = $1 AND is_active = true AND tenant_id = $2
        """
        direct_rows = await db.fetch_all(direct_query, asset_id, tenant_id)
    else:
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
    tenant: str | None = None,
    tag_key: str | None = None,
    tag_value: str | None = None,
    tags: list[dict] | None = None,
    asset_id: int | None = None,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    breakdown: Literal["none", "device", "daily"] = "none",
    output: OutputMode = "summary",
) -> dict:
    """
    Get aggregated telemetry for a group of devices.

    Group by tag (tag_key + tag_value), multiple tags (AND logic), or asset hierarchy.
    Default: electricity consumption/cost from daily_energy_cost_summary.
    With quantity specified: any WAGE metric from telemetry_15min_agg.
    Auto-filters to devices in the user's tenant.

    Args:
        tenant: Tenant name or code to filter devices (optional)
        tag_key: Tag key for single-tag grouping (e.g., "process", "building")
        tag_value: Tag value to match (e.g., "Waterjet", "Factory A")
        tags: List of tags for multi-tag AND query. Each: {"key": "...", "value": "..."}
              Example: [{"key": "building", "value": "Factory B"},
                        {"key": "equipment_type", "value": "Compressor"}]
        asset_id: Asset ID for hierarchy-based grouping
        quantity_id: Quantity ID for non-electricity metrics
        quantity_search: Quantity search term (e.g., "power", "water flow")
        period: Time period - "7d", "1M", "2025-12", etc.
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        breakdown: Breakdown type - "none", "device", "daily" (for summary output)
        output: Output mode - "summary" (default), "timeseries", "per_device"

    Returns:
        Dictionary with group data based on output mode:
        - summary: Aggregated totals/averages (current behavior)
        - timeseries: Time-aligned rows per device [{time, device_1, device_2, ...}]
        - per_device: Per-device aggregation without time-series
    """
    # Resolve tenant first (if provided)
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Validate grouping parameters
    if tags and len(tags) > 0:
        # Multi-tag AND query
        devices, error = await _resolve_multi_tag_devices(tags, tenant_id)
        group_type = "multi_tag"
        group_label = " AND ".join(f"{t['key']}={t['value']}" for t in tags)
    elif tag_key and tag_value:
        # Single tag query (backward compatible)
        devices, error = await _resolve_tag_devices(tag_key, tag_value, tenant_id)
        group_type = "tag"
        group_label = f"{tag_key}={tag_value}"
    elif asset_id:
        devices, error = await _resolve_asset_devices(asset_id, tenant_id)
        group_type = "asset"
        # Get asset name for label
        asset = await db.fetch_one(
            "SELECT asset_name FROM assets WHERE id = $1",
            asset_id,
        )
        group_label = asset["asset_name"] if asset else f"Asset {asset_id}"
    else:
        return {"error": "Either (tag_key + tag_value), tags array, or asset_id is required"}

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

    # Calculate time range for smart bucketing
    time_range = query_end - query_start

    if use_custom_quantity:
        # Resolve quantity for WAGE telemetry
        resolved_qty_id, qty_info, error = await _resolve_quantity_id(
            quantity_id, quantity_search
        )
        if error:
            return {"error": error}

        # Select optimal bucket for timeseries/per_device output
        selected_bucket = select_group_bucket(time_range, device_count)

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
            output=output,
            selected_bucket=selected_bucket,
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
            output=output,
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
    output: OutputMode = "summary",
) -> dict:
    """Get electricity consumption/cost summary from daily_energy_cost_summary.

    Note: Electricity data uses daily_energy_cost_summary which is pre-aggregated daily.
    timeseries/per_device output modes will be implemented in a future update.
    """
    # TODO: Implement timeseries/per_device for electricity (uses daily buckets)
    if output != "summary":
        logger.warning(f"output={output} not yet implemented for electricity, using summary")
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


async def _get_telemetry_timeseries(
    device_ids: list[int],
    device_names: list[str],
    quantity_id: int,
    quantity_info: dict,
    query_start: datetime,
    query_end: datetime,
    selected_bucket: str,
) -> list[dict]:
    """
    Get time-series data pivoted into time-aligned rows.

    Returns rows like: [{time: "2025-01-01T00:00", device_1: 100, device_2: 150, ...}]
    where device keys are display names.

    Args:
        device_ids: List of device IDs
        device_names: List of device names (parallel to device_ids)
        quantity_id: Quantity ID
        quantity_info: Quantity metadata dict
        query_start: Start datetime
        query_end: End datetime
        selected_bucket: Bucket size string (e.g., "1hour", "1day")

    Returns:
        List of time-aligned dicts with device values as columns
    """
    # Convert bucket string to timedelta
    bucket_interval = timedelta(minutes=BUCKET_MINUTES.get(selected_bucket, 60))

    # Determine query method based on quantity type
    is_instantaneous = is_instantaneous_quantity(quantity_info)

    if is_instantaneous:
        # Use nearest-value sampling for instantaneous quantities
        rows = await _query_nearest_value_timeseries(
            device_ids=device_ids,
            quantity_id=quantity_id,
            query_start=query_start,
            query_end=query_end,
            bucket_interval=bucket_interval,
        )
    else:
        # Use AVG/SUM for cumulative quantities
        is_cumulative = not is_instantaneous
        rows = await _query_avg_value_timeseries(
            device_ids=device_ids,
            quantity_id=quantity_id,
            query_start=query_start,
            query_end=query_end,
            bucket_interval=bucket_interval,
            is_cumulative=is_cumulative,
        )

    if not rows:
        return []

    # Build device_id -> name mapping
    id_to_name = dict(zip(device_ids, device_names))

    # Pivot: group by time_bucket, create dict with device names as keys
    time_data: dict[datetime, dict] = {}

    for row in rows:
        time_bucket = row["time_bucket"]
        device_id = row["device_id"]
        value = row["value"]

        # Get device name (use name from our list, fallback to query result)
        device_name = id_to_name.get(device_id, row.get("device_name", f"device_{device_id}"))

        if time_bucket not in time_data:
            time_data[time_bucket] = {"time": time_bucket.isoformat()}

        time_data[time_bucket][device_name] = value

    # Sort by time and return as list
    sorted_times = sorted(time_data.keys())
    return [time_data[t] for t in sorted_times]


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
    output: OutputMode = "summary",
    selected_bucket: str = "1hour",
) -> dict:
    """Get WAGE telemetry summary from telemetry_15min_agg.

    Args:
        output: Output mode - "summary", "timeseries", "per_device"
        selected_bucket: Bucket size for timeseries output (from select_group_bucket)

    For instantaneous quantities (voltage, power, current):
    - Auto-enables device breakdown when breakdown="none" and multiple devices
    - Skips percentage calculation (nonsensical for instantaneous values)
    - Adds min/max with device attribution in summary
    """
    # Check if quantity is instantaneous
    is_instantaneous = is_instantaneous_quantity(quantity_info)

    # For instantaneous quantities with multiple devices: auto-enable device breakdown
    # A single average across all devices is meaningless for voltage/power
    if is_instantaneous and breakdown == "none" and device_count > 1 and output == "summary":
        breakdown = "device"

    # Handle timeseries output mode
    if output == "timeseries":
        timeseries = await _get_telemetry_timeseries(
            device_ids=device_ids,
            device_names=device_names,
            quantity_id=quantity_id,
            quantity_info=quantity_info,
            query_start=query_start,
            query_end=query_end,
            selected_bucket=selected_bucket,
        )

        unit = quantity_info.get("unit") or ""
        agg_method = (quantity_info.get("aggregation_method") or "avg").lower()
        is_cumulative = agg_method in CUMULATIVE_METHODS

        return {
            "group": {
                "type": group_type,
                "label": group_label,
                "result_type": result_type,
                "device_count": device_count,
                "devices": device_names,
            },
            "quantity": {
                "id": quantity_id,
                "name": quantity_info["quantity_name"],
                "unit": unit,
                "aggregation": "sum" if is_cumulative else "nearest",
            },
            "timeseries": {
                "bucket": selected_bucket,
                "period": f"{start_str} to {end_str}",
                "row_count": len(timeseries),
                "data": timeseries,
            },
        }
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

    # For instantaneous quantities, find which devices had min/max values
    min_device = None
    max_device = None
    if is_instantaneous and min_value is not None and max_value is not None and device_count > 1:
        # Query to find device with min value
        min_device_query = f"""
            SELECT d.display_name, t.aggregated_value, t.bucket
            FROM telemetry_15min_agg t
            JOIN devices d ON t.device_id = d.id
            WHERE t.quantity_id = $1
              AND t.bucket >= $2
              AND t.bucket < $3
              AND t.device_id IN ({device_placeholders})
              AND t.aggregated_value = $4
            LIMIT 1
        """
        min_row = await db.fetch_one(
            min_device_query,
            quantity_id,
            query_start,
            query_end,
            *device_ids,
            min_value,
        )
        if min_row:
            min_device = min_row["display_name"]

        # Query to find device with max value
        max_device_query = f"""
            SELECT d.display_name, t.aggregated_value, t.bucket
            FROM telemetry_15min_agg t
            JOIN devices d ON t.device_id = d.id
            WHERE t.quantity_id = $1
              AND t.bucket >= $2
              AND t.bucket < $3
              AND t.device_id IN ({device_placeholders})
              AND t.aggregated_value = $4
            LIMIT 1
        """
        max_row = await db.fetch_one(
            max_device_query,
            quantity_id,
            query_start,
            query_end,
            *device_ids,
            max_value,
        )
        if max_row:
            max_device = max_row["display_name"]

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
            "is_instantaneous": is_instantaneous,
        },
        "summary": {
            f"{agg_label}_value": round(agg_value, 2),
            "min_value": round(min_value, 2) if min_value else None,
            "max_value": round(max_value, 2) if max_value else None,
            "min_device": min_device,
            "max_device": max_device,
            "unit": unit,
            "period": f"{start_str} to {end_str}",
            "days_with_data": days_with_data,
            "data_points": data_points,
        },
    }

    if breakdown == "device":
        breakdown_data = await _get_telemetry_device_breakdown(
            device_ids, quantity_id, query_start, query_end, agg_value,
            is_cumulative, is_instantaneous
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
    is_instantaneous: bool = False,
) -> list[dict]:
    """Get per-device breakdown for telemetry data.

    For instantaneous quantities (voltage, power):
    - Shows avg value per device with min/max
    - Skips percentage (nonsensical for instantaneous values)

    For cumulative quantities (energy):
    - Shows total per device with percentage of group total
    """
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

        item = {
            "device": row.get("device"),
            "device_id": row.get("device_id"),
            "value": round(agg_value, 2),
            "min": round(min_val, 2) if min_val else None,
            "max": round(max_val, 2) if max_val else None,
        }

        # Only add percentage for cumulative quantities (energy)
        # Percentage is meaningless for instantaneous quantities (voltage, power)
        if not is_instantaneous:
            pct = 100 * agg_value / total_value if total_value > 0 else 0
            item["percentage"] = round(pct, 1)

        breakdown.append(item)

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


def _format_timeseries_response(
    result: dict,
    group: dict,
    result_type: str,
    devices: list[str],
) -> str:
    """Format timeseries output for human-readable display."""
    qty = result["quantity"]
    ts = result["timeseries"]
    data = ts.get("data", [])

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
        f"**Quantity**: {qty['name']} ({qty['unit']})",
        f"**Period**: {ts['period']}",
        f"**Bucket**: {ts['bucket']}",
        f"**Rows**: {ts['row_count']}",
        "",
        "### Time Series Data",
        "",
    ]

    if not data:
        lines.append("_No data available for this period._")
        return "\n".join(lines)

    unit = qty.get("unit", "")

    # Create table header from device names
    device_cols = [d for d in devices if d != "time"]

    # Build markdown table
    header_row = "| Time | " + " | ".join(device_cols) + " |"
    separator = "|------|" + "|".join(["------"] * len(device_cols)) + "|"
    lines.extend([header_row, separator])

    # Limit rows for display (show first 20, indicate if more)
    display_limit = 20
    for row in data[:display_limit]:
        time_str = row.get("time", "?")
        # Truncate ISO time for readability
        if "T" in time_str:
            time_str = time_str.replace("T", " ")[:16]

        values = []
        for device in device_cols:
            val = row.get(device)
            if val is not None:
                values.append(f"{val:,.2f}")
            else:
                values.append("-")

        row_str = f"| {time_str} | " + " | ".join(values) + " |"
        lines.append(row_str)

    if len(data) > display_limit:
        lines.append(f"| ... | {len(data) - display_limit} more rows ... |")

    lines.append("")
    lines.append(f"_Values in {unit}_")

    return "\n".join(lines)


def format_group_telemetry_response(result: dict) -> str:
    """Format get_group_telemetry response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    group = result["group"]
    result_type = group.get("result_type", "aggregated_group")
    devices = group.get("devices", [])

    # Handle timeseries output format
    if "timeseries" in result:
        return _format_timeseries_response(result, group, result_type, devices)

    summary = result["summary"]

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
        is_instantaneous = qty.get("is_instantaneous", False)

        # Get the aggregated value key (total_value or average_value)
        agg_key = f"{agg}_value"
        agg_value = summary.get(agg_key, 0)

        lines.append(f"- **{agg.title()}**: {agg_value:,.2f} {unit}")

        # Show min/max with device attribution for instantaneous quantities
        if summary.get("min_value") is not None:
            min_line = f"- **Min**: {summary['min_value']:,.2f} {unit}"
            if is_instantaneous and summary.get("min_device"):
                min_line += f" ({summary['min_device']})"
            lines.append(min_line)

        if summary.get("max_value") is not None:
            max_line = f"- **Max**: {summary['max_value']:,.2f} {unit}"
            if is_instantaneous and summary.get("max_device"):
                max_line += f" ({summary['max_device']})"
            lines.append(max_line)

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
            is_instantaneous = qty.get("is_instantaneous", False)

            if "device" in first:
                for item in breakdown:
                    device = item.get("device", "?")
                    value = item["value"]
                    min_val = item.get("min")
                    max_val = item.get("max")

                    if is_instantaneous:
                        # For instantaneous: show avg with min/max range, no percentage
                        if min_val is not None and max_val is not None:
                            lines.append(
                                f"- **{device}**: avg {value:,.2f} {unit} "
                                f"(range: {min_val:,.2f} - {max_val:,.2f})"
                            )
                        else:
                            lines.append(f"- **{device}**: {value:,.2f} {unit}")
                    else:
                        # For cumulative: show value with percentage
                        pct = item.get("percentage", 0)
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
    tenant: str | None = None,
    groups: list[dict] | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
) -> dict:
    """
    Compare electricity consumption across multiple groups.
    Auto-filters to devices in the user's tenant.

    Args:
        tenant: Tenant name or code to filter devices (optional)
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

    # Resolve tenant first (if provided)
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

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

        # Resolve devices with tenant filter
        if tag_key and tag_value:
            devices, error = await _resolve_tag_devices(tag_key, tag_value, tenant_id)
            group_label = f"{tag_key}={tag_value}"
        elif asset_id:
            devices, error = await _resolve_asset_devices(asset_id, tenant_id)
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
