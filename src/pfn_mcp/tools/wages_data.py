"""Unified WAGES Data Tool.

Combines functionality from:
- get_electricity_cost (energy consumption and cost)
- get_group_telemetry (tag-based and asset-based grouping)
- get_peak_analysis (peak/max value finding)

Into a single tool: get_wages_data

WAGES = Water, Air, Gas, Electricity, Steam
"""

from __future__ import annotations

import logging
from datetime import timedelta
from typing import Literal

from pfn_mcp import db
from pfn_mcp.tools.electricity_cost import parse_period
from pfn_mcp.tools.formula_parser import (
    FormulaParseError,
    calculate_formula_result,
    get_all_device_ids,
    parse_formula,
)
from pfn_mcp.tools.resolve import resolve_tenant

logger = logging.getLogger(__name__)

# Type aliases
ScopeType = Literal[
    "device", "tag", "multi_tag", "asset", "aggregation", "formula", "tenant"
]
AggMethodType = Literal["sum", "avg", "max", "min"]
BreakdownType = Literal["none", "device", "daily", "shift", "rate", "shift_rate"]
OutputType = Literal["summary", "timeseries"]

# Constants
ACTIVE_ENERGY_QTY_ID = 124
CUMULATIVE_QUANTITY_IDS = {62, 89, 96, 124, 130, 131, 481}

BUCKET_MINUTES = {
    "15min": 15,
    "1hour": 60,
    "4hour": 240,
    "1day": 1440,
    "1week": 10080,
}


async def get_wages_data(
    # Scope parameters (use ONE)
    device_id: int | None = None,
    device_name: str | None = None,
    tag_key: str | None = None,
    tag_value: str | None = None,
    tags: list[dict] | None = None,
    asset_id: int | None = None,
    aggregation: str | None = None,
    formula: str | None = None,
    # Quantity parameters
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    # Time parameters
    tenant: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    # Aggregation method
    agg_method: AggMethodType | None = None,
    # Output options
    breakdown: BreakdownType = "none",
    output: OutputType = "summary",
) -> dict:
    """Unified WAGES telemetry query tool.

    Handles single devices, tag-based groups, asset hierarchy, or formula-based
    aggregations for any WAGES (Water, Air, Gas, Electricity, Steam) metric.

    Args:
        device_id: Single device ID (exact)
        device_name: Single device name (fuzzy match)
        tag_key: Tag key for group query
        tag_value: Tag value to match
        tags: Multi-tag AND query [{"key": "...", "value": "..."}]
        asset_id: Asset ID for hierarchy-based grouping
        aggregation: Named aggregation from meter_aggregations table
        formula: Inline formula (e.g., "94+11+27", "94-84")
        quantity_id: Quantity ID (omit for energy/cost)
        quantity_search: Quantity search term (omit for energy/cost)
        tenant: Tenant name/code (required for aggregation lookup)
        period: Time period (7d, 1M, 2025-01, etc.)
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        agg_method: Aggregation method (sum, avg, max, min)
        breakdown: Breakdown type (none, device, daily, shift, rate, shift_rate)
        output: Output format (summary, timeseries)

    Returns:
        Result dict with summary, optional breakdown, and metadata
    """
    # Resolve scope
    scope_result = await _resolve_scope(
        device_id=device_id,
        device_name=device_name,
        tag_key=tag_key,
        tag_value=tag_value,
        tags=tags,
        asset_id=asset_id,
        aggregation=aggregation,
        formula=formula,
        tenant=tenant,
    )

    if "error" in scope_result:
        return scope_result

    scope_type = scope_result["scope_type"]
    device_ids = scope_result["device_ids"]
    scope_info = scope_result["scope_info"]
    tenant_id = scope_result.get("tenant_id")
    formula_terms = scope_result.get("formula_terms")

    # Parse time period
    period_result = parse_period(period, start_date, end_date)
    if period_result[0] is None:
        return {"error": period_result[1]}

    query_start, query_end = period_result
    # Build period string for display
    if start_date and end_date:
        period_str = f"{start_date} to {end_date}"
    elif start_date:
        period_str = f"{start_date} to now"
    else:
        period_str = period or "7d"

    # Determine data source and query
    is_energy_cost = quantity_id is None and quantity_search is None

    if is_energy_cost:
        # Use daily_energy_cost_summary for energy/cost queries
        return await _query_energy_cost(
            device_ids=device_ids,
            tenant_id=tenant_id,
            query_start=query_start,
            query_end=query_end,
            period_str=period_str,
            breakdown=breakdown,
            scope_type=scope_type,
            scope_info=scope_info,
            formula_terms=formula_terms,
        )
    else:
        # Use telemetry_15min_agg for other WAGES metrics
        return await _query_telemetry(
            device_ids=device_ids,
            tenant_id=tenant_id,
            quantity_id=quantity_id,
            quantity_search=quantity_search,
            query_start=query_start,
            query_end=query_end,
            period_str=period_str,
            agg_method=agg_method,
            breakdown=breakdown,
            output=output,
            scope_type=scope_type,
            scope_info=scope_info,
            formula_terms=formula_terms,
        )


