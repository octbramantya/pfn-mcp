"""Discovery tools - explore data availability and relationships."""

import json
import logging
from datetime import UTC, datetime

from pfn_mcp import db
from pfn_mcp.tools.datetime_utils import format_display_datetime
from pfn_mcp.tools.quantities import expand_quantity_aliases
from pfn_mcp.tools.resolve import resolve_tenant

logger = logging.getLogger(__name__)


async def get_device_data_range(
    device_id: int | None = None,
    device_name: str | None = None,
    quantity_id: int | None = None,
    quantity_search: str | None = None,
) -> dict:
    """
    Get the time range of available data for a device.

    Args:
        device_id: Device ID to query
        device_name: Device name (fuzzy search if device_id not provided)
        quantity_id: Optional specific quantity to check
        quantity_search: Optional quantity type filter (uses semantic aliases)

    Returns:
        Dictionary with device info, data range, and per-quantity breakdown
    """
    # Resolve device
    if device_id is None and device_name is None:
        return {"error": "Either device_id or device_name is required"}

    if device_id is None:
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
    quantity_conditions = []
    params = [device_id]
    param_idx = 2

    if quantity_id:
        quantity_conditions.append(f"t.quantity_id = ${param_idx}")
        params.append(quantity_id)
        param_idx += 1
    elif quantity_search:
        alias_patterns = expand_quantity_aliases(quantity_search)
        pattern_conds = []
        for pattern in alias_patterns:
            pattern_conds.append(f"q.quantity_code ILIKE ${param_idx}")
            params.append(pattern)
            param_idx += 1
        quantity_conditions.append(f"({' OR '.join(pattern_conds)})")

    quantity_where = ""
    if quantity_conditions:
        quantity_where = "AND " + " AND ".join(quantity_conditions)

    # Get overall data range
    range_query = f"""
        SELECT
            MIN(t.bucket) as earliest,
            MAX(t.bucket) as latest,
            COUNT(DISTINCT t.quantity_id) as quantity_count,
            COUNT(*) as record_count
        FROM telemetry_15min_agg t
        JOIN quantities q ON t.quantity_id = q.id
        WHERE t.device_id = $1
        {quantity_where}
    """
    overall = await db.fetch_one(range_query, *params)

    if not overall or overall["earliest"] is None:
        return {
            "device": {
                "id": device["id"],
                "name": device["display_name"],
                "code": device["device_code"],
            },
            "data_available": False,
            "message": "No telemetry data found for this device",
        }

    # Calculate days of data
    earliest = overall["earliest"]
    latest = overall["latest"]
    if earliest and latest:
        days_of_data = (latest - earliest).days + 1
    else:
        days_of_data = 0

    # Get per-quantity breakdown (top 10 by record count)
    breakdown_query = f"""
        SELECT
            q.id as quantity_id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            MIN(t.bucket) as earliest,
            MAX(t.bucket) as latest,
            COUNT(*) as record_count
        FROM telemetry_15min_agg t
        JOIN quantities q ON t.quantity_id = q.id
        WHERE t.device_id = $1
        {quantity_where}
        GROUP BY q.id, q.quantity_code, q.quantity_name, q.unit
        ORDER BY record_count DESC
        LIMIT 10
    """
    breakdown = await db.fetch_all(breakdown_query, *params)

    return {
        "device": {
            "id": device["id"],
            "name": device["display_name"],
            "code": device["device_code"],
        },
        "data_available": True,
        "range": {
            "earliest": earliest.isoformat() if earliest else None,
            "latest": latest.isoformat() if latest else None,
            "days_of_data": days_of_data,
        },
        "summary": {
            "quantity_count": overall["quantity_count"],
            "record_count": overall["record_count"],
        },
        "quantities_breakdown": [
            {
                "quantity_id": q["quantity_id"],
                "code": q["quantity_code"],
                "name": q["quantity_name"],
                "unit": q["unit"],
                "earliest": q["earliest"].isoformat() if q["earliest"] else None,
                "latest": q["latest"].isoformat() if q["latest"] else None,
                "records": q["record_count"],
            }
            for q in breakdown
        ],
    }


