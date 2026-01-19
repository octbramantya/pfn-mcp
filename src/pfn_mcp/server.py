"""MCP Server for Valkyrie energy monitoring database."""

import asyncio
import logging
import signal

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from pfn_mcp import db
from pfn_mcp.config import settings
from pfn_mcp.tool_schema import yaml_to_tools
from pfn_mcp.tools import aggregations as aggregations_tool
from pfn_mcp.tools import device_quantities as device_quantities_tool
from pfn_mcp.tools import devices as devices_tool
from pfn_mcp.tools import discovery as discovery_tool
from pfn_mcp.tools import electricity_cost as electricity_cost_tool
from pfn_mcp.tools import energy_consumption as energy_consumption_tool
from pfn_mcp.tools import group_telemetry as group_telemetry_tool
from pfn_mcp.tools import peak_analysis as peak_analysis_tool
from pfn_mcp.tools import quantities as quantities_tool
from pfn_mcp.tools import telemetry as telemetry_tool
from pfn_mcp.tools import tenants as tenants_tool
from pfn_mcp.tools import wages_data as wages_data_tool

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Create MCP server instance
mcp = Server(settings.server_name)


@mcp.list_tools()
async def list_tools() -> list[Tool]:
    """List available MCP tools (loaded from tools.yaml)."""
    return yaml_to_tools()


# Tool definitions moved to tools.yaml - see tool_schema.py for loader
# This keeps server.py focused on handlers while schemas are in a parseable format

# NOTE: The following ~700 lines of inline Tool() definitions were removed.
# See src/pfn_mcp/tools.yaml for the schema definitions.
# See src/pfn_mcp/tool_schema.py for the yaml_to_tools() loader.