async def _resolve_scope(
    device_id: int | None,
    device_name: str | None,
    tag_key: str | None,
    tag_value: str | None,
    tags: list[dict] | None,
    asset_id: int | None,
    aggregation: str | None,
    formula: str | None,
    tenant: str | None,
) -> dict:
    """Resolve query scope to list of device IDs.

    Returns:
        dict with keys:
        - scope_type: ScopeType
        - device_ids: list[int]
        - scope_info: dict with scope-specific metadata
        - tenant_id: int | None
        - formula_terms: list[FormulaTerm] | None (for formula scope)
        OR
        - error: str
    """
    # Count how many scope types are provided
    scope_count = sum(
        [
            device_id is not None,
            device_name is not None,
            tag_key is not None or tag_value is not None,
            tags is not None,
            asset_id is not None,
            aggregation is not None,
            formula is not None,
        ]
    )

    if scope_count == 0:
        return {
            "error": "No scope provided. Use one of: device_id, device_name, "
            "tag_key+tag_value, tags, asset_id, aggregation, or formula"
        }

    if scope_count > 1:
        # Special case: tag_key and tag_value together
        if (tag_key is not None or tag_value is not None) and scope_count == 1:
            pass  # Valid
        else:
            return {
                "error": "Multiple scopes provided. Use only ONE of: device_id, "
                "device_name, tag_key+tag_value, tags, asset_id, aggregation, formula"
            }

    # Resolve tenant if provided
    tenant_id = None
    tenant_info = None
    if tenant:
        tenant_id, tenant_info, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Handle each scope type
    if device_id is not None:
        return await _resolve_device_scope(device_id, tenant_id)

    if device_name is not None:
        return await _resolve_device_name_scope(device_name, tenant_id)

    if tag_key is not None or tag_value is not None:
        if tag_key is None or tag_value is None:
            return {"error": "Both tag_key and tag_value are required for tag queries"}
        return await _resolve_tag_scope(tag_key, tag_value, tenant_id)

    if tags is not None:
        return await _resolve_multi_tag_scope(tags, tenant_id)

    if asset_id is not None:
        return await _resolve_asset_scope(asset_id, tenant_id)

    if aggregation is not None:
        if tenant_id is None:
            return {"error": "tenant is required for aggregation queries"}
        return await _resolve_aggregation_scope(aggregation, tenant_id)

    if formula is not None:
        return await _resolve_formula_scope(formula, tenant_id)

    return {"error": "Unknown scope type"}


async def _resolve_device_scope(
    device_id: int, tenant_id: int | None
) -> dict:
    """Resolve single device by ID."""
    query = """
        SELECT id, display_name, tenant_id
        FROM devices
        WHERE id = $1 AND is_active = true
    """
    params = [device_id]

    if tenant_id is not None:
        query += " AND tenant_id = $2"
        params.append(tenant_id)

    device = await db.fetch_one(query, *params)
    if not device:
        return {"error": f"Device ID {device_id} not found"}

    return {
        "scope_type": "device",
        "device_ids": [device["id"]],
        "scope_info": {"device_name": device["display_name"]},
        "tenant_id": device["tenant_id"],
    }


async def _resolve_device_name_scope(
    device_name: str, tenant_id: int | None
) -> dict:
    """Resolve single device by name (fuzzy match)."""
    base_query = """
        SELECT id, display_name, tenant_id,
               CASE
                   WHEN LOWER(display_name) = LOWER($1) THEN 1
                   WHEN LOWER(display_name) LIKE LOWER($1) || '%' THEN 2
                   WHEN LOWER(display_name) LIKE '%' || LOWER($1) || '%' THEN 3
                   ELSE 4
               END as match_rank
        FROM devices
        WHERE is_active = true
          AND (
              LOWER(display_name) = LOWER($1)
              OR LOWER(display_name) LIKE '%' || LOWER($1) || '%'
          )
    """
    params = [device_name]

    if tenant_id is not None:
        base_query += " AND tenant_id = $2"
        params.append(tenant_id)

    base_query += " ORDER BY match_rank, display_name LIMIT 1"

    device = await db.fetch_one(base_query, *params)
    if not device:
        return {"error": f"No device found matching '{device_name}'"}

    return {
        "scope_type": "device",
        "device_ids": [device["id"]],
        "scope_info": {"device_name": device["display_name"]},
        "tenant_id": device["tenant_id"],
    }


