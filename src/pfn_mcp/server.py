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
from pfn_mcp.tools import quantities as quantities_tool
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
