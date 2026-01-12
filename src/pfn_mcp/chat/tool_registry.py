"""Tool registry - maps tool names to implementation functions."""

from collections.abc import Callable
from typing import Any

from pfn_mcp.tool_schema import get_tool_metadata, load_tools_yaml
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

# Type alias for tool functions
ToolFunc = Callable[..., Any]
FormatFunc = Callable[[Any], str]

# Tool implementations: name -> (async_func, format_func)
# Format functions convert results to human-readable strings
TOOL_REGISTRY: dict[str, tuple[ToolFunc, FormatFunc]] = {
    # Discovery tools
    "list_tenants": (
        tenants_tool.list_tenants,
        tenants_tool.format_tenants_response,
    ),
    "list_devices": (
        devices_tool.list_devices,
        lambda r, search="": devices_tool.format_devices_response(r, search),
    ),
    "list_quantities": (
        quantities_tool.list_quantities,
        quantities_tool.format_quantities_response,
    ),
    "list_device_quantities": (
        device_quantities_tool.list_device_quantities,
        device_quantities_tool.format_device_quantities_response,
    ),
    "compare_device_quantities": (
        device_quantities_tool.compare_device_quantities,
        device_quantities_tool.format_compare_quantities_response,
    ),
    "get_device_data_range": (
        discovery_tool.get_device_data_range,
        discovery_tool.format_device_data_range_response,
    ),
    "find_devices_by_quantity": (
        discovery_tool.find_devices_by_quantity,
        discovery_tool.format_find_devices_response,
    ),
    "get_device_info": (
        discovery_tool.get_device_info,
        discovery_tool.format_device_info_response,
    ),
    "check_data_freshness": (
        discovery_tool.check_data_freshness,
        discovery_tool.format_data_freshness_response,
    ),
    "get_tenant_summary": (
        discovery_tool.get_tenant_summary,
        discovery_tool.format_tenant_summary_response,
    ),
    # Telemetry tools
    "resolve_device": (
        telemetry_tool.resolve_device,
        telemetry_tool.format_resolve_device_response,
    ),
    "get_device_telemetry": (
        telemetry_tool.get_device_telemetry,
        telemetry_tool.format_telemetry_response,
    ),
    "get_quantity_stats": (
        telemetry_tool.get_quantity_stats,
        telemetry_tool.format_quantity_stats_response,
    ),
    "get_energy_consumption": (
        energy_consumption_tool.get_energy_consumption,
        energy_consumption_tool.format_energy_consumption_response,
    ),
    # Electricity cost tools
    "get_electricity_cost": (
        electricity_cost_tool.get_electricity_cost,
        electricity_cost_tool.format_electricity_cost_response,
    ),
    "get_electricity_cost_ranking": (
        electricity_cost_tool.get_electricity_cost_ranking,
        electricity_cost_tool.format_electricity_cost_ranking_response,
    ),
    "compare_electricity_periods": (
        electricity_cost_tool.compare_electricity_periods,
        electricity_cost_tool.format_compare_electricity_periods_response,
    ),
    # Group telemetry tools
    "list_tags": (
        group_telemetry_tool.list_tags,
        group_telemetry_tool.format_list_tags_response,
    ),
    "list_tag_values": (
        group_telemetry_tool.list_tag_values,
        group_telemetry_tool.format_list_tag_values_response,
    ),
    "search_tags": (
        group_telemetry_tool.search_tags,
        group_telemetry_tool.format_search_tags_response,
    ),
    "get_group_telemetry": (
        group_telemetry_tool.get_group_telemetry,
        group_telemetry_tool.format_group_telemetry_response,
    ),
    "compare_groups": (
        group_telemetry_tool.compare_groups,
        group_telemetry_tool.format_compare_groups_response,
    ),
    # Peak analysis
    "get_peak_analysis": (
        peak_analysis_tool.get_peak_analysis,
        peak_analysis_tool.format_peak_analysis_response,
    ),
}


def get_tool_names() -> list[str]:
    """Get list of all registered tool names."""
    return list(TOOL_REGISTRY.keys())


def get_tool(name: str) -> tuple[ToolFunc, FormatFunc] | None:
    """Get tool function and formatter by name."""
    return TOOL_REGISTRY.get(name)


def get_tool_schemas() -> list[dict]:
    """Get tool schemas in OpenAI/Anthropic function calling format."""
    tools_yaml = load_tools_yaml()
    schemas = []

    for tool_def in tools_yaml:
        name = tool_def["name"]
        if name not in TOOL_REGISTRY:
            continue

        # Build parameters schema
        properties = {}
        required = []

        for param in tool_def.get("params", []):
            param_name = param["name"]
            param_schema: dict[str, Any] = {"type": param.get("type", "string")}

            if "description" in param:
                param_schema["description"] = param["description"]
            if "enum" in param:
                param_schema["enum"] = param["enum"]
            if "default" in param:
                param_schema["default"] = param["default"]

            # Handle array types
            if param.get("type") == "array":
                items_type = param.get("items", "string")
                if items_type == "object":
                    param_schema["items"] = {"type": "object"}
                else:
                    param_schema["items"] = {"type": items_type}

            properties[param_name] = param_schema

            if param.get("required"):
                required.append(param_name)

        schema = {
            "type": "function",
            "function": {
                "name": name,
                "description": tool_def["description"],
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                },
            },
        }
        schemas.append(schema)

    return schemas


def get_tenant_aware_tools() -> set[str]:
    """Get set of tool names that are tenant-aware."""
    metadata = get_tool_metadata()
    return {name for name, info in metadata.items() if info.get("tenant_aware")}