def format_device_data_range_response(result: dict) -> str:
    """Format device data range result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    lines = [
        f"# Data Range for {device['name']}",
        f"Device ID: {device['id']} | Code: {device['code']}",
        "",
    ]

    if not result.get("data_available"):
        lines.append(result.get("message", "No data available"))
        return "\n".join(lines)

    data_range = result["range"]
    summary = result["summary"]

    # Format timestamps in display timezone (WIB)
    earliest_str = format_display_datetime(data_range["earliest"]) or data_range["earliest"]
    latest_str = format_display_datetime(data_range["latest"]) or data_range["latest"]

    lines.extend([
        "## Overall Data Range",
        f"- **Earliest**: {earliest_str} (WIB)",
        f"- **Latest**: {latest_str} (WIB)",
        f"- **Days of data**: {data_range['days_of_data']}",
        "",
        "## Summary",
        f"- Quantities tracked: {summary['quantity_count']}",
        f"- Total records: {summary['record_count']:,}",
        "",
    ])

    if result.get("quantities_breakdown"):
        lines.append("## Quantities (top 10 by record count)")
        for q in result["quantities_breakdown"]:
            unit = q["unit"] or "-"
            lines.append(f"- **{q['name']}** [{unit}]")
            lines.append(f"  ID: {q['quantity_id']} | Records: {q['records']:,}")

    return "\n".join(lines)


async def find_devices_by_quantity(
    quantity_id: int | None = None,
    quantity_search: str | None = None,
    tenant: str | None = None,
) -> dict:
    """
    Find all devices that have data for a specific quantity.

    Args:
        quantity_id: Specific quantity ID to search for
        quantity_search: Quantity search term (uses semantic aliases)
        tenant: Tenant name or code filter (None = all tenants/superuser)

    Returns:
        Dictionary with quantity info and list of devices grouped by tenant
    """
    if quantity_id is None and quantity_search is None:
        return {"error": "Either quantity_id or quantity_search is required"}

    # Resolve quantity/quantities
    quantity_conditions = ["q.is_active = true"]
    params = []
    param_idx = 1

    if quantity_id:
        quantity_conditions.append(f"q.id = ${param_idx}")
        params.append(quantity_id)
        param_idx += 1
    elif quantity_search:
        alias_patterns = expand_quantity_aliases(quantity_search)
        pattern_conds = []
        for pattern in alias_patterns:
            pattern_conds.append(f"q.quantity_code ILIKE ${param_idx}")
            params.append(pattern)
            param_idx += 1
        quantity_conditions.append(f"({' OR '.join(pattern_conds)})")

    quantity_where = " AND ".join(quantity_conditions)

    # Get matching quantities first
    quantities_query = f"""
        SELECT id, quantity_code, quantity_name, unit, category
        FROM quantities q
        WHERE {quantity_where}
        ORDER BY q.quantity_name
    """
    quantities = await db.fetch_all(quantities_query, *params)

    if not quantities:
        return {"error": f"No quantities found matching: {quantity_search or quantity_id}"}

    quantity_ids = [q["id"] for q in quantities]

    # Resolve tenant filter - string to ID
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Find devices with data for these quantities
    # Use a more efficient subquery approach
    if tenant_id:
        device_query = """
            SELECT
                d.id as device_id,
                d.display_name,
                d.device_code,
                t_tenant.tenant_name,
                t_tenant.id as tenant_id
            FROM devices d
            JOIN tenants t_tenant ON d.tenant_id = t_tenant.id
            WHERE d.is_active = true
              AND d.tenant_id = $2
              AND d.id IN (
                  SELECT DISTINCT device_id
                  FROM telemetry_15min_agg
                  WHERE quantity_id = ANY($1::int[])
              )
            ORDER BY t_tenant.tenant_name, d.display_name
        """
        query_params = [quantity_ids, tenant_id]
    else:
        device_query = """
            SELECT
                d.id as device_id,
                d.display_name,
                d.device_code,
                t_tenant.tenant_name,
                t_tenant.id as tenant_id
            FROM devices d
            JOIN tenants t_tenant ON d.tenant_id = t_tenant.id
            WHERE d.is_active = true
              AND d.id IN (
                  SELECT DISTINCT device_id
                  FROM telemetry_15min_agg
                  WHERE quantity_id = ANY($1::int[])
              )
            ORDER BY t_tenant.tenant_name, d.display_name
        """
        query_params = [quantity_ids]

    devices = await db.fetch_all(device_query, *query_params)

    # Group by tenant
    by_tenant: dict[str, list] = {}
    for d in devices:
        tenant_name = d["tenant_name"]
        if tenant_name not in by_tenant:
            by_tenant[tenant_name] = []
        by_tenant[tenant_name].append({
            "device_id": d["device_id"],
            "name": d["display_name"],
            "code": d["device_code"],
        })

    return {
        "quantities": [
            {
                "id": q["id"],
                "code": q["quantity_code"],
                "name": q["quantity_name"],
                "unit": q["unit"],
                "category": q["category"],
            }
            for q in quantities
        ],
        "quantity_count": len(quantities),
        "devices_by_tenant": by_tenant,
        "total_devices": len(devices),
    }


def format_find_devices_response(result: dict) -> str:
    """Format find devices by quantity result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    lines = [
        "# Devices by Quantity",
        "",
        f"## Matching Quantities ({result['quantity_count']})",
    ]

    for q in result["quantities"]:
        unit = q["unit"] or "-"
        lines.append(f"- {q['name']} (ID: {q['id']}) [{unit}] - {q['category']}")

    lines.extend([
        "",
        f"## Devices ({result['total_devices']} total)",
        "",
    ])

    for tenant_name, devices in result["devices_by_tenant"].items():
        lines.append(f"### {tenant_name} ({len(devices)} devices)")
        for d in devices:
            lines.append(f"- **{d['name']}** (ID: {d['device_id']}, Code: {d['code']})")
        lines.append("")

    return "\n".join(lines)