# --- OLD TOOL DEFINITIONS REMOVED (was ~700 lines) ---
# To see old definitions, check git history or tools.yaml

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
        tenant = arguments.get("tenant")
        limit = arguments.get("limit", 20)
        offset = arguments.get("offset", 0)
        try:
            result = await devices_tool.list_devices(
                search=search,
                tenant=tenant,
                limit=limit,
                offset=offset,
            )
            response = devices_tool.format_devices_response(result, search)
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
        tenant = arguments.get("tenant")
        try:
            result = await discovery_tool.find_devices_by_quantity(
                quantity_id=quantity_id,
                quantity_search=quantity_search,
                tenant=tenant,
            )
            response = discovery_tool.format_find_devices_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"find_devices_by_quantity failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_device_info":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        ip_address = arguments.get("ip_address")
        slave_id = arguments.get("slave_id")
        tenant = arguments.get("tenant")
        try:
            result = await discovery_tool.get_device_info(
                device_id=device_id,
                device_name=device_name,
                ip_address=ip_address,
                slave_id=slave_id,
                tenant=tenant,
            )
            response = discovery_tool.format_device_info_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_device_info failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "check_data_freshness":
        device_id = arguments.get("device_id")
        device_name = arguments.get("device_name")
        tenant = arguments.get("tenant")
        hours_threshold = arguments.get("hours_threshold", 24)
        try:
            result = await discovery_tool.check_data_freshness(
                device_id=device_id,
                device_name=device_name,
                tenant=tenant,
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

    elif name == "get_date_info":
        date_input = arguments.get("date", "today")
        try:
            result = discovery_tool.get_date_info(date_input=date_input)
            response = discovery_tool.format_date_info_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_date_info failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "resolve_device":
        search = arguments.get("search", "")
        tenant = arguments.get("tenant")
        limit = arguments.get("limit", 5)
        try:
            result = await telemetry_tool.resolve_device(
                search=search,
                tenant=tenant,
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
                tenant=arguments.get("tenant"),
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
                tenant=arguments.get("tenant"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period", "30d"),
            )
            response = telemetry_tool.format_quantity_stats_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_quantity_stats failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_energy_consumption":
        try:
            result = await energy_consumption_tool.get_energy_consumption(
                device_id=arguments.get("device_id"),
                device_name=arguments.get("device_name"),
                tenant=arguments.get("tenant"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                bucket=arguments.get("bucket", "auto"),
                include_quality_info=arguments.get("include_quality_info", False),
            )
            response = energy_consumption_tool.format_energy_consumption_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_energy_consumption failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_electricity_cost":
        # DEPRECATED: Use get_wages_data instead
        logger.warning("get_electricity_cost is deprecated, use get_wages_data")
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
            deprecation_note = (
                "⚠️ DEPRECATED: get_electricity_cost will be removed. "
                "Use get_wages_data instead.\n\n"
            )
            return [TextContent(type="text", text=deprecation_note + response)]
        except Exception as e:
            logger.error(f"get_electricity_cost failed: {e}")
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
                tenant=arguments.get("tenant"),
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
            result = await group_telemetry_tool.list_tag_values(
                tenant=arguments.get("tenant"),
                tag_key=tag_key,
            )
            response = group_telemetry_tool.format_list_tag_values_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_tag_values failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "list_aggregations":
        tenant = arguments.get("tenant")
        if not tenant:
            return [TextContent(type="text", text="Error: tenant is required")]
        try:
            result = await aggregations_tool.list_aggregations(
                tenant=tenant,
                aggregation_type=arguments.get("aggregation_type"),
            )
            response = aggregations_tool.format_list_aggregations_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"list_aggregations failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "search_tags":
        search = arguments.get("search")
        if not search:
            return [TextContent(type="text", text="Error: search is required")]
        try:
            result = await group_telemetry_tool.search_tags(
                search=search,
                limit=arguments.get("limit", 10),
            )
            response = group_telemetry_tool.format_search_tags_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"search_tags failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_group_telemetry":
        # DEPRECATED: Use get_wages_data instead
        logger.warning("get_group_telemetry is deprecated, use get_wages_data")
        try:
            result = await group_telemetry_tool.get_group_telemetry(
                tenant=arguments.get("tenant"),
                tag_key=arguments.get("tag_key"),
                tag_value=arguments.get("tag_value"),
                tags=arguments.get("tags"),
                asset_id=arguments.get("asset_id"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                breakdown=arguments.get("breakdown", "none"),
                output=arguments.get("output", "summary"),
            )
            response = group_telemetry_tool.format_group_telemetry_response(result)
            deprecation_note = (
                "⚠️ DEPRECATED: get_group_telemetry will be removed. "
                "Use get_wages_data with tag_key/tag_value instead.\n\n"
            )
            return [TextContent(type="text", text=deprecation_note + response)]
        except Exception as e:
            logger.error(f"get_group_telemetry failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "compare_groups":
        groups = arguments.get("groups")
        if not groups:
            return [TextContent(type="text", text="Error: groups is required")]
        try:
            result = await group_telemetry_tool.compare_groups(
                tenant=arguments.get("tenant"),
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
        # DEPRECATED: Use get_wages_data with agg_method="max" instead
        logger.warning("get_peak_analysis is deprecated, use get_wages_data")
        try:
            result = await peak_analysis_tool.get_peak_analysis(
                tenant=arguments.get("tenant"),
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
            deprecation_note = (
                "⚠️ DEPRECATED: get_peak_analysis will be removed. "
                "Use get_wages_data with agg_method='max' instead.\n\n"
            )
            return [TextContent(type="text", text=deprecation_note + response)]
        except Exception as e:
            logger.error(f"get_peak_analysis failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    elif name == "get_wages_data":
        try:
            result = await wages_data_tool.get_wages_data(
                device_id=arguments.get("device_id"),
                device_name=arguments.get("device_name"),
                tag_key=arguments.get("tag_key"),
                tag_value=arguments.get("tag_value"),
                tags=arguments.get("tags"),
                asset_id=arguments.get("asset_id"),
                aggregation=arguments.get("aggregation"),
                formula=arguments.get("formula"),
                quantity_id=arguments.get("quantity_id"),
                quantity_search=arguments.get("quantity_search"),
                tenant=arguments.get("tenant"),
                period=arguments.get("period"),
                start_date=arguments.get("start_date"),
                end_date=arguments.get("end_date"),
                agg_method=arguments.get("agg_method"),
                breakdown=arguments.get("breakdown", "none"),
                output=arguments.get("output", "summary"),
            )
            response = wages_data_tool.format_wages_data_response(result)
            return [TextContent(type="text", text=response)]
        except Exception as e:
            logger.error(f"get_wages_data failed: {e}")
            return [TextContent(type="text", text=f"Error: {e}")]

    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]


async def run_server():
    """Run the MCP server using stdio transport."""
    logger.info(f"Starting {settings.server_name} v{settings.server_version}")

    # Track shutdown state
    shutdown_event = asyncio.Event()

    def signal_handler(signum, frame):
        """Handle shutdown signals."""
        sig_name = signal.Signals(signum).name
        logger.info(f"Received {sig_name}, initiating shutdown...")
        shutdown_event.set()

    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

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

    async def server_task():
        """Run the MCP server."""
        async with stdio_server() as (read_stream, write_stream):
            await mcp.run(
                read_stream,
                write_stream,
                mcp.create_initialization_options(),
            )

    async def shutdown_watcher():
        """Watch for shutdown signal and cancel server."""
        await shutdown_event.wait()

    try:
        # Run server until shutdown signal or natural completion
        server = asyncio.create_task(server_task())
        watcher = asyncio.create_task(shutdown_watcher())

        done, pending = await asyncio.wait(
            [server, watcher],
            return_when=asyncio.FIRST_COMPLETED,
        )

        # Cancel pending tasks with timeout
        for task in pending:
            task.cancel()
        if pending:
            # Wait briefly for tasks to cancel, then give up
            _, still_pending = await asyncio.wait(pending, timeout=1.0)
            if still_pending:
                logger.warning(f"{len(still_pending)} task(s) did not cancel in time")

    finally:
        # Close database pool with timeout
        logger.info("Closing database pool...")
        try:
            await asyncio.wait_for(db.close_pool(), timeout=2.0)
            logger.info("Database pool closed")
        except TimeoutError:
            logger.warning("Database pool close timed out, forcing exit")
        except Exception as e:
            logger.error(f"Error closing database pool: {e}")

        logger.info("Server shutdown complete")


def main():
    """Entry point for the MCP server."""
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