async def _resolve_tag_scope(
    tag_key: str, tag_value: str, tenant_id: int | None
) -> dict:
    """Resolve devices by tag key/value."""
    query = """
        SELECT d.id, d.display_name
        FROM devices d
        JOIN device_tags dt ON d.id = dt.device_id
        WHERE dt.tag_key = $1 AND dt.tag_value = $2
          AND dt.is_active = true AND d.is_active = true
    """
    params = [tag_key, tag_value]

    if tenant_id is not None:
        query += " AND d.tenant_id = $3"
        params.append(tenant_id)

    query += " ORDER BY d.display_name"

    devices = await db.fetch_all(query, *params)
    if not devices:
        return {"error": f"No devices found with tag {tag_key}={tag_value}"}

    return {
        "scope_type": "tag",
        "device_ids": [d["id"] for d in devices],
        "scope_info": {
            "tag_key": tag_key,
            "tag_value": tag_value,
            "device_count": len(devices),
            "devices": [{"id": d["id"], "name": d["display_name"]} for d in devices],
        },
        "tenant_id": tenant_id,
    }


async def _resolve_multi_tag_scope(
    tags: list[dict], tenant_id: int | None
) -> dict:
    """Resolve devices by multiple tags (AND logic)."""
    if not tags:
        return {"error": "tags list cannot be empty"}

    # Build query with all tag conditions
    conditions = []
    params = []
    param_idx = 1

    for tag in tags:
        key = tag.get("key")
        value = tag.get("value")
        if not key or not value:
            return {"error": "Each tag must have 'key' and 'value'"}

        conditions.append(f"""
            EXISTS (
                SELECT 1 FROM device_tags dt
                WHERE dt.device_id = d.id
                  AND dt.tag_key = ${param_idx}
                  AND dt.tag_value = ${param_idx + 1}
                  AND dt.is_active = true
            )
        """)
        params.extend([key, value])
        param_idx += 2

    query = f"""
        SELECT d.id, d.display_name
        FROM devices d
        WHERE d.is_active = true
          AND {' AND '.join(conditions)}
    """

    if tenant_id is not None:
        query += f" AND d.tenant_id = ${param_idx}"
        params.append(tenant_id)

    query += " ORDER BY d.display_name"

    devices = await db.fetch_all(query, *params)
    if not devices:
        tag_str = ", ".join(f"{t['key']}={t['value']}" for t in tags)
        return {"error": f"No devices found with all tags: {tag_str}"}

    return {
        "scope_type": "multi_tag",
        "device_ids": [d["id"] for d in devices],
        "scope_info": {
            "tags": tags,
            "device_count": len(devices),
            "devices": [{"id": d["id"], "name": d["display_name"]} for d in devices],
        },
        "tenant_id": tenant_id,
    }


async def _resolve_asset_scope(
    asset_id: int, tenant_id: int | None
) -> dict:
    """Resolve devices by asset hierarchy."""
    # Use database function to get all downstream assets
    query = """
        SELECT DISTINCT d.id, d.display_name
        FROM devices d
        WHERE d.is_active = true
          AND (
              d.asset_id IN (
                  SELECT id FROM get_all_downstream_assets($1, 'ELECTRICITY')
              )
              OR d.asset_id = $1
          )
    """
    params = [asset_id]

    if tenant_id is not None:
        query += " AND d.tenant_id = $2"
        params.append(tenant_id)

    query += " ORDER BY d.display_name"

    devices = await db.fetch_all(query, *params)
    if not devices:
        return {"error": f"No devices found under asset ID {asset_id}"}

    # Get asset info
    asset = await db.fetch_one(
        "SELECT id, name, utility_path FROM assets WHERE id = $1",
        asset_id,
    )

    return {
        "scope_type": "asset",
        "device_ids": [d["id"] for d in devices],
        "scope_info": {
            "asset_id": asset_id,
            "asset_name": asset["name"] if asset else f"Asset {asset_id}",
            "device_count": len(devices),
            "devices": [{"id": d["id"], "name": d["display_name"]} for d in devices],
        },
        "tenant_id": tenant_id,
    }


