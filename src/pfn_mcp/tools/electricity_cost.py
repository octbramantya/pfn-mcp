"""Electricity cost tools - Query daily_energy_cost_summary table."""

import logging
import re
from datetime import UTC, datetime, timedelta
from typing import Literal

from pfn_mcp import db

logger = logging.getLogger(__name__)

# Period patterns
RELATIVE_PERIOD = re.compile(r"^(\d+)\s*([dDwWmMyY])$")  # 7d, 1M, 1Y
MONTH_PERIOD = re.compile(r"^(\d{4})-(\d{2})$")  # 2025-12
DATE_RANGE = re.compile(r"^(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})$")

# Active Energy Delivered quantity ID
ACTIVE_ENERGY_QTY_ID = 124


def parse_period(
    period: str | None,
    start_date: str | None,
    end_date: str | None,
) -> tuple[datetime, datetime] | tuple[None, str]:
    """
    Parse period parameters into start/end datetime.

    Supports:
    - Relative: "7d", "30d", "3M", "1Y"
    - Month: "2025-12"
    - Range: "2025-12-01 to 2025-12-15"
    - Explicit start_date/end_date

    Returns (start, end) naive UTC datetimes or (None, error_message).
    Note: Returns naive datetimes for compatibility with asyncpg and
    PostgreSQL timestamp without timezone columns.
    """
    # Use UTC internally, but return naive datetimes for database compatibility
    now_utc = datetime.now(UTC)
    # Convert to naive UTC for database queries
    now = now_utc.replace(tzinfo=None)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)

    # Explicit date range takes precedence
    if start_date:
        try:
            start_dt = datetime.strptime(start_date, "%Y-%m-%d")
        except ValueError:
            return None, f"Invalid start_date format: {start_date}. Use YYYY-MM-DD"

        if end_date:
            try:
                end_dt = datetime.strptime(end_date, "%Y-%m-%d")
                # End of day
                end_dt = end_dt + timedelta(days=1)
            except ValueError:
                return None, f"Invalid end_date format: {end_date}. Use YYYY-MM-DD"
        else:
            end_dt = today + timedelta(days=1)  # End of today

        return start_dt, end_dt

    # Parse period string
    if not period:
        period = "7d"  # Default

    period = period.strip()

    # Try relative period (7d, 30d, 3M, 1Y)
    match = RELATIVE_PERIOD.match(period)
    if match:
        value = int(match.group(1))
        unit = match.group(2).lower()

        if unit == "d":
            delta = timedelta(days=value)
        elif unit == "w":
            delta = timedelta(weeks=value)
        elif unit == "m":
            delta = timedelta(days=value * 30)
        elif unit == "y":
            delta = timedelta(days=value * 365)
        else:
            delta = timedelta(days=value)

        return today - delta, today + timedelta(days=1)

    # Try month period (2025-12)
    match = MONTH_PERIOD.match(period)
    if match:
        year = int(match.group(1))
        month = int(match.group(2))
        start_dt = datetime(year, month, 1)

        # Calculate end of month
        if month == 12:
            end_dt = datetime(year + 1, 1, 1)
        else:
            end_dt = datetime(year, month + 1, 1)

        return start_dt, end_dt

    # Try date range (2025-12-01 to 2025-12-15)
    match = DATE_RANGE.match(period)
    if match:
        try:
            start_dt = datetime.strptime(match.group(1), "%Y-%m-%d")
            end_dt = datetime.strptime(match.group(2), "%Y-%m-%d")
            end_dt = end_dt + timedelta(days=1)  # End of day
            return start_dt, end_dt
        except ValueError:
            return None, f"Invalid date range format: {period}"

    return None, f"Invalid period format: {period}. Use: 7d, 1M, 2025-12, or date range"