async def get_device_info(
    device_id: int | None = None,
    device_name: str | None = None,
    ip_address: str | None = None,
    slave_id: int | None = None,
    tenant: str | None = None,
) -> dict:
    """
    Get detailed device information including metadata.

    Args:
        device_id: Device ID to query
        device_name: Device name (fuzzy search if device_id not provided)
        ip_address: IP address to search in metadata (requires slave_id)
        slave_id: Modbus slave ID to search in metadata (requires ip_address)
        tenant: Tenant name or code filter (optional, narrows search)

    Returns:
        Dictionary with full device details including tenant context and metadata
    """
    # Validate parameter combinations
    has_modbus_search = ip_address is not None or slave_id is not None
    has_device_search = device_id is not None or device_name is not None

    if has_modbus_search:
        # Modbus search mode requires both ip_address and slave_id
        if ip_address is None or slave_id is None:
            return {"error": "Both ip_address and slave_id are required for Modbus search"}
    elif not has_device_search:
        return {"error": "Either device_id, device_name, or (ip_address + slave_id) is required"}

    # Resolve tenant filter if provided
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # Search by Modbus parameters (ip_address + slave_id)
    if has_modbus_search:
        if tenant_id:
            device_query = """
                SELECT
                    d.id,
                    d.display_name,
                    d.device_code,
                    d.is_active,
                    d.created_at,
                    d.updated_at,
                    d.metadata,
                    t.id as tenant_id,
                    t.tenant_name,
                    t.tenant_code
                FROM devices d
                JOIN tenants t ON d.tenant_id = t.id
                WHERE d.metadata -> 'data_concentrator' ->> 'ip_address' = $1
                  AND (d.metadata -> 'data_concentrator' ->> 'slave_id')::int = $2
                  AND d.tenant_id = $3
            """
            device = await db.fetch_one(device_query, ip_address, slave_id, tenant_id)
        else:
            device_query = """
                SELECT
                    d.id,
                    d.display_name,
                    d.device_code,
                    d.is_active,
                    d.created_at,
                    d.updated_at,
                    d.metadata,
                    t.id as tenant_id,
                    t.tenant_name,
                    t.tenant_code
                FROM devices d
                JOIN tenants t ON d.tenant_id = t.id
                WHERE d.metadata -> 'data_concentrator' ->> 'ip_address' = $1
                  AND (d.metadata -> 'data_concentrator' ->> 'slave_id')::int = $2
            """
            device = await db.fetch_one(device_query, ip_address, slave_id)

        if not device:
            tenant_hint = f" in tenant {tenant}" if tenant else ""
            msg = f"Device not found with IP {ip_address} and slave_id {slave_id}{tenant_hint}"
            return {"error": msg}

    # Search by device_name (fuzzy)
    elif device_id is None:
        if tenant_id:
            device_query = """
                SELECT
                    d.id,
                    d.display_name,
                    d.device_code,
                    d.is_active,
                    d.created_at,
                    d.updated_at,
                    d.metadata,
                    t.id as tenant_id,
                    t.tenant_name,
                    t.tenant_code
                FROM devices d
                JOIN tenants t ON d.tenant_id = t.id
                WHERE LOWER(d.display_name) LIKE LOWER($1)
                  AND d.tenant_id = $3
                ORDER BY
                    CASE
                        WHEN LOWER(d.display_name) = LOWER($2) THEN 0
                        WHEN LOWER(d.display_name) LIKE LOWER($2) || '%' THEN 1
                        ELSE 2
                    END
                LIMIT 1
            """
            device = await db.fetch_one(device_query, f"%{device_name}%", device_name, tenant_id)
        else:
            device_query = """
                SELECT
                    d.id,
                    d.display_name,
                    d.device_code,
                    d.is_active,
                    d.created_at,
                    d.updated_at,
                    d.metadata,
                    t.id as tenant_id,
                    t.tenant_name,
                    t.tenant_code
                FROM devices d
                JOIN tenants t ON d.tenant_id = t.id
                WHERE LOWER(d.display_name) LIKE LOWER($1)
                ORDER BY
                    CASE
                        WHEN LOWER(d.display_name) = LOWER($2) THEN 0
                        WHEN LOWER(d.display_name) LIKE LOWER($2) || '%' THEN 1
                        ELSE 2
                    END
                LIMIT 1
            """
            device = await db.fetch_one(device_query, f"%{device_name}%", device_name)

    # Search by device_id (exact)
    else:
        device_query = """
            SELECT
                d.id,
                d.display_name,
                d.device_code,
                d.is_active,
                d.created_at,
                d.updated_at,
                d.metadata,
                t.id as tenant_id,
                t.tenant_name,
                t.tenant_code
            FROM devices d
            JOIN tenants t ON d.tenant_id = t.id
            WHERE d.id = $1
        """
        device = await db.fetch_one(device_query, device_id)

    if not device:
        search_term = device_name if device_name else f"ID {device_id}"
        return {"error": f"Device not found: {search_term}"}

    # Parse metadata - may be dict, string, or None
    raw_metadata = device["metadata"]
    if isinstance(raw_metadata, str):
        try:
            metadata = json.loads(raw_metadata)
        except (json.JSONDecodeError, TypeError):
            metadata = {}
    elif isinstance(raw_metadata, dict):
        metadata = raw_metadata
    else:
        metadata = {}

    device_info = metadata.get("device_info", {}) if metadata else {}
    data_concentrator = metadata.get("data_concentrator", {}) if metadata else {}
    location = metadata.get("location", {}) if metadata else {}
    communication = (
        metadata.get("communication") or metadata.get("communiction", {})
        if metadata
        else {}
    )

    return {
        "device": {
            "id": device["id"],
            "name": device["display_name"],
            "code": device["device_code"],
            "is_active": device["is_active"],
            "created_at": device["created_at"].isoformat() if device["created_at"] else None,
            "updated_at": device["updated_at"].isoformat() if device["updated_at"] else None,
        },
        "tenant": {
            "id": device["tenant_id"],
            "name": device["tenant_name"],
            "code": device["tenant_code"],
        },
        "device_info": {
            "manufacturer": device_info.get("manufacturer"),
            "model": device_info.get("model"),
        },
        "data_concentrator": {
            "ip_address": data_concentrator.get("ip_address"),
            "slave_id": data_concentrator.get("slave_id"),
            "port": data_concentrator.get("port"),
            "number": data_concentrator.get("number"),
        },
        "location": {
            "latitude": location.get("latitude"),
            "longitude": location.get("longitude"),
        } if location else None,
        "communication": {
            "protocol": communication.get("protocol"),
            "last_updated": communication.get("last_updated"),
        } if communication else None,
    }