async def _resolve_aggregation_scope(
    aggregation: str, tenant_id: int
) -> dict:
    """Resolve named aggregation from meter_aggregations table."""
    agg = await db.fetch_one(
        """
        SELECT id, name, aggregation_type, formula, description
        FROM meter_aggregations
        WHERE tenant_id = $1 AND name = $2 AND is_active = true
        """,
        tenant_id,
        aggregation,
    )

    if not agg:
        # List available aggregations
        available = await db.fetch_all(
            """
            SELECT name, aggregation_type, description
            FROM meter_aggregations
            WHERE tenant_id = $1 AND is_active = true
            ORDER BY aggregation_type, name
            """,
            tenant_id,
        )
        names = [a["name"] for a in available]
        return {
            "error": f"Aggregation '{aggregation}' not found. "
            f"Available: {', '.join(names) if names else 'none'}"
        }

    # Parse the formula and get device IDs
    try:
        terms = parse_formula(agg["formula"])
    except FormulaParseError as e:
        return {"error": f"Invalid formula in aggregation '{aggregation}': {e}"}

    device_ids = get_all_device_ids(terms)

    # Validate devices exist
    placeholders = ", ".join(f"${i+1}" for i in range(len(device_ids)))
    devices = await db.fetch_all(
        f"""
        SELECT id, display_name FROM devices
        WHERE id IN ({placeholders}) AND is_active = true
        ORDER BY display_name
        """,
        *device_ids,
    )

    if len(devices) != len(device_ids):
        found_ids = {d["id"] for d in devices}
        missing = set(device_ids) - found_ids
        return {
            "error": f"Aggregation '{aggregation}' references missing devices: {sorted(missing)}"
        }

    return {
        "scope_type": "aggregation",
        "device_ids": device_ids,
        "scope_info": {
            "aggregation_name": agg["name"],
            "aggregation_type": agg["aggregation_type"],
            "formula": agg["formula"],
            "description": agg["description"],
            "device_count": len(devices),
            "devices": [{"id": d["id"], "name": d["display_name"]} for d in devices],
        },
        "tenant_id": tenant_id,
        "formula_terms": terms,
    }


async def _resolve_formula_scope(
    formula: str, tenant_id: int | None
) -> dict:
    """Resolve inline formula."""
    try:
        terms = parse_formula(formula)
    except FormulaParseError as e:
        return {"error": f"Invalid formula: {e}"}

    device_ids = get_all_device_ids(terms)

    # Validate devices exist
    placeholders = ", ".join(f"${i+1}" for i in range(len(device_ids)))
    param_idx = len(device_ids) + 1

    query = f"""
        SELECT id, display_name, tenant_id FROM devices
        WHERE id IN ({placeholders}) AND is_active = true
    """
    params = list(device_ids)

    if tenant_id is not None:
        query += f" AND tenant_id = ${param_idx}"
        params.append(tenant_id)

    devices = await db.fetch_all(query, *params)

    if len(devices) != len(device_ids):
        found_ids = {d["id"] for d in devices}
        missing = set(device_ids) - found_ids
        return {"error": f"Formula references missing devices: {sorted(missing)}"}

    # Infer tenant from devices if not provided
    if tenant_id is None and devices:
        tenant_id = devices[0]["tenant_id"]

    return {
        "scope_type": "formula",
        "device_ids": device_ids,
        "scope_info": {
            "formula": formula,
            "device_count": len(devices),
            "devices": [{"id": d["id"], "name": d["display_name"]} for d in devices],
        },
        "tenant_id": tenant_id,
        "formula_terms": terms,
    }


