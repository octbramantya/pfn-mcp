"""MCP Server for Valkyrie energy monitoring database."""

import asyncio
import logging

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from pfn_mcp import db
from pfn_mcp.config import settings
from pfn_mcp.tools import device_quantities as device_quantities_tool
from pfn_mcp.tools import devices as devices_tool
from pfn_mcp.tools import discovery as discovery_tool
from pfn_mcp.tools import electricity_cost as electricity_cost_tool
from pfn_mcp.tools import group_telemetry as group_telemetry_tool
from pfn_mcp.tools import peak_analysis as peak_analysis_tool
from pfn_mcp.tools import quantities as quantities_tool
from pfn_mcp.tools import telemetry as telemetry_tool
from pfn_mcp.tools import tenants as tenants_tool

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Create MCP server instance
mcp = Server(settings.server_name)


@mcp.list_tools()
async def list_tools() -> list[Tool]:
    """List available MCP tools."""
    return [
        Tool(
            name="list_tenants",
            description="List all available tenants in the Valkyrie database",
            inputSchema={
                "type": "object",
                "properties": {},
                "required": [],
            },
        ),
        Tool(
            name="list_devices",
            description=(
                "Search for devices by name. Supports fuzzy matching. "
                "Returns device info with tenant context."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "search": {
                        "type": "string",
                        "description": "Search term to filter devices by name",
                    },
                    "tenant_id": {
                        "type": "integer",
                        "description": "Optional tenant ID to filter devices",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of results (default: 20)",
                        "default": 20,
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="list_quantities",
            description=(
                "List available measurement quantities (metrics). "
                "Supports semantic search: 'voltage', 'power', 'energy', 'current', "
                "'power factor', 'thd', 'frequency', 'water', 'air'. "
                "Categories: Electricity, Water, Air, Gas."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "category": {
                        "type": "string",
                        "description": (
                            "Filter by WAGE category. Accepts: "
                            "electricity/electrical, water, air, gas"
                        ),
                    },
                    "search": {
                        "type": "string",
                        "description": (
                            "Semantic search term: voltage, power, energy, current, "
                            "power factor, thd, frequency, unbalance, water, air"
                        ),
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="list_device_quantities",
            description=(
                "List quantities available for a specific device. "
                "Shows what measurements exist in telemetry for the device. "
                "Supports semantic search for quantity types."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID to query",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Device name (fuzzy search)",
                    },
                    "search": {
                        "type": "string",
                        "description": (
                            "Filter by quantity type: voltage, power, energy, "
                            "current, thd, etc."
                        ),
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="compare_device_quantities",
            description=(
                "Compare quantities available across multiple devices. "
                "Shows shared quantities and per-device breakdown. "
                "Useful for finding common measurements between devices."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "List of device IDs to compare",
                    },
                    "device_names": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of device names (fuzzy search)",
                    },
                    "search": {
                        "type": "string",
                        "description": "Filter by quantity type: voltage, power, etc.",
                    },
                },
                "required": [],
            },
        ),
        # Discovery tools
        Tool(
            name="get_device_data_range",
            description=(
                "Get the time range of available data for a device. "
                "Shows earliest/latest data timestamps, days of data, and quantity breakdown. "
                "Essential for knowing what date ranges to query."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID to query",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Device name (fuzzy search)",
                    },
                    "quantity_id": {
                        "type": "integer",
                        "description": "Optional: check specific quantity",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": "Optional: filter by quantity type (voltage, power, etc.)",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="find_devices_by_quantity",
            description=(
                "Find all devices that have data for a specific quantity. "
                "Useful for finding which devices track a particular metric. "
                "Groups results by tenant."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "quantity_id": {
                        "type": "integer",
                        "description": "Quantity ID to search for",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": "Quantity search term (voltage, power, energy, etc.)",
                    },
                    "tenant_id": {
                        "type": "integer",
                        "description": "Optional: filter to specific tenant",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="get_device_info",
            description=(
                "Get detailed device information including metadata. "
                "Shows manufacturer, model, Modbus address (slave_id + IP), "
                "location, and communication protocol. "
                "Unique key for admins: slave_id@ip_address."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID to query",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Device name (fuzzy search)",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="check_data_freshness",
            description=(
                "Check when data was last received for device(s). "
                "Identifies offline, stale, or recently active meters. "
                "Can check single device or all devices for a tenant."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID to check",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Device name (fuzzy search)",
                    },
                    "tenant_id": {
                        "type": "integer",
                        "description": "Check all devices for a tenant",
                    },
                    "hours_threshold": {
                        "type": "integer",
                        "description": "Hours to consider data 'stale' (default: 24)",
                        "default": 24,
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="get_tenant_summary",
            description=(
                "Get comprehensive tenant overview. "
                "Shows device counts, data range, quantity coverage by category, "
                "and device models. Good starting point for tenant analysis."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "integer",
                        "description": "Tenant ID to query",
                    },
                    "tenant_name": {
                        "type": "string",
                        "description": "Tenant name (fuzzy search)",
                    },
                },
                "required": [],
            },
        ),
        # Telemetry tools (Phase 2)
        Tool(
            name="resolve_device",
            description=(
                "Confirm device selection before querying telemetry. "
                "Returns ranked candidates with match confidence (exact/partial/fuzzy). "
                "Use BEFORE get_device_telemetry when user provides device name, not ID. "
                "Prevents wrong-device queries from ambiguous fuzzy matches."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "search": {
                        "type": "string",
                        "description": "Device name search term",
                    },
                    "tenant_id": {
                        "type": "integer",
                        "description": "Optional tenant ID to filter devices",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum candidates to return (default: 5)",
                        "default": 5,
                    },
                },
                "required": ["search"],
            },
        ),
        Tool(
            name="get_device_telemetry",
            description=(
                "Fetch time-series telemetry data for a device. "
                "Returns aggregated data (avg, min, max, sum, count) with adaptive bucketing. "
                "Supports period strings (24h, 7d, 30d) or date ranges. "
                "Use resolve_device first if device name is ambiguous."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID (preferred over device_name)",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Device name (fuzzy search)",
                    },
                    "quantity_id": {
                        "type": "integer",
                        "description": "Quantity ID (preferred over quantity_search)",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": (
                            "Quantity search: voltage, power, energy, current, "
                            "power factor, thd, frequency"
                        ),
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: 1h, 24h, 7d, 30d, 3M, 1Y",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Start date (ISO format, alternative to period)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "End date (ISO format, defaults to now)",
                    },
                    "bucket": {
                        "type": "string",
                        "description": "Bucket size: 15min, 1hour, 4hour, 1day, 1week, auto",
                        "default": "auto",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="get_quantity_stats",
            description=(
                "Pre-flight validation before telemetry queries. "
                "Returns data availability stats: point count, min/max/avg values, "
                "first/last timestamps, data completeness percentage, and gaps. "
                "Use to verify data exists before calling get_device_telemetry."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Device ID to query",
                    },
                    "quantity_id": {
                        "type": "integer",
                        "description": "Quantity ID (preferred over quantity_search)",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": "Quantity search: voltage, power, energy, etc.",
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period to check (default: 30d)",
                        "default": "30d",
                    },
                },
                "required": ["device_id"],
            },
        ),
        # Electricity cost tools
        Tool(
            name="get_electricity_cost",
            description=(
                "Get electricity consumption and cost for a device or tenant. "
                "Queries pre-aggregated daily cost data with time-of-use rates. "
                "Supports breakdown by: daily, shift, rate (WBP/LWBP), or source (PLN/Solar). "
                "Period formats: '7d', '1M', '2025-12', or 'YYYY-MM-DD to YYYY-MM-DD'."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device": {
                        "type": "string",
                        "description": "Device name (fuzzy match)",
                    },
                    "tenant": {
                        "type": "string",
                        "description": "Tenant name (fuzzy match)",
                    },
                    "period": {
                        "type": "string",
                        "description": (
                            "Time period: '7d', '30d', '1M', '2025-12', "
                            "or 'YYYY-MM-DD to YYYY-MM-DD' (default: 7d)"
                        ),
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                    "breakdown": {
                        "type": "string",
                        "description": (
                            "Breakdown type: 'none', 'daily', 'shift', 'rate', 'source' "
                            "(default: none)"
                        ),
                        "enum": ["none", "daily", "shift", "rate", "source"],
                        "default": "none",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="get_electricity_cost_breakdown",
            description=(
                "Detailed electricity cost breakdown for a device. "
                "Groups by shift (SHIFT1/2/3), rate (WBP/LWBP), source (PLN/Solar), "
                "or combined shift+rate. Use for shift productivity or rate analysis."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device": {
                        "type": "string",
                        "description": "Device name (fuzzy match, required)",
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: '7d', '1M', '2025-12' (default: 7d)",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                    "group_by": {
                        "type": "string",
                        "description": (
                            "Grouping: 'shift', 'rate', 'source', 'shift_rate' "
                            "(default: shift_rate)"
                        ),
                        "enum": ["shift", "rate", "source", "shift_rate"],
                        "default": "shift_rate",
                    },
                },
                "required": ["device"],
            },
        ),
        Tool(
            name="get_electricity_cost_ranking",
            description=(
                "Rank devices by electricity cost or consumption within a tenant. "
                "Shows top consumers with percentage of total. "
                "Use for identifying high-cost equipment or usage patterns."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant": {
                        "type": "string",
                        "description": "Tenant name (fuzzy match, required)",
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: '7d', '30d', '1M' (default: 30d)",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                    "metric": {
                        "type": "string",
                        "description": "Ranking metric: 'cost' or 'consumption' (default: cost)",
                        "enum": ["cost", "consumption"],
                        "default": "cost",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Number of results (default: 10)",
                        "default": 10,
                    },
                },
                "required": ["tenant"],
            },
        ),
        Tool(
            name="compare_electricity_periods",
            description=(
                "Compare electricity costs between two time periods. "
                "Shows consumption and cost for each period with change metrics. "
                "Use for month-over-month or custom period comparisons."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device": {
                        "type": "string",
                        "description": "Device name (fuzzy match)",
                    },
                    "tenant": {
                        "type": "string",
                        "description": "Tenant name (fuzzy match)",
                    },
                    "period1": {
                        "type": "string",
                        "description": "First period (e.g., '2025-11', '30d')",
                    },
                    "period2": {
                        "type": "string",
                        "description": "Second period (e.g., '2025-12', '30d')",
                    },
                },
                "required": ["period1", "period2"],
            },
        ),
        # Group telemetry tools
        Tool(
            name="list_tags",
            description=(
                "List available device tags for grouping. "
                "Tags allow flexible grouping by process, building, area, etc. "
                "Shows tag keys, values, and device counts by category."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "tag_key": {
                        "type": "string",
                        "description": "Filter by specific tag key (e.g., 'process', 'building')",
                    },
                    "tag_category": {
                        "type": "string",
                        "description": "Filter by tag category (e.g., 'location', 'production')",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="list_tag_values",
            description=(
                "List all values for a specific tag key with device counts. "
                "Shows which devices belong to each tag value. "
                "Use to explore available groupings before get_group_telemetry."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "tag_key": {
                        "type": "string",
                        "description": "Tag key to list values for (e.g., 'process', 'building')",
                    },
                },
                "required": ["tag_key"],
            },
        ),
        Tool(
            name="get_group_telemetry",
            description=(
                "Get aggregated telemetry for a group of devices. "
                "Default: electricity consumption/cost. "
                "With quantity: any WAGE metric (power, water flow, air pressure, etc.). "
                "Group by tag (tag_key + tag_value) or asset hierarchy (asset_id). "
                "Supports breakdown by device or daily."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "tag_key": {
                        "type": "string",
                        "description": "Tag key for grouping (e.g., 'process', 'building')",
                    },
                    "tag_value": {
                        "type": "string",
                        "description": "Tag value to match (e.g., 'Waterjet', 'Factory A')",
                    },
                    "asset_id": {
                        "type": "integer",
                        "description": "Asset ID for hierarchy-based grouping",
                    },
                    "quantity_id": {
                        "type": "integer",
                        "description": "Quantity ID for WAGE metrics (omit for electricity cost)",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": (
                            "Quantity search: power, voltage, water flow, air pressure, etc. "
                            "(omit for electricity cost)"
                        ),
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: '7d', '1M', '2025-12' (default: 7d)",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                    "breakdown": {
                        "type": "string",
                        "description": "Breakdown type: 'none', 'device', 'daily' (default: none)",
                        "enum": ["none", "device", "daily"],
                        "default": "none",
                    },
                },
                "required": [],
            },
        ),
        Tool(
            name="compare_groups",
            description=(
                "Compare electricity consumption across multiple groups. "
                "Each group can be defined by tag or asset. "
                "Returns consumption, cost, and percentage for each group."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "groups": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "tag_key": {"type": "string"},
                                "tag_value": {"type": "string"},
                                "asset_id": {"type": "integer"},
                            },
                        },
                        "description": (
                            "List of groups to compare. Each group needs either "
                            "(tag_key + tag_value) or asset_id"
                        ),
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: '7d', '1M', '2025-12' (default: 7d)",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                },
                "required": ["groups"],
            },
        ),
        # Peak analysis tools
        Tool(
            name="get_peak_analysis",
            description=(
                "Find peak values with timestamps for a device or group. "
                "Returns top N peaks per bucket (hour/day/week). "
                "Shows which device caused each peak. "
                "Supports any WAGE quantity: power, flow, pressure, etc."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "device_id": {
                        "type": "integer",
                        "description": "Single device ID",
                    },
                    "device_name": {
                        "type": "string",
                        "description": "Single device name (fuzzy search)",
                    },
                    "tag_key": {
                        "type": "string",
                        "description": "Tag key for group (e.g., 'process', 'building')",
                    },
                    "tag_value": {
                        "type": "string",
                        "description": "Tag value for group (e.g., 'Waterjet')",
                    },
                    "asset_id": {
                        "type": "integer",
                        "description": "Asset ID for hierarchy-based grouping",
                    },
                    "quantity_id": {
                        "type": "integer",
                        "description": "Quantity ID (e.g., 185 for Active Power)",
                    },
                    "quantity_search": {
                        "type": "string",
                        "description": "Quantity search: power, flow, pressure, voltage, etc.",
                    },
                    "period": {
                        "type": "string",
                        "description": "Time period: '7d', '30d', '1M' (default: 7d)",
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Explicit start date (YYYY-MM-DD)",
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Explicit end date (YYYY-MM-DD)",
                    },
                    "bucket": {
                        "type": "string",
                        "description": "Bucket size: '1hour', '1day', '1week' (auto if omitted)",
                        "enum": ["1hour", "1day", "1week"],
                    },
                    "top_n": {
                        "type": "integer",
                        "description": "Number of top peaks to return (default: 10)",
                        "default": 10,
                    },
                    "breakdown": {
                        "type": "string",
                        "description": "Breakdown: 'none' or 'device_daily' (default: none)",
                        "enum": ["none", "device_daily"],
                        "default": "none",
                    },
                },
                "required": [],
            },
        ),
    ]