def format_device_info_response(result: dict) -> str:
    """Format device info result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    device = result["device"]
    tenant = result["tenant"]

    lines = [
        f"# Device: {device['name']}",
        "",
        "## Basic Info",
        f"- **Device ID**: {device['id']}",
        f"- **Code**: {device['code']}",
        f"- **Status**: {'Active' if device['is_active'] else 'Inactive'}",
        "",
        "## Tenant",
        f"- **Name**: {tenant['name']}",
        f"- **ID**: {tenant['id']}",
        f"- **Code**: {tenant['code']}",
        "",
    ]

    di = result.get("device_info", {})
    if di.get("manufacturer") or di.get("model"):
        lines.append("## Device Info")
        if di.get("manufacturer"):
            lines.append(f"- **Manufacturer**: {di['manufacturer']}")
        if di.get("model"):
            lines.append(f"- **Model**: {di['model']}")
        lines.append("")

    dc = result.get("data_concentrator", {})
    if dc.get("ip_address") or dc.get("slave_id"):
        lines.append("## Data Concentrator")
        if dc.get("ip_address"):
            lines.append(f"- **IP Address**: {dc['ip_address']}")
        if dc.get("slave_id"):
            lines.append(f"- **Slave ID**: {dc['slave_id']}")
        if dc.get("port"):
            lines.append(f"- **Port**: {dc['port']}")
        # Unique key for admins
        if dc.get("ip_address") and dc.get("slave_id"):
            lines.append(f"- **Unique Key**: {dc['slave_id']}@{dc['ip_address']}")
        lines.append("")

    loc = result.get("location")
    if loc and (loc.get("latitude") or loc.get("longitude")):
        lines.append("## Location")
        lines.append(f"- **Coordinates**: {loc['latitude']}, {loc['longitude']}")
        lines.append("")

    comm = result.get("communication")
    if comm and comm.get("protocol"):
        lines.append("## Communication")
        lines.append(f"- **Protocol**: {comm['protocol']}")
        if comm.get("last_updated"):
            lines.append(f"- **Last Updated**: {comm['last_updated']}")
        lines.append("")

    return "\n".join(lines)


async def check_data_freshness(
    device_id: int | None = None,
    device_name: str | None = None,
    tenant: str | None = None,
    hours_threshold: int = 24,
) -> dict:
    """
    Check when data was last received for device(s).

    Args:
        device_id: Specific device ID to check
        device_name: Device name (fuzzy search)
        tenant: Tenant name or code to check all devices (None = superuser mode)
        hours_threshold: Hours to consider data "stale" (default 24)

    Returns:
        Dictionary with device freshness status
    """
    now = datetime.now(UTC)

    if device_id or device_name:
        # Single device check
        if device_id is None:
            device_query = """
                SELECT id, display_name, device_code, tenant_id
                FROM devices
                WHERE is_active = true
                  AND LOWER(display_name) LIKE LOWER($1)
                ORDER BY
                    CASE
                        WHEN LOWER(display_name) = LOWER($2) THEN 0
                        ELSE 1
                    END
                LIMIT 1
            """
            device = await db.fetch_one(device_query, f"%{device_name}%", device_name)
            if not device:
                return {"error": f"Device not found: {device_name}"}
            device_id = device["id"]
        else:
            device = await db.fetch_one(
                "SELECT id, display_name, device_code FROM devices WHERE id = $1",
                device_id,
            )
            if not device:
                return {"error": f"Device ID not found: {device_id}"}

        # Get last reading time
        freshness_query = """
            SELECT MAX(bucket) as last_reading
            FROM telemetry_15min_agg
            WHERE device_id = $1
        """
        result = await db.fetch_one(freshness_query, device_id)
        last_reading = result["last_reading"] if result else None

        if last_reading:
            # Handle timezone-naive datetimes from database
            if last_reading.tzinfo is None:
                last_reading_utc = last_reading.replace(tzinfo=UTC)
            else:
                last_reading_utc = last_reading
            hours_ago = (now - last_reading_utc).total_seconds() / 3600
            if hours_ago <= 1:
                status = "online"
            elif hours_ago <= hours_threshold:
                status = "recent"
            else:
                status = "stale"
        else:
            hours_ago = None
            status = "no_data"

        return {
            "device": {
                "id": device["id"],
                "name": device["display_name"],
                "code": device["device_code"],
            },
            "last_reading": last_reading.isoformat() if last_reading else None,
            "hours_ago": round(hours_ago, 1) if hours_ago else None,
            "status": status,
            "threshold_hours": hours_threshold,
        }

    elif tenant:
        # Resolve tenant string to ID
        tenant_id, tenant_info, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

        # All devices for tenant
        devices_query = """
            SELECT
                d.id,
                d.display_name,
                d.device_code,
                MAX(t.bucket) as last_reading
            FROM devices d
            LEFT JOIN telemetry_15min_agg t ON d.id = t.device_id
            WHERE d.tenant_id = $1 AND d.is_active = true
            GROUP BY d.id, d.display_name, d.device_code
            ORDER BY last_reading DESC NULLS LAST
        """
        devices = await db.fetch_all(devices_query, tenant_id)

        if not devices:
            return {"error": f"No devices found for tenant: {tenant}"}

        device_statuses = []
        status_counts = {"online": 0, "recent": 0, "stale": 0, "no_data": 0}

        for d in devices:
            last_reading = d["last_reading"]
            if last_reading:
                # Handle timezone-naive datetimes from database
                if last_reading.tzinfo is None:
                    last_reading_utc = last_reading.replace(tzinfo=UTC)
                else:
                    last_reading_utc = last_reading
                hours_ago = (now - last_reading_utc).total_seconds() / 3600
                if hours_ago <= 1:
                    status = "online"
                elif hours_ago <= hours_threshold:
                    status = "recent"
                else:
                    status = "stale"
            else:
                hours_ago = None
                status = "no_data"

            status_counts[status] += 1
            device_statuses.append({
                "device_id": d["id"],
                "name": d["display_name"],
                "code": d["device_code"],
                "last_reading": last_reading.isoformat() if last_reading else None,
                "hours_ago": round(hours_ago, 1) if hours_ago else None,
                "status": status,
            })

        return {
            "tenant": tenant_info.get("tenant_name") if tenant_info else tenant,
            "tenant_id": tenant_id,
            "device_count": len(devices),
            "status_summary": status_counts,
            "threshold_hours": hours_threshold,
            "devices": device_statuses,
        }

    else:
        return {"error": "Either device_id, device_name, or tenant is required"}


def format_data_freshness_response(result: dict) -> str:
    """Format data freshness result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    lines = ["# Data Freshness Check", ""]

    if "device" in result:
        # Single device
        device = result["device"]
        status = result["status"]
        status_emoji = {
            "online": "🟢",
            "recent": "🟡",
            "stale": "🔴",
            "no_data": "⚫",
        }.get(status, "❓")

        # Format last reading in display timezone
        last_reading_str = format_display_datetime(result["last_reading"]) or "Never"
        tz_suffix = " (WIB)" if result["last_reading"] else ""

        lines.extend([
            f"## {device['name']}",
            f"- **Device ID**: {device['id']}",
            f"- **Status**: {status_emoji} {status.upper()}",
            f"- **Last Reading**: {last_reading_str}{tz_suffix}",
        ])
        if result["hours_ago"] is not None:
            lines.append(f"- **Hours Ago**: {result['hours_ago']}")
        lines.append(f"- **Threshold**: {result['threshold_hours']} hours")

    else:
        # Tenant-wide check
        summary = result["status_summary"]
        tenant_label = result.get("tenant") or f"Tenant ID: {result.get('tenant_id')}"
        lines.extend([
            f"## {tenant_label}",
            f"Total devices: {result['device_count']}",
            "",
            "### Status Summary",
            f"- 🟢 Online (< 1h): {summary['online']}",
            f"- 🟡 Recent (< {result['threshold_hours']}h): {summary['recent']}",
            f"- 🔴 Stale (> {result['threshold_hours']}h): {summary['stale']}",
            f"- ⚫ No Data: {summary['no_data']}",
            "",
            "### Device Details",
        ])

        for d in result["devices"]:
            status_emoji = {
                "online": "🟢",
                "recent": "🟡",
                "stale": "🔴",
                "no_data": "⚫",
            }.get(d["status"], "❓")
            hours = f" ({d['hours_ago']}h ago)" if d["hours_ago"] else ""
            lines.append(f"- {status_emoji} **{d['name']}**{hours}")

    return "\n".join(lines)