async def _query_energy_cost(
    device_ids: list[int],
    tenant_id: int | None,
    query_start,
    query_end,
    period_str: str,
    breakdown: BreakdownType,
    scope_type: ScopeType,
    scope_info: dict,
    formula_terms=None,
) -> dict:
    """Query energy consumption and cost from daily_energy_cost_summary."""
    # Build device filter
    device_placeholders = ", ".join(f"${i+3}" for i in range(len(device_ids)))

    # Get per-device totals
    device_query = f"""
        SELECT
            device_id,
            SUM(total_consumption) as consumption,
            SUM(total_cost) as cost
        FROM daily_energy_cost_summary
        WHERE daily_bucket >= $1
          AND daily_bucket < $2
          AND device_id IN ({device_placeholders})
        GROUP BY device_id
    """

    rows = await db.fetch_all(device_query, query_start, query_end, *device_ids)

    if not rows:
        return {
            "error": "No energy data found for the specified period",
            "period": period_str,
            "scope": scope_info,
        }

    # Build values dict for formula calculation
    device_values = {row["device_id"]: float(row["consumption"] or 0) for row in rows}
    device_costs = {row["device_id"]: float(row["cost"] or 0) for row in rows}

    # Calculate totals based on scope type
    if formula_terms is not None:
        # Use formula calculation (supports subtraction)
        total_consumption = calculate_formula_result(formula_terms, device_values)
        total_cost = calculate_formula_result(formula_terms, device_costs)
    else:
        # Simple sum for non-formula scopes
        total_consumption = sum(device_values.values())
        total_cost = sum(device_costs.values())

    # Get day count
    days_query = f"""
        SELECT COUNT(DISTINCT daily_bucket) as days
        FROM daily_energy_cost_summary
        WHERE daily_bucket >= $1
          AND daily_bucket < $2
          AND device_id IN ({device_placeholders})
    """
    days_result = await db.fetch_one(days_query, query_start, query_end, *device_ids)
    days_with_data = days_result["days"] if days_result else 0

    # Calculate average rate
    avg_rate = total_cost / total_consumption if total_consumption > 0 else 0

    result = {
        "summary": {
            "total_consumption_kwh": round(total_consumption, 2),
            "total_cost_rp": round(total_cost, 2),
            "avg_rate_per_kwh": round(avg_rate, 2),
            "period": period_str,
            "days_with_data": days_with_data,
        },
        "scope_type": scope_type,
        "scope": scope_info,
    }

    # Add breakdown if requested
    if breakdown != "none":
        breakdown_data = await _get_energy_breakdown(
            device_ids,
            query_start,
            query_end,
            breakdown,
            total_consumption,
            total_cost,
            formula_terms,
        )
        result["breakdown"] = breakdown_data
        result["breakdown_type"] = breakdown

    return result


async def _get_energy_breakdown(
    device_ids: list[int],
    query_start,
    query_end,
    breakdown: BreakdownType,
    total_consumption: float,
    total_cost: float,
    formula_terms=None,
) -> list[dict]:
    """Get energy breakdown by device, daily, shift, rate, or shift_rate."""
    device_placeholders = ", ".join(f"${i+3}" for i in range(len(device_ids)))

    if breakdown == "device":
        query = f"""
            SELECT
                d.id as device_id,
                d.display_name as device_name,
                SUM(e.total_consumption) as consumption,
                SUM(e.total_cost) as cost
            FROM daily_energy_cost_summary e
            JOIN devices d ON d.id = e.device_id
            WHERE e.daily_bucket >= $1
              AND e.daily_bucket < $2
              AND e.device_id IN ({device_placeholders})
            GROUP BY d.id, d.display_name
            ORDER BY consumption DESC
        """
        rows = await db.fetch_all(query, query_start, query_end, *device_ids)

        return [
            {
                "device_id": row["device_id"],
                "device_name": row["device_name"],
                "consumption_kwh": round(float(row["consumption"] or 0), 2),
                "cost_rp": round(float(row["cost"] or 0), 2),
                "percentage": round(
                    100 * float(row["consumption"] or 0) / total_consumption, 1
                )
                if total_consumption > 0
                else 0,
            }
            for row in rows
        ]

    elif breakdown == "daily":
        query = f"""
            SELECT
                daily_bucket::date as date,
                SUM(total_consumption) as consumption,
                SUM(total_cost) as cost
            FROM daily_energy_cost_summary
            WHERE daily_bucket >= $1
              AND daily_bucket < $2
              AND device_id IN ({device_placeholders})
            GROUP BY daily_bucket::date
            ORDER BY date
        """
        rows = await db.fetch_all(query, query_start, query_end, *device_ids)

        return [
            {
                "date": str(row["date"]),
                "consumption_kwh": round(float(row["consumption"] or 0), 2),
                "cost_rp": round(float(row["cost"] or 0), 2),
            }
            for row in rows
        ]

    elif breakdown == "shift":
        query = f"""
            SELECT
                shift_period,
                SUM(total_consumption) as consumption,
                SUM(total_cost) as cost
            FROM daily_energy_cost_summary
            WHERE daily_bucket >= $1
              AND daily_bucket < $2
              AND device_id IN ({device_placeholders})
            GROUP BY shift_period
            ORDER BY shift_period
        """
        rows = await db.fetch_all(query, query_start, query_end, *device_ids)

        return [
            {
                "shift": row["shift_period"],
                "consumption_kwh": round(float(row["consumption"] or 0), 2),
                "cost_rp": round(float(row["cost"] or 0), 2),
                "percentage": round(
                    100 * float(row["consumption"] or 0) / total_consumption, 1
                )
                if total_consumption > 0
                else 0,
            }
            for row in rows
        ]

    elif breakdown == "rate":
        query = f"""
            SELECT
                rate_code,
                SUM(total_consumption) as consumption,
                SUM(total_cost) as cost
            FROM daily_energy_cost_summary
            WHERE daily_bucket >= $1
              AND daily_bucket < $2
              AND device_id IN ({device_placeholders})
            GROUP BY rate_code
            ORDER BY rate_code
        """
        rows = await db.fetch_all(query, query_start, query_end, *device_ids)

        return [
            {
                "rate": row["rate_code"],
                "consumption_kwh": round(float(row["consumption"] or 0), 2),
                "cost_rp": round(float(row["cost"] or 0), 2),
                "percentage": round(
                    100 * float(row["consumption"] or 0) / total_consumption, 1
                )
                if total_consumption > 0
                else 0,
            }
            for row in rows
        ]

    elif breakdown == "shift_rate":
        query = f"""
            SELECT
                shift_period,
                rate_code,
                SUM(total_consumption) as consumption,
                SUM(total_cost) as cost
            FROM daily_energy_cost_summary
            WHERE daily_bucket >= $1
              AND daily_bucket < $2
              AND device_id IN ({device_placeholders})
            GROUP BY shift_period, rate_code
            ORDER BY shift_period, rate_code
        """
        rows = await db.fetch_all(query, query_start, query_end, *device_ids)

        return [
            {
                "shift": row["shift_period"],
                "rate": row["rate_code"],
                "consumption_kwh": round(float(row["consumption"] or 0), 2),
                "cost_rp": round(float(row["cost"] or 0), 2),
            }
            for row in rows
        ]

    return []