async def _resolve_device(
    device: str | None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve device name to ID using fuzzy match.

    Returns (device_id, device_info, error_message).
    """
    if not device:
        return None, None, None

    device_row = await db.fetch_one(
        """
        SELECT d.id, d.display_name, d.device_code, d.tenant_id, t.tenant_name
        FROM devices d
        LEFT JOIN tenants t ON d.tenant_id = t.id
        WHERE d.is_active = true
          AND (d.display_name ILIKE $1 OR d.device_name ILIKE $1)
        ORDER BY
            CASE
                WHEN LOWER(d.display_name) = LOWER($2) THEN 0
                WHEN LOWER(d.display_name) LIKE LOWER($2) || '%' THEN 1
                ELSE 2
            END
        LIMIT 1
        """,
        f"%{device}%",
        device,
    )

    if not device_row:
        return None, None, f"Device not found: {device}"

    return device_row["id"], dict(device_row), None


async def _resolve_tenant(
    tenant: str | None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve tenant name to ID using fuzzy match.

    Returns (tenant_id, tenant_info, error_message).
    """
    if not tenant:
        return None, None, None

    tenant_row = await db.fetch_one(
        """
        SELECT id, tenant_name, tenant_code
        FROM tenants
        WHERE is_active = true
          AND (tenant_name ILIKE $1 OR tenant_code ILIKE $1)
        ORDER BY
            CASE
                WHEN LOWER(tenant_name) = LOWER($2) THEN 0
                WHEN LOWER(tenant_name) LIKE LOWER($2) || '%' THEN 1
                ELSE 2
            END
        LIMIT 1
        """,
        f"%{tenant}%",
        tenant,
    )

    if not tenant_row:
        return None, None, f"Tenant not found: {tenant}"

    return tenant_row["id"], dict(tenant_row), None


BreakdownType = Literal["none", "daily", "shift", "rate", "source"]


async def get_electricity_cost(
    device: str | None = None,
    tenant: str | None = None,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    breakdown: BreakdownType = "none",
) -> dict:
    """
    Get electricity consumption and cost for a device or tenant.

    Queries the daily_energy_cost_summary table for Active Energy (qty 124).

    Args:
        device: Device name (fuzzy match)
        tenant: Tenant name (fuzzy match)
        period: Time period - "7d", "1M", "2025-12", or "YYYY-MM-DD to YYYY-MM-DD"
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        breakdown: Breakdown type - "none", "daily", "shift", "rate", "source"

    Returns:
        Dictionary with summary and optional breakdown
    """
    # Validate at least one of device or tenant
    if not device and not tenant:
        return {"error": "Either device or tenant is required"}

    # Resolve device
    device_id, device_info, error = await _resolve_device(device)
    if error:
        return {"error": error}

    # Resolve tenant
    tenant_id, tenant_info, error = await _resolve_tenant(tenant)
    if error:
        return {"error": error}

    # If device provided, get tenant from device
    if device_info and not tenant_info:
        tenant_id = device_info["tenant_id"]
        tenant_info = {"tenant_name": device_info.get("tenant_name")}

    # Parse period
    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result

    # Build query conditions
    conditions = [
        "quantity_id = $1",
        "daily_bucket >= $2",
        "daily_bucket < $3",
    ]
    params: list = [ACTIVE_ENERGY_QTY_ID, query_start, query_end]
    param_idx = 4

    if device_id:
        conditions.append(f"device_id = ${param_idx}")
        params.append(device_id)
        param_idx += 1
    elif tenant_id:
        conditions.append(f"tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    where_clause = " AND ".join(conditions)

    # Get summary totals
    summary_query = f"""
        SELECT
            COALESCE(SUM(total_consumption), 0) as total_consumption_kwh,
            COALESCE(SUM(total_cost), 0) as total_cost_rp,
            COUNT(DISTINCT daily_bucket) as days_with_data,
            COUNT(*) as row_count,
            SUM(CASE WHEN total_cost IS NULL THEN total_consumption ELSE 0 END)
                as unmapped_consumption
        FROM daily_energy_cost_summary
        WHERE {where_clause}
    """

    summary = await db.fetch_one(summary_query, *params)

    total_consumption = float(summary["total_consumption_kwh"] or 0)
    total_cost = float(summary["total_cost_rp"] or 0)
    days_with_data = summary["days_with_data"] or 0
    unmapped = float(summary["unmapped_consumption"] or 0)

    # Calculate average rate
    mapped_consumption = total_consumption - unmapped
    avg_rate = total_cost / mapped_consumption if mapped_consumption > 0 else 0

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")
    period_str = f"{start_str} to {end_str}"

    result_dict = {
        "summary": {
            "total_consumption_kwh": round(total_consumption, 2),
            "total_cost_rp": round(total_cost, 2),
            "avg_rate_per_kwh": round(avg_rate, 2),
            "period": period_str,
            "days_with_data": days_with_data,
        },
    }

    # Add device/tenant context
    if device_info:
        result_dict["summary"]["device"] = device_info.get("display_name")
        result_dict["summary"]["device_id"] = device_id
    if tenant_info:
        result_dict["summary"]["tenant"] = tenant_info.get("tenant_name")

    # Handle unmapped consumption warning
    if unmapped > 0:
        result_dict["summary"]["unmapped_consumption_kwh"] = round(unmapped, 2)
        result_dict["summary"]["cost_coverage_pct"] = round(
            100 * (total_consumption - unmapped) / total_consumption, 1
        ) if total_consumption > 0 else 0

    # Get breakdown if requested
    if breakdown != "none":
        breakdown_data = await _get_breakdown(
            breakdown, where_clause, params, query_start, query_end
        )
        result_dict["breakdown"] = breakdown_data

    return result_dict


async def _get_breakdown(
    breakdown_type: BreakdownType,
    where_clause: str,
    params: list,
    start_dt: datetime,
    end_dt: datetime,
) -> list[dict]:
    """Get breakdown data based on type."""
    if breakdown_type == "daily":
        query = f"""
            SELECT
                daily_bucket::date as date,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY daily_bucket::date
            ORDER BY date
        """
    elif breakdown_type == "shift":
        query = f"""
            SELECT
                shift_period as shift,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY shift_period
            ORDER BY shift_period
        """
    elif breakdown_type == "rate":
        query = f"""
            SELECT
                COALESCE(rate_code, 'UNMAPPED') as rate,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp,
                AVG(rate_per_unit) as avg_rate_per_unit
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY rate_code
            ORDER BY consumption_kwh DESC
        """
    elif breakdown_type == "source":
        # Add table alias to where clause columns
        aliased_where = (
            where_clause.replace("quantity_id", "decs.quantity_id")
            .replace("daily_bucket", "decs.daily_bucket")
            .replace("device_id", "decs.device_id")
            .replace("tenant_id", "decs.tenant_id")
        )
        query = f"""
            SELECT
                COALESCE(us.source_name, 'UNMAPPED') as source,
                COALESCE(SUM(decs.total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(decs.total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary decs
            LEFT JOIN utility_sources us ON decs.utility_source_id = us.id
            WHERE {aliased_where}
            GROUP BY us.source_name
            ORDER BY consumption_kwh DESC
        """
    else:
        return []

    rows = await db.fetch_all(query, *params)

    breakdown_data = []
    total_consumption = sum(float(r.get("consumption_kwh", 0) or 0) for r in rows)

    for row in rows:
        consumption = float(row.get("consumption_kwh", 0) or 0)
        cost = float(row.get("cost_rp", 0) or 0)

        item = {
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
            "percentage": round(100 * consumption / total_consumption, 1)
            if total_consumption > 0
            else 0,
        }

        # Add breakdown-specific fields
        if breakdown_type == "daily":
            date_val = row.get("date")
            item["date"] = date_val.strftime("%Y-%m-%d") if date_val else None
        elif breakdown_type == "shift":
            item["shift"] = row.get("shift")
        elif breakdown_type == "rate":
            item["rate"] = row.get("rate")
            rate_per_unit = row.get("avg_rate_per_unit")
            if rate_per_unit:
                item["rate_per_kwh"] = round(float(rate_per_unit), 2)
        elif breakdown_type == "source":
            item["source"] = row.get("source")

        breakdown_data.append(item)

    return breakdown_data


def format_electricity_cost_response(result: dict) -> str:
    """Format get_electricity_cost response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    summary = result["summary"]
    lines = []

    # Header
    if "device" in summary:
        lines.append(f"## Electricity Cost: {summary['device']}")
        if "tenant" in summary:
            lines.append(f"**Tenant**: {summary['tenant']}")
    elif "tenant" in summary:
        lines.append(f"## Electricity Cost: {summary['tenant']}")

    lines.append(f"**Period**: {summary['period']}")
    lines.append(f"**Days with data**: {summary['days_with_data']}")
    lines.append("")

    # Summary
    lines.append("### Summary")
    consumption = summary["total_consumption_kwh"]
    cost = summary["total_cost_rp"]
    avg_rate = summary["avg_rate_per_kwh"]

    lines.append(f"- **Consumption**: {consumption:,.2f} kWh")
    lines.append(f"- **Cost**: Rp {cost:,.0f}")
    lines.append(f"- **Avg Rate**: Rp {avg_rate:,.2f}/kWh")

    # Unmapped warning
    if "unmapped_consumption_kwh" in summary:
        unmapped = summary["unmapped_consumption_kwh"]
        coverage = summary.get("cost_coverage_pct", 0)
        lines.append("")
        lines.append(f"⚠️ **{unmapped:,.2f} kWh** ({100-coverage:.1f}%) has no cost mapping")
        lines.append("   → Configure device_utility_mappings for accurate costs")

    # Breakdown
    breakdown = result.get("breakdown", [])
    if breakdown:
        lines.append("")
        lines.append("### Breakdown")
        lines.append("")

        # Determine breakdown type from first item
        first = breakdown[0]
        if "date" in first:
            for item in breakdown:
                date = item.get("date", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                lines.append(f"- {date}: {kwh:,.2f} kWh, Rp {rp:,.0f}")
        elif "shift" in first:
            for item in breakdown:
                shift = item.get("shift", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                pct = item["percentage"]
                lines.append(f"- **{shift}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")
        elif "rate" in first:
            for item in breakdown:
                rate = item.get("rate", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                pct = item["percentage"]
                rate_per = item.get("rate_per_kwh", 0)
                lines.append(
                    f"- **{rate}**: {kwh:,.2f} kWh ({pct}%), "
                    f"Rp {rp:,.0f} @ Rp {rate_per:,.2f}/kWh"
                )
        elif "source" in first:
            for item in breakdown:
                source = item.get("source", "?")
                kwh = item["consumption_kwh"]
                rp = item["cost_rp"]
                pct = item["percentage"]
                lines.append(f"- **{source}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")

    return "\n".join(lines)


GroupByType = Literal["shift", "rate", "source", "shift_rate"]


async def get_electricity_cost_breakdown(
    device: str,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    group_by: GroupByType = "shift_rate",
) -> dict:
    """
    Get detailed electricity cost breakdown for a device.

    Provides consumption and cost analysis grouped by shift, rate,
    utility source, or shift+rate combination.

    Args:
        device: Device name (fuzzy match, required)
        period: Time period - "7d", "1M", "2025-12", etc. (default: 7d)
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        group_by: Grouping type - "shift", "rate", "source", "shift_rate"

    Returns:
        Dictionary with device, period, and breakdown data
    """
    # Resolve device (required)
    device_id, device_info, error = await _resolve_device(device)
    if error:
        return {"error": error}

    # Parse period
    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result

    # Build base conditions
    conditions = [
        "quantity_id = $1",
        "daily_bucket >= $2",
        "daily_bucket < $3",
        "device_id = $4",
    ]
    params: list = [ACTIVE_ENERGY_QTY_ID, query_start, query_end, device_id]

    where_clause = " AND ".join(conditions)

    # Build GROUP BY query based on group_by type
    if group_by == "shift":
        query = f"""
            SELECT
                shift_period as shift,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY shift_period
            ORDER BY shift_period
        """
    elif group_by == "rate":
        query = f"""
            SELECT
                COALESCE(rate_code, 'UNMAPPED') as rate,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp,
                AVG(rate_per_unit) as avg_rate_per_unit
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY rate_code
            ORDER BY consumption_kwh DESC
        """
    elif group_by == "source":
        query = """
            SELECT
                COALESCE(us.source_name, 'UNMAPPED') as source,
                COALESCE(SUM(decs.total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(decs.total_cost), 0) as cost_rp
            FROM daily_energy_cost_summary decs
            LEFT JOIN utility_sources us ON decs.utility_source_id = us.id
            WHERE decs.quantity_id = $1
              AND decs.daily_bucket >= $2
              AND decs.daily_bucket < $3
              AND decs.device_id = $4
            GROUP BY us.source_name
            ORDER BY consumption_kwh DESC
        """
    else:  # shift_rate (default)
        query = f"""
            SELECT
                shift_period as shift,
                COALESCE(rate_code, 'UNMAPPED') as rate,
                COALESCE(SUM(total_consumption), 0) as consumption_kwh,
                COALESCE(SUM(total_cost), 0) as cost_rp,
                AVG(rate_per_unit) as avg_rate_per_unit
            FROM daily_energy_cost_summary
            WHERE {where_clause}
            GROUP BY shift_period, rate_code
            ORDER BY shift_period, rate_code
        """

    rows = await db.fetch_all(query, *params)

    # Calculate totals for percentages
    total_consumption = sum(float(r.get("consumption_kwh", 0) or 0) for r in rows)
    total_cost = sum(float(r.get("cost_rp", 0) or 0) for r in rows)

    # Build breakdown data
    breakdown_data = []
    for row in rows:
        consumption = float(row.get("consumption_kwh", 0) or 0)
        cost = float(row.get("cost_rp", 0) or 0)

        item = {
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
            "percentage": round(100 * consumption / total_consumption, 1)
            if total_consumption > 0
            else 0,
        }

        # Add group-specific fields
        if group_by == "shift":
            item["shift"] = row.get("shift")
        elif group_by == "rate":
            item["rate"] = row.get("rate")
            rate_per_unit = row.get("avg_rate_per_unit")
            if rate_per_unit:
                item["rate_per_kwh"] = round(float(rate_per_unit), 2)
        elif group_by == "source":
            item["source"] = row.get("source")
        else:  # shift_rate
            item["shift"] = row.get("shift")
            item["rate"] = row.get("rate")
            rate_per_unit = row.get("avg_rate_per_unit")
            if rate_per_unit:
                item["rate_per_kwh"] = round(float(rate_per_unit), 2)

        breakdown_data.append(item)

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    return {
        "device": device_info.get("display_name"),
        "device_id": device_id,
        "tenant": device_info.get("tenant_name"),
        "period": f"{start_str} to {end_str}",
        "group_by": group_by,
        "summary": {
            "total_consumption_kwh": round(total_consumption, 2),
            "total_cost_rp": round(total_cost, 2),
        },
        "breakdown": breakdown_data,
    }


def format_electricity_cost_breakdown_response(result: dict) -> str:
    """Format get_electricity_cost_breakdown response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    period = result["period"]
    group_by = result["group_by"]
    summary = result["summary"]
    breakdown = result["breakdown"]

    lines = [
        f"## Electricity Breakdown: {device}",
        f"**Period**: {period}",
        f"**Grouped by**: {group_by}",
        "",
        f"**Total**: {summary['total_consumption_kwh']:,.2f} kWh, "
        f"Rp {summary['total_cost_rp']:,.0f}",
        "",
        "### Breakdown",
        "",
    ]

    if not breakdown:
        lines.append("No data available for this period.")
        return "\n".join(lines)

    # Format based on group_by type
    if group_by == "shift":
        for item in breakdown:
            shift = item.get("shift", "?")
            kwh = item["consumption_kwh"]
            rp = item["cost_rp"]
            pct = item["percentage"]
            lines.append(f"- **{shift}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")

    elif group_by == "rate":
        for item in breakdown:
            rate = item.get("rate", "?")
            kwh = item["consumption_kwh"]
            rp = item["cost_rp"]
            pct = item["percentage"]
            rate_per = item.get("rate_per_kwh", 0)
            lines.append(
                f"- **{rate}**: {kwh:,.2f} kWh ({pct}%), "
                f"Rp {rp:,.0f} @ Rp {rate_per:,.2f}/kWh"
            )

    elif group_by == "source":
        for item in breakdown:
            source = item.get("source", "?")
            kwh = item["consumption_kwh"]
            rp = item["cost_rp"]
            pct = item["percentage"]
            lines.append(f"- **{source}**: {kwh:,.2f} kWh ({pct}%), Rp {rp:,.0f}")

    else:  # shift_rate
        # Group by shift for display
        current_shift = None
        for item in breakdown:
            shift = item.get("shift", "?")
            rate = item.get("rate", "?")
            kwh = item["consumption_kwh"]
            rp = item["cost_rp"]
            pct = item["percentage"]
            rate_per = item.get("rate_per_kwh", 0)

            if shift != current_shift:
                if current_shift is not None:
                    lines.append("")
                lines.append(f"**{shift}**")
                current_shift = shift

            lines.append(
                f"  - {rate}: {kwh:,.2f} kWh ({pct}%), "
                f"Rp {rp:,.0f} @ Rp {rate_per:,.2f}/kWh"
            )

    return "\n".join(lines)


MetricType = Literal["cost", "consumption"]


async def get_electricity_cost_ranking(
    tenant: str,
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,
    metric: MetricType = "cost",
    limit: int = 10,
) -> dict:
    """
    Rank devices by electricity consumption or cost within a tenant.

    Args:
        tenant: Tenant name (fuzzy match, required)
        period: Time period - "7d", "30d", "1M", "2025-12", etc. (default: 30d)
        start_date: Explicit start date (YYYY-MM-DD)
        end_date: Explicit end date (YYYY-MM-DD)
        metric: Ranking metric - "cost" or "consumption" (default: cost)
        limit: Number of results (default: 10)

    Returns:
        Dictionary with tenant, period, metric, and ranked devices
    """
    # Resolve tenant (required)
    tenant_id, tenant_info, error = await _resolve_tenant(tenant)
    if error:
        return {"error": error}

    # Parse period (default to 30d for ranking)
    if not period and not start_date:
        period = "30d"

    result = parse_period(period, start_date, end_date)
    if result[0] is None:
        return {"error": result[1]}

    query_start, query_end = result

    # Determine ORDER BY based on metric
    order_col = "total_cost" if metric == "cost" else "total_consumption"

    # Query aggregated by device
    query = f"""
        SELECT
            d.id as device_id,
            d.display_name as device,
            COALESCE(SUM(decs.total_consumption), 0) as consumption_kwh,
            COALESCE(SUM(decs.total_cost), 0) as cost_rp
        FROM daily_energy_cost_summary decs
        JOIN devices d ON decs.device_id = d.id
        WHERE decs.tenant_id = $1
          AND decs.quantity_id = $2
          AND decs.daily_bucket >= $3
          AND decs.daily_bucket < $4
        GROUP BY d.id, d.display_name
        ORDER BY {order_col} DESC
        LIMIT $5
    """

    rows = await db.fetch_all(
        query, tenant_id, ACTIVE_ENERGY_QTY_ID, query_start, query_end, limit
    )

    # Get tenant totals for percentage calculation
    totals_query = """
        SELECT
            COALESCE(SUM(total_consumption), 0) as total_consumption,
            COALESCE(SUM(total_cost), 0) as total_cost
        FROM daily_energy_cost_summary
        WHERE tenant_id = $1
          AND quantity_id = $2
          AND daily_bucket >= $3
          AND daily_bucket < $4
    """

    totals = await db.fetch_one(
        totals_query, tenant_id, ACTIVE_ENERGY_QTY_ID, query_start, query_end
    )

    tenant_total_consumption = float(totals["total_consumption"] or 0)
    tenant_total_cost = float(totals["total_cost"] or 0)

    # Build ranking data
    ranking_data = []
    for rank, row in enumerate(rows, 1):
        consumption = float(row.get("consumption_kwh", 0) or 0)
        cost = float(row.get("cost_rp", 0) or 0)

        # Calculate percentage based on metric
        if metric == "cost":
            pct = 100 * cost / tenant_total_cost if tenant_total_cost > 0 else 0
        else:
            pct = (
                100 * consumption / tenant_total_consumption
                if tenant_total_consumption > 0
                else 0
            )

        ranking_data.append({
            "rank": rank,
            "device": row.get("device"),
            "device_id": row.get("device_id"),
            "consumption_kwh": round(consumption, 2),
            "cost_rp": round(cost, 2),
            "percentage_of_total": round(pct, 1),
        })

    # Format period string
    start_str = query_start.strftime("%Y-%m-%d")
    end_str = (query_end - timedelta(days=1)).strftime("%Y-%m-%d")

    return {
        "tenant": tenant_info.get("tenant_name"),
        "tenant_id": tenant_id,
        "period": f"{start_str} to {end_str}",
        "metric": metric,
        "total_devices": len(ranking_data),
        "tenant_totals": {
            "consumption_kwh": round(tenant_total_consumption, 2),
            "cost_rp": round(tenant_total_cost, 2),
        },
        "ranking": ranking_data,
    }


def format_electricity_cost_ranking_response(result: dict) -> str:
    """Format get_electricity_cost_ranking response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    tenant = result["tenant"]
    period = result["period"]
    metric = result["metric"]
    totals = result["tenant_totals"]
    ranking = result["ranking"]

    metric_label = "Cost" if metric == "cost" else "Consumption"

    lines = [
        f"## Electricity Ranking: {tenant}",
        f"**Period**: {period}",
        f"**Ranked by**: {metric_label}",
        "",
        f"**Tenant Total**: {totals['consumption_kwh']:,.2f} kWh, "
        f"Rp {totals['cost_rp']:,.0f}",
        "",
        "### Top Devices",
        "",
    ]

    if not ranking:
        lines.append("No data available for this period.")
        return "\n".join(lines)

    for item in ranking:
        rank = item["rank"]
        device = item["device"]
        kwh = item["consumption_kwh"]
        rp = item["cost_rp"]
        pct = item["percentage_of_total"]

        lines.append(
            f"{rank}. **{device}**: {kwh:,.2f} kWh, Rp {rp:,.0f} ({pct}%)"
        )

    return "\n".join(lines)


def _format_period_label(period: str) -> str:
    """Convert period string to human-readable label."""
    # Try month format (2025-12)
    match = MONTH_PERIOD.match(period.strip())
    if match:
        year = int(match.group(1))
        month = int(match.group(2))
        month_names = [
            "", "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        return f"{month_names[month]} {year}"

    # Try relative period (7d, 30d)
    match = RELATIVE_PERIOD.match(period.strip())
    if match:
        value = match.group(1)
        unit = match.group(2).lower()
        unit_names = {"d": "days", "w": "weeks", "m": "months", "y": "years"}
        return f"Last {value} {unit_names.get(unit, 'days')}"

    # Return as-is for date ranges
    return period


async def _get_period_totals(
    device_id: int | None,
    tenant_id: int | None,
    start_dt: datetime,
    end_dt: datetime,
) -> dict:
    """Get consumption and cost totals for a period."""
    conditions = [
        "quantity_id = $1",
        "daily_bucket >= $2",
        "daily_bucket < $3",
    ]
    params: list = [ACTIVE_ENERGY_QTY_ID, start_dt, end_dt]
    param_idx = 4

    if device_id:
        conditions.append(f"device_id = ${param_idx}")
        params.append(device_id)
    elif tenant_id:
        conditions.append(f"tenant_id = ${param_idx}")
        params.append(tenant_id)

    where_clause = " AND ".join(conditions)

    query = f"""
        SELECT
            COALESCE(SUM(total_consumption), 0) as consumption_kwh,
            COALESCE(SUM(total_cost), 0) as cost_rp
        FROM daily_energy_cost_summary
        WHERE {where_clause}
    """

    row = await db.fetch_one(query, *params)
    return {
        "consumption_kwh": float(row["consumption_kwh"] or 0),
        "cost_rp": float(row["cost_rp"] or 0),
    }


async def compare_electricity_periods(
    device: str | None = None,
    tenant: str | None = None,
    period1: str | None = None,
    period2: str | None = None,
) -> dict:
    """
    Compare electricity costs between two time periods.

    Args:
        device: Device name (fuzzy match)
        tenant: Tenant name (fuzzy match)
        period1: First period (e.g., "2025-11", "7d")
        period2: Second period (e.g., "2025-12", "7d")

    Returns:
        Dictionary with period comparison and change metrics
    """
    # Validate at least one of device or tenant
    if not device and not tenant:
        return {"error": "Either device or tenant is required"}

    # Validate periods
    if not period1 or not period2:
        return {"error": "Both period1 and period2 are required"}

    # Resolve device
    device_id, device_info, error = await _resolve_device(device)
    if error:
        return {"error": error}

    # Resolve tenant
    tenant_id, tenant_info, error = await _resolve_tenant(tenant)
    if error:
        return {"error": error}

    # If device provided, get tenant from device
    if device_info and not tenant_info:
        tenant_id = device_info["tenant_id"]

    # Parse periods
    result1 = parse_period(period1, None, None)
    if result1[0] is None:
        return {"error": f"Invalid period1: {result1[1]}"}
    start1, end1 = result1

    result2 = parse_period(period2, None, None)
    if result2[0] is None:
        return {"error": f"Invalid period2: {result2[1]}"}
    start2, end2 = result2

    # Get totals for each period
    totals1 = await _get_period_totals(device_id, tenant_id, start1, end1)
    totals2 = await _get_period_totals(device_id, tenant_id, start2, end2)

    # Calculate changes
    consumption_change = totals2["consumption_kwh"] - totals1["consumption_kwh"]
    cost_change = totals2["cost_rp"] - totals1["cost_rp"]

    consumption_pct = (
        100 * consumption_change / totals1["consumption_kwh"]
        if totals1["consumption_kwh"] > 0
        else 0
    )
    cost_pct = (
        100 * cost_change / totals1["cost_rp"]
        if totals1["cost_rp"] > 0
        else 0
    )

    # Build response
    response = {
        "comparison": {
            "period1": {
                "label": _format_period_label(period1),
                "consumption_kwh": round(totals1["consumption_kwh"], 2),
                "cost_rp": round(totals1["cost_rp"], 2),
            },
            "period2": {
                "label": _format_period_label(period2),
                "consumption_kwh": round(totals2["consumption_kwh"], 2),
                "cost_rp": round(totals2["cost_rp"], 2),
            },
            "change": {
                "consumption_kwh": round(consumption_change, 2),
                "consumption_percent": round(consumption_pct, 1),
                "cost_rp": round(cost_change, 2),
                "cost_percent": round(cost_pct, 1),
            },
        },
    }

    # Add entity context
    if device_info:
        response["device"] = device_info.get("display_name")
        response["device_id"] = device_id
    if tenant_info:
        response["tenant"] = tenant_info.get("tenant_name")

    return response


def format_compare_electricity_periods_response(result: dict) -> str:
    """Format compare_electricity_periods response for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    comparison = result["comparison"]
    p1 = comparison["period1"]
    p2 = comparison["period2"]
    change = comparison["change"]

    # Header
    entity = result.get("device") or result.get("tenant", "Unknown")
    lines = [
        f"## Period Comparison: {entity}",
        "",
    ]

    # Period 1
    lines.append(f"### {p1['label']}")
    lines.append(f"- Consumption: {p1['consumption_kwh']:,.2f} kWh")
    lines.append(f"- Cost: Rp {p1['cost_rp']:,.0f}")
    lines.append("")

    # Period 2
    lines.append(f"### {p2['label']}")
    lines.append(f"- Consumption: {p2['consumption_kwh']:,.2f} kWh")
    lines.append(f"- Cost: Rp {p2['cost_rp']:,.0f}")
    lines.append("")

    # Change summary
    lines.append("### Change")

    # Consumption change
    cons_arrow = "↑" if change["consumption_kwh"] >= 0 else "↓"
    cons_sign = "+" if change["consumption_kwh"] >= 0 else ""
    lines.append(
        f"- Consumption: {cons_arrow} {cons_sign}{change['consumption_kwh']:,.2f} kWh "
        f"({cons_sign}{change['consumption_percent']:.1f}%)"
    )

    # Cost change
    cost_arrow = "↑" if change["cost_rp"] >= 0 else "↓"
    cost_sign = "+" if change["cost_rp"] >= 0 else ""
    lines.append(
        f"- Cost: {cost_arrow} {cost_sign}Rp {change['cost_rp']:,.0f} "
        f"({cost_sign}{change['cost_percent']:.1f}%)"
    )

    return "\n".join(lines)