async def get_tenant_summary(
    tenant_id: int | None = None,
    tenant_name: str | None = None,
) -> dict:
    """
    Get comprehensive tenant overview.

    Args:
        tenant_id: Tenant ID to query
        tenant_name: Tenant name (fuzzy search if tenant_id not provided)

    Returns:
        Dictionary with tenant info, device counts, and data coverage
    """
    if tenant_id is None and tenant_name is None:
        return {"error": "Either tenant_id or tenant_name is required"}

    if tenant_id is None:
        tenant_query = """
            SELECT id, tenant_name, tenant_code
            FROM tenants
            WHERE LOWER(tenant_name) LIKE LOWER($1)
            ORDER BY
                CASE
                    WHEN LOWER(tenant_name) = LOWER($2) THEN 0
                    ELSE 1
                END
            LIMIT 1
        """
        tenant = await db.fetch_one(tenant_query, f"%{tenant_name}%", tenant_name)
        if not tenant:
            return {"error": f"Tenant not found: {tenant_name}"}
        tenant_id = tenant["id"]
    else:
        tenant = await db.fetch_one(
            "SELECT id, tenant_name, tenant_code FROM tenants WHERE id = $1",
            tenant_id,
        )
        if not tenant:
            return {"error": f"Tenant ID not found: {tenant_id}"}

    # Get device counts
    device_counts = await db.fetch_one(
        """
        SELECT
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE is_active) as active,
            COUNT(*) FILTER (WHERE NOT is_active) as inactive
        FROM devices
        WHERE tenant_id = $1
        """,
        tenant_id,
    )

    # Get a sample device to check data range (much faster than aggregating all)
    # This gives an approximation rather than exact range
    sample_device = await db.fetch_one(
        "SELECT id FROM devices WHERE tenant_id = $1 AND is_active = true LIMIT 1",
        tenant_id,
    )

    if sample_device:
        # Get data range from sample device (fast)
        data_stats = await db.fetch_one(
            """
            SELECT
                MIN(bucket) as earliest_data,
                MAX(bucket) as latest_data
            FROM telemetry_15min_agg
            WHERE device_id = $1
            """,
            sample_device["id"],
        )
        # Count quantities in use system-wide (already indexed)
        qty_count = await db.fetch_one(
            """
            SELECT COUNT(DISTINCT quantity_id) as quantity_count
            FROM telemetry_15min_agg
            WHERE device_id = $1
            """,
            sample_device["id"],
        )
        if data_stats:
            data_stats = dict(data_stats)
            data_stats["quantity_count"] = qty_count["quantity_count"] if qty_count else 0
            data_stats["devices_with_data"] = device_counts["active"]
        else:
            data_stats = {
                "earliest_data": None,
                "latest_data": None,
                "quantity_count": 0,
                "devices_with_data": 0,
            }
    else:
        data_stats = {
            "earliest_data": None,
            "latest_data": None,
            "quantity_count": 0,
            "devices_with_data": 0,
        }

    # Skip expensive category breakdown - can be added as separate tool if needed
    category_stats = []

    # Get devices by model
    model_stats = await db.fetch_all(
        """
        SELECT
            metadata -> 'device_info' ->> 'manufacturer' as manufacturer,
            metadata -> 'device_info' ->> 'model' as model,
            COUNT(*) as count
        FROM devices
        WHERE tenant_id = $1 AND is_active = true
        GROUP BY manufacturer, model
        ORDER BY count DESC
        LIMIT 5
        """,
        tenant_id,
    )

    return {
        "tenant": {
            "id": tenant["id"],
            "name": tenant["tenant_name"],
            "code": tenant["tenant_code"],
        },
        "devices": {
            "total": device_counts["total"],
            "active": device_counts["active"],
            "inactive": device_counts["inactive"],
            "with_data": data_stats["devices_with_data"] or 0,
        },
        "data_range": {
            "earliest": data_stats["earliest_data"].isoformat()
            if data_stats["earliest_data"]
            else None,
            "latest": data_stats["latest_data"].isoformat()
            if data_stats["latest_data"]
            else None,
        },
        "quantities": {
            "total_in_use": data_stats["quantity_count"] or 0,
            "by_category": [
                {
                    "category": c["category"],
                    "quantity_count": c["quantity_count"],
                    "device_count": c["device_count"],
                }
                for c in category_stats
            ],
        },
        "device_models": [
            {
                "manufacturer": m["manufacturer"],
                "model": m["model"],
                "count": m["count"],
            }
            for m in model_stats
        ],
    }