async def _query_telemetry(
    device_ids: list[int],
    tenant_id: int | None,
    quantity_id: int | None,
    quantity_search: str | None,
    query_start,
    query_end,
    period_str: str,
    agg_method: AggMethodType | None,
    breakdown: BreakdownType,
    output: OutputType,
    scope_type: ScopeType,
    scope_info: dict,
    formula_terms=None,
) -> dict:
    """Query telemetry data from telemetry_15min_agg."""
    # Resolve quantity
    qty_id, qty_info, error = await _resolve_quantity(quantity_id, quantity_search)
    if error:
        return {"error": error}

    # Determine aggregation method
    is_cumulative = qty_id in CUMULATIVE_QUANTITY_IDS
    if agg_method is None:
        agg_method = "sum" if is_cumulative else "avg"

    # Select bucket size based on time range and device count
    time_range = query_end - query_start
    bucket = _select_bucket(time_range, len(device_ids))

    # Build device filter
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    # Map agg_method to SQL function
    sql_agg = {
        "sum": "SUM(aggregated_value)",
        "avg": "AVG(aggregated_value)",
        "max": "MAX(aggregated_value)",
        "min": "MIN(aggregated_value)",
    }.get(agg_method, "SUM(aggregated_value)")

    # Query per-device aggregates for formula support
    device_query = f"""
        SELECT
            device_id,
            {sql_agg} as value,
            SUM(sample_count) as samples
        FROM telemetry_15min_agg
        WHERE bucket >= $1
          AND bucket < $2
          AND quantity_id = $3
          AND device_id IN ({device_placeholders})
        GROUP BY device_id
    """

    rows = await db.fetch_all(device_query, query_start, query_end, qty_id, *device_ids)

    if not rows:
        return {
            "error": f"No telemetry data found for quantity '{qty_info['name']}'",
            "period": period_str,
            "scope": scope_info,
        }

    # Build values dict
    device_values = {row["device_id"]: float(row["value"] or 0) for row in rows}

    # Calculate total based on scope type
    if formula_terms is not None and agg_method == "sum":
        # Use formula calculation for sum (supports subtraction)
        total_value = calculate_formula_result(formula_terms, device_values)
    else:
        # For avg/max/min, formula doesn't make sense - just aggregate
        all_values = list(device_values.values())
        if agg_method == "sum":
            total_value = sum(all_values)
        elif agg_method == "avg":
            total_value = sum(all_values) / len(all_values) if all_values else 0
        elif agg_method == "max":
            total_value = max(all_values) if all_values else 0
        elif agg_method == "min":
            total_value = min(all_values) if all_values else 0
        else:
            total_value = sum(all_values)

    result = {
        "summary": {
            "value": round(total_value, 3),
            "unit": qty_info.get("unit", ""),
            "quantity": qty_info.get("name", f"quantity_{qty_id}"),
            "agg_method": agg_method,
            "period": period_str,
            "bucket": bucket,
        },
        "scope_type": scope_type,
        "scope": scope_info,
    }

    # Add peak info for max queries
    if agg_method == "max":
        peak_info = await _get_peak_info(
            device_ids, qty_id, query_start, query_end, total_value
        )
        if peak_info:
            result["peak"] = peak_info

    # Add breakdown if requested
    if breakdown == "device" and len(device_ids) > 1:
        breakdown_data = [
            {
                "device_id": row["device_id"],
                "device_name": next(
                    (d["name"] for d in scope_info.get("devices", [])
                     if d["id"] == row["device_id"]),
                    f"Device {row['device_id']}",
                ),
                "value": round(float(row["value"] or 0), 3),
                "samples": row["samples"],
            }
            for row in sorted(rows, key=lambda r: r["value"] or 0, reverse=True)
        ]
        result["breakdown"] = breakdown_data
        result["breakdown_type"] = "device"

    return result


