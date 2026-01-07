"""Tool schema loader - converts tools.yaml to MCP Tool objects."""

from pathlib import Path

import yaml
from mcp.types import Tool


def load_tools_yaml() -> list[dict]:
    """Load tool definitions from tools.yaml."""
    yaml_path = Path(__file__).parent / "tools.yaml"
    with open(yaml_path) as f:
        data = yaml.safe_load(f)
    return data.get("tools", [])


def _build_input_schema(params: list[dict]) -> dict:
    """Convert params list to JSON Schema format."""
    if not params:
        return {"type": "object", "properties": {}, "required": []}

    properties = {}
    required = []

    for param in params:
        name = param["name"]
        param_type = param.get("type", "string")

        prop: dict = {}

        # Map types
        if param_type == "array":
            prop["type"] = "array"
            items_type = param.get("items", "string")
            if items_type == "object":
                prop["items"] = {"type": "object", "properties": {}}
            else:
                prop["items"] = {"type": items_type}
        else:
            prop["type"] = param_type

        # Add description
        if "description" in param:
            prop["description"] = param["description"]

        # Add enum if present
        if "enum" in param:
            prop["enum"] = param["enum"]

        # Add default if present
        if "default" in param:
            prop["default"] = param["default"]

        properties[name] = prop

        # Track required params
        if param.get("required"):
            required.append(name)

    return {"type": "object", "properties": properties, "required": required}


def yaml_to_tools() -> list[Tool]:
    """Convert tools.yaml definitions to MCP Tool objects."""
    tool_defs = load_tools_yaml()
    tools = []

    for tool_def in tool_defs:
        tool = Tool(
            name=tool_def["name"],
            description=tool_def["description"],
            inputSchema=_build_input_schema(tool_def.get("params", [])),
        )
        tools.append(tool)

    return tools


def get_tool_metadata() -> dict[str, dict]:
    """Get metadata about tools (tenant_aware, params) for wrapper generation."""
    tool_defs = load_tools_yaml()
    return {
        tool["name"]: {
            "tenant_aware": tool.get("tenant_aware", False),
            "params": [p["name"] for p in tool.get("params", [])],
            "required": [p["name"] for p in tool.get("params", []) if p.get("required")],
        }
        for tool in tool_defs
    }