@mcp.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    """Handle tool calls."""
    logger.info(f"Tool called: {name} with arguments: {arguments}")

    if name == "list_tenants":
        try:
            results = await tenants_tool.list_tenants()
            response = tenants_tool.format_tenants_response(results)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_tenants failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_devices":
        search = arguments.get("search")
        tenant_id = arguments.get("tenant_id")
        limit = arguments.get("limit", 20)
        try:
            results = await devices_tool.list_devices(
                search=search,
                tenant_id=tenant_id,
                limit=limit,
            )
            response = devices_tool.format_devices_response(results, search)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_devices failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_quantities":
        category = arguments.get("category")
        search = arguments.get("search")
        try:
            results = await quantities_tool.list_quantities(
                category=category,
                search=search,
                in_use_only=True,
            )
            response = quantities_tool.format_quantities_response(results)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_quantities failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_device_quantities":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        search = arguments.get("search")
        try:
            result = await device_quantities_tool.list_device_quantities(
                device_id=device_id,
                device_name=device_name,
                search=search,
            )
            response = device_quantities_tool.format_device_quantities_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_device_quantities failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "compare_device_quantities":
        device_ids = arguments.get("device_ids")
        device_names = arguments.get("device_names")
        search = arguments.get("search")
        try:
            result = await device_quantities_tool.compare_device_quantities(
                device_ids=device_ids,
                device_names=device_names,
                search=search,
            )
            response = device_quantities_tool.format_compare_quantities_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"compare_device_quantities failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_device_data_range":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        quantity_id = arguments.get("quantity_id")
        quantity_search = arguments.get("quantity_search")
        try:
            result = await discovery_tool.get_device_data_range(
                device_id=device_id,
                device_name=device_name,
                quantity_id=quantity_id,
                quantity_search=quantity_search,
            )
            response = discovery_tool.format_device_data_range_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_device_data_range failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "find_devices_by_quantity":
        quantity_id = arguments.get("quantity_id")
        quantity_search = arguments.get("quantity_search")
        tenant_id = arguments.get("tenant_id")
        try:
            result = await discovery_tool.find_devices_by_quantity(
                quantity_id=quantity_id,
                quantity_search=quantity_search,
                tenant_id=tenant_id,
            )
            response = discovery_tool.format_find_devices_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"find_devices_by_quantity failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_device_info":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        try:
            result = await discovery_tool.get_device_info(
                device_id=device_id,
                device_name=device_name,
            )
            response = discovery_tool.format_device_info_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_device_info failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "check_data_freshness":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        tenant_id = arguments.get("tenant_id")
        hours_threshold = arguments.get("hours_threshold", 24)
        try:
            result = await discovery_tool.check_data_freshness(
                device_id=device_id,
                device_name=device_name,
                tenant_id=tenant_id,
                hours_threshold=hours_threshold,
            )
            response = discovery_tool.format_data_freshness_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"check_data_freshness failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_tenant_summary":
        tenant_id = arguments.get("tenant_id")
        tenant_name = arguments.get("tenant_name")
        try:
            result = await discovery_tool.get_tenant_summary(
                tenant_id=tenant_id,
                tenant_name=tenant_name,
            )
            response = discovery_tool.format_tenant_summary_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_tenant_summary failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "resolve_device":
        search = arguments.get("search", "")
        tenant_id = arguments.get("tenant_id")
        limit = arguments.get("limit", 5)
        try:
            result = await telemetry_tool.resolve_device(
                search=search,
                tenant_id=tenant_id,
                limit=limit,
            )
            response = telemetry_tool.format_resolve_device_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"resolve_device failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_device_telemetry":
        try:
            result = await telemetry_tool.get_device_telemetry(
                device_id=arguments.get("device_id"),
                device_name=arguments.get("device_name"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                bucket=arguments.get("bucket", "auto"),
            )
            response = telemetry_tool.format_telemetry_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_device_telemetry failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_quantity_stats":
        device_id = arguments.get("device_id")
        if device_id is None:
            return [TextContent(type="text", text="Error: device_id is required")]
        try:
            result = await telemetry_tool.get_quantity_stats(
                device_id=device_id,
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period", "30d"),
            )
            response = telemetry_tool.format_quantity_stats_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_quantity_stats failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_electricity_cost":
        try:
            result = await electricity_cost_tool.get_electricity_cost(
                device=arguments.get("device"),
                tenant=arguments.get("tenant"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                breakdown=arguments.get("breakdown", "none"),
            )
            response = electricity_cost_tool.format_electricity_cost_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_electricity_cost failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_electricity_cost_breakdown":
        device = arguments.get("device")
        if not device:
            return [TextContent(type="text", text="Error: device is required")]
        try:
            result = await electricity_cost_tool.get_electricity_cost_breakdown(
                device=device,
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                group_by=arguments.get("group_by", "shift_rate"),
            )
            response = electricity_cost_tool.format_electricity_cost_breakdown_response(
                result
            )
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_electricity_cost_breakdown failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_electricity_cost_ranking":
        tenant = arguments.get("tenant")
        if not tenant:
            return [TextContent(type="text", text="Error: tenant is required")]
        try:
            result = await electricity_cost_tool.get_electricity_cost_ranking(
                tenant=tenant,
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                metric=arguments.get("metric", "cost"),
                limit=arguments.get("limit", 10),
            )
            response = electricity_cost_tool.format_electricity_cost_ranking_response(
                result
            )
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_electricity_cost_ranking failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "compare_electricity_periods":
        try:
            result = await electricity_cost_tool.compare_electricity_periods(
                device=arguments.get("device"),
                tenant=arguments.get("tenant"),
                period1=arguments.get("period1"),
                period2=arguments.get("period2"),
            )
            response = electricity_cost_tool.format_compare_electricity_periods_response(
                result
            )
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"compare_electricity_periods failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_tags":
        try:
            result = await group_telemetry_tool.list_tags(
                tag_key=arguments.get("tag_key"),
                tag_category=arguments.get("tag_category"),
            )
            response = group_telemetry_tool.format_list_tags_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_tags failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_tag_values":
        tag_key = arguments.get("tag_key")
        if not tag_key:
            return [TextContent(type="text", text="Error: tag_key is required")]
        try:
            result = await group_telemetry_tool.list_tag_values(tag_key=tag_key)
            response = group_telemetry_tool.format_list_tag_values_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_tag_values failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_group_telemetry":
        try:
            result = await group_telemetry_tool.get_group_telemetry(
                tag_key=arguments.get("tag_key"),
                tag_value=arguments.get("tag_value"),
                asset_id=arguments.get("asset_id"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                breakdown=arguments.get("breakdown", "none"),
            )
            response = group_telemetry_tool.format_group_telemetry_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_group_telemetry failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "compare_groups":
        groups = arguments.get("groups")
        if not groups:
            return [TextContent(type="text", text="Error: groups is required")]
        try:
            result = await group_telemetry_tool.compare_groups(
                groups=groups,
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
            )
            response = group_telemetry_tool.format_compare_groups_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"compare_groups failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_peak_analysis":
        try:
            result = await peak_analysis_tool.get_peak_analysis(
                device_id=arguments.get("device_id"),
                device_name=arguments.get("device_name"),
                tag_key=arguments.get("tag_key"),
                tag_value=arguments.get("tag_value"),
                asset_id=arguments.get("asset_id"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                bucket=arguments.get("bucket"),
                top_n=arguments.get("top_n", 10),
                breakdown=arguments.get("breakdown", "none"),
            )
            response = peak_analysis_tool.format_peak_analysis_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_peak_analysis failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]


async def run_server():
    """Run the MCP server using stdio transport."""
    logger.info(f"Starting {settings.server_name} v{settings.server_version}")

    # Initialize database connection pool
    try:
        await db.init_pool()
        if await db.check_connection():
            logger.info("Database connection verified")
        else:
            logger.warning("Database connection check failed - tools may not work")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
        logger.warning("Server starting without database - tools will return errors")

    try:
        async with stdio_server() as (read_stream, write_stream):
            await mcp.run(
                read_stream,
                write_stream,
                mcp.create_initialization_options(),
            )
    finally:
        await db.close_pool()


def main():
    """Entry point for the MCP server."""
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