async def _resolve_quantity(
    quantity_id: int | None, quantity_search: str | None
) -> tuple[int | None, dict | None, str | None]:
    """Resolve quantity by ID or search term."""
    if quantity_id is not None:
        qty = await db.fetch_one(
            """
            SELECT id, quantity_code, quantity_name, unit
            FROM quantities
            WHERE id = $1
            """,
            quantity_id,
        )
        if not qty:
            return None, None, f"Quantity ID {quantity_id} not found"
        return qty["id"], {"name": qty["quantity_name"], "unit": qty["unit"]}, None

    if quantity_search is not None:
        # Semantic search
        qty = await db.fetch_one(
            """
            SELECT id, quantity_code, quantity_name, unit
            FROM quantities
            WHERE LOWER(quantity_code) LIKE '%' || LOWER($1) || '%'
               OR LOWER(quantity_name) LIKE '%' || LOWER($1) || '%'
            ORDER BY
                CASE
                    WHEN LOWER(quantity_code) = LOWER($1) THEN 1
                    WHEN LOWER(quantity_code) LIKE LOWER($1) || '%' THEN 2
                    ELSE 3
                END
            LIMIT 1
            """,
            quantity_search,
        )
        if not qty:
            return None, None, f"No quantity found matching '{quantity_search}'"
        return qty["id"], {"name": qty["quantity_name"], "unit": qty["unit"]}, None

    return None, None, "Either quantity_id or quantity_search is required"


def _select_bucket(time_range: timedelta, device_count: int) -> str:
    """Select optimal bucket size based on time range and device count."""
    hours = time_range.total_seconds() / 3600
    target_rows = 1000
    target_buckets = target_rows // max(device_count, 1)

    bucket_order = ["15min", "1hour", "4hour", "1day", "1week"]

    for bucket in bucket_order:
        bucket_hours = BUCKET_MINUTES[bucket] / 60
        num_buckets = hours / bucket_hours
        if num_buckets <= target_buckets:
            return bucket

    return "1week"


async def _get_peak_info(
    device_ids: list[int],
    quantity_id: int,
    query_start,
    query_end,
    peak_value: float,
) -> dict | None:
    """Get information about when the peak occurred."""
    device_placeholders = ", ".join(f"${i+4}" for i in range(len(device_ids)))

    # Find when peak occurred
    peak_query = f"""
        SELECT
            bucket as peak_time,
            device_id,
            aggregated_value as value
        FROM telemetry_15min_agg
        WHERE bucket >= $1
          AND bucket < $2
          AND quantity_id = $3
          AND device_id IN ({device_placeholders})
        ORDER BY aggregated_value DESC
        LIMIT 1
    """

    peak = await db.fetch_one(peak_query, query_start, query_end, quantity_id, *device_ids)

    if peak:
        # Get device name
        device = await db.fetch_one(
            "SELECT display_name FROM devices WHERE id = $1",
            peak["device_id"],
        )
        return {
            "timestamp": str(peak["peak_time"]),
            "value": round(float(peak["value"]), 3),
            "device_id": peak["device_id"],
            "device_name": device["display_name"] if device else f"Device {peak['device_id']}",
        }

    return None