def format_tenant_summary_response(result: dict) -> str:
    """Format tenant summary result for human-readable output."""
    if "error" in result:
        return f"Error: {result['error']}"

    tenant = result["tenant"]
    devices = result["devices"]
    data_range = result["data_range"]
    quantities = result["quantities"]

    lines = [
        f"# Tenant: {tenant['name']}",
        f"ID: {tenant['id']} | Code: {tenant['code']}",
        "",
        "## Devices",
        f"- **Total**: {devices['total']}",
        f"- **Active**: {devices['active']}",
        f"- **Inactive**: {devices['inactive']}",
        f"- **With Data**: {devices['with_data']}",
        "",
        "## Data Range",
        f"- **Earliest**: {data_range['earliest'] or 'No data'}",
        f"- **Latest**: {data_range['latest'] or 'No data'}",
        "",
        "## Quantities in Use",
        f"Total: {quantities['total_in_use']}",
        "",
    ]

    if quantities["by_category"]:
        lines.append("### By Category")
        for cat in quantities["by_category"]:
            lines.append(
                f"- **{cat['category']}**: {cat['quantity_count']} quantities "
                f"across {cat['device_count']} devices"
            )
        lines.append("")

    if result.get("device_models"):
        lines.append("## Device Models (Top 5)")
        for m in result["device_models"]:
            manufacturer = m["manufacturer"] or "Unknown"
            model = m["model"] or "Unknown"
            lines.append(f"- {manufacturer} {model}: {m['count']} devices")

    return "\n".join(lines)