def format_wages_data_response(result: dict) -> str:
    """Format get_wages_data response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    lines = []
    summary = result.get("summary", {})
    scope = result.get("scope", {})
    scope_type = result.get("scope_type", "unknown")

    # Header
    if "total_consumption_kwh" in summary:
        # Energy/cost response
        lines.append("## Energy Consumption Summary")
        lines.append("")
        lines.append(f"**Period:** {summary.get('period', 'N/A')}")
        lines.append(f"**Scope:** {_format_scope(scope_type, scope)}")
        lines.append("")
        lines.append(f"- **Total Consumption:** {summary['total_consumption_kwh']:,.2f} kWh")
        lines.append(f"- **Total Cost:** Rp {summary['total_cost_rp']:,.0f}")
        lines.append(f"- **Average Rate:** Rp {summary['avg_rate_per_kwh']:,.2f}/kWh")
        lines.append(f"- **Days with Data:** {summary.get('days_with_data', 'N/A')}")
    else:
        # Telemetry response
        lines.append(f"## {summary.get('quantity', 'Telemetry')} Summary")
        lines.append("")
        lines.append(f"**Period:** {summary.get('period', 'N/A')}")
        lines.append(f"**Scope:** {_format_scope(scope_type, scope)}")
        lines.append(f"**Aggregation:** {summary.get('agg_method', 'sum').upper()}")
        lines.append("")
        unit = summary.get("unit", "")
        lines.append(f"- **Value:** {summary['value']:,.3f} {unit}")

        # Peak info
        if "peak" in result:
            peak = result["peak"]
            lines.append("")
            lines.append("### Peak")
            lines.append(f"- **Time:** {peak['timestamp']}")
            lines.append(f"- **Device:** {peak['device_name']}")
            lines.append(f"- **Value:** {peak['value']:,.3f} {unit}")

    # Breakdown
    if "breakdown" in result:
        lines.append("")
        lines.append(f"### Breakdown by {result.get('breakdown_type', 'item')}")
        for item in result["breakdown"][:10]:  # Limit to 10
            if "device_name" in item:
                if "consumption_kwh" in item:
                    lines.append(
                        f"- **{item['device_name']}:** {item['consumption_kwh']:,.2f} kWh "
                        f"({item.get('percentage', 0):.1f}%)"
                    )
                else:
                    lines.append(
                        f"- **{item['device_name']}:** {item.get('value', 0):,.3f}"
                    )
            elif "date" in item:
                lines.append(
                    f"- **{item['date']}:** {item['consumption_kwh']:,.2f} kWh"
                )
            elif "shift" in item:
                lines.append(
                    f"- **{item['shift']}:** {item.get('consumption_kwh', 0):,.2f} kWh "
                    f"({item.get('percentage', 0):.1f}%)"
                )
            elif "rate" in item:
                lines.append(
                    f"- **{item['rate']}:** {item.get('consumption_kwh', 0):,.2f} kWh "
                    f"({item.get('percentage', 0):.1f}%)"
                )

        if len(result["breakdown"]) > 10:
            lines.append(f"- _(and {len(result['breakdown']) - 10} more...)_")

    return "\n".join(lines)


def _format_scope(scope_type: str, scope: dict) -> str:
    """Format scope info for display."""
    if scope_type == "device":
        return f"Device: {scope.get('device_name', 'Unknown')}"
    elif scope_type == "tag":
        key, val = scope.get("tag_key"), scope.get("tag_value")
        count = scope.get("device_count", 0)
        return f"Tag: {key}={val} ({count} devices)"
    elif scope_type == "multi_tag":
        tags_str = ", ".join(f"{t['key']}={t['value']}" for t in scope.get("tags", []))
        return f"Tags: {tags_str} ({scope.get('device_count', 0)} devices)"
    elif scope_type == "asset":
        name = scope.get("asset_name", "Unknown")
        count = scope.get("device_count", 0)
        return f"Asset: {name} ({count} devices)"
    elif scope_type == "aggregation":
        agg_name = scope.get("aggregation_name")
        formula = scope.get("formula", "")
        return f"Aggregation: {agg_name} ({formula})"
    elif scope_type == "formula":
        return f"Formula: {scope.get('formula', '')}"
    else:
        return f"Scope: {scope_type}"
