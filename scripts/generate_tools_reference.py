#!/usr/bin/env python3
"""Generate tools-reference.md from tools.yaml.

This script parses the tools.yaml file and generates a comprehensive
markdown reference document with tool descriptions, parameters, and
defer_loading recommendations for the Tool Search feature.

Usage:
    python scripts/generate_tools_reference.py

Output:
    docs/tools-reference.md
"""

from datetime import datetime
from pathlib import Path

import yaml


# Tools that should NOT be deferred (always loaded)
# These are the most frequently used tools
ALWAYS_LOADED_TOOLS = {
    "resolve_device",
    "get_electricity_cost",
    "get_energy_consumption",
    "get_device_telemetry",
    "list_devices",
}

# Tool categories for organization
TOOL_CATEGORIES = {
    "Discovery": [
        "list_tenants",
        "list_devices",
        "list_quantities",
        "list_device_quantities",
        "compare_device_quantities",
        "get_device_data_range",
        "find_devices_by_quantity",
        "get_device_info",
        "check_data_freshness",
        "get_tenant_summary",
    ],
    "Telemetry": [
        "resolve_device",
        "get_device_telemetry",
        "get_quantity_stats",
        "get_energy_consumption",
    ],
    "Electricity Cost": [
        "get_electricity_cost",
        "get_electricity_cost_ranking",
        "compare_electricity_periods",
    ],
    "Group Telemetry": [
        "list_tags",
        "list_tag_values",
        "search_tags",
        "get_group_telemetry",
        "compare_groups",
    ],
    "Peak Analysis": [
        "get_peak_analysis",
    ],
}


def load_tools_yaml(path: Path) -> list[dict]:
    """Load tools from YAML file."""
    with open(path) as f:
        data = yaml.safe_load(f)
    return data.get("tools", [])


def format_param_table(params: list[dict]) -> str:
    """Format parameters as a markdown table."""
    if not params:
        return "_No parameters_\n"

    lines = [
        "| Parameter | Type | Required | Description |",
        "|-----------|------|----------|-------------|",
    ]

    for p in params:
        name = p["name"]
        ptype = p.get("type", "string")
        if ptype == "array":
            items = p.get("items", "string")
            ptype = f"array[{items}]"
        required = "Yes" if p.get("required") else "No"
        desc = p.get("description", "").replace("\n", " ").strip()
        # Truncate long descriptions
        if len(desc) > 80:
            desc = desc[:77] + "..."
        lines.append(f"| `{name}` | {ptype} | {required} | {desc} |")

    return "\n".join(lines) + "\n"


def format_tool_section(tool: dict) -> str:
    """Format a single tool as a markdown section."""
    name = tool["name"]
    desc = tool.get("description", "").strip()
    tenant_aware = tool.get("tenant_aware", False)
    params = tool.get("params", [])
    defer = name not in ALWAYS_LOADED_TOOLS

    lines = [
        f"### `{name}`",
        "",
        f"**Tenant-aware:** {'Yes' if tenant_aware else 'No'} | "
        f"**Defer loading:** {'Yes' if defer else 'No (always loaded)'}",
        "",
        desc,
        "",
        "**Parameters:**",
        "",
        format_param_table(params),
    ]

    return "\n".join(lines)


def generate_quick_reference(tools: list[dict]) -> str:
    """Generate quick reference table."""
    lines = [
        "## Quick Reference",
        "",
        "| Tool | Category | Tenant-Aware | Defer Loading | Purpose |",
        "|------|----------|--------------|---------------|---------|",
    ]

    # Build tool lookup
    tool_lookup = {t["name"]: t for t in tools}

    for category, tool_names in TOOL_CATEGORIES.items():
        for name in tool_names:
            if name not in tool_lookup:
                continue
            tool = tool_lookup[name]
            tenant = "Yes" if tool.get("tenant_aware") else "No"
            defer = "No" if name in ALWAYS_LOADED_TOOLS else "Yes"
            # First sentence of description
            desc = tool.get("description", "").split(".")[0].strip()
            if len(desc) > 50:
                desc = desc[:47] + "..."
            lines.append(f"| `{name}` | {category} | {tenant} | {defer} | {desc} |")

    return "\n".join(lines) + "\n"


def generate_tool_search_config(tools: list[dict]) -> str:
    """Generate tool search configuration example."""
    always_loaded = []
    deferred = []

    for tool in tools:
        name = tool["name"]
        if name in ALWAYS_LOADED_TOOLS:
            always_loaded.append(name)
        else:
            deferred.append(name)

    lines = [
        "## Tool Search Configuration",
        "",
        "When using Anthropic's Tool Search Tool, configure `defer_loading` as follows:",
        "",
        "### Always Loaded (Non-Deferred)",
        "These 5 tools are loaded immediately for every request:",
        "",
    ]
    for name in always_loaded:
        lines.append(f"- `{name}`")

    lines.extend([
        "",
        "### Deferred (Searchable)",
        f"These {len(deferred)} tools are loaded on-demand via search:",
        "",
    ])
    for name in deferred:
        lines.append(f"- `{name}`")

    lines.extend([
        "",
        "### MCP Integration Example",
        "",
        "```python",
        "tools = [",
        '    {"type": "tool_search_tool_bm25_20251119", "name": "tool_search"},',
        "    {",
        '        "type": "mcp_toolset",',
        '        "mcp_server_name": "pfn-mcp",',
        '        "default_config": {"defer_loading": True},',
        '        "configs": {',
    ])
    for name in always_loaded:
        lines.append(f'            "{name}": {{"defer_loading": False}},')
    lines.extend([
        "        }",
        "    }",
        "]",
        "```",
        "",
    ])

    return "\n".join(lines)


def main():
    """Generate tools-reference.md."""
    # Paths
    root = Path(__file__).parent.parent
    tools_yaml = root / "src" / "pfn_mcp" / "tools.yaml"
    output_path = root / "docs" / "tools-reference.md"

    # Load tools
    tools = load_tools_yaml(tools_yaml)
    tool_lookup = {t["name"]: t for t in tools}

    # Generate document
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        "# PFN MCP Tools Reference",
        "",
        f"<!-- Auto-generated from tools.yaml on {now} -->",
        "<!-- DO NOT EDIT MANUALLY - run: python scripts/generate_tools_reference.py -->",
        "",
        f"Total tools: **{len(tools)}**",
        "",
        "---",
        "",
        generate_quick_reference(tools),
        "",
        "---",
        "",
        generate_tool_search_config(tools),
        "",
        "---",
        "",
    ]

    # Generate detailed sections by category
    for category, tool_names in TOOL_CATEGORIES.items():
        lines.append(f"## {category} Tools")
        lines.append("")

        for name in tool_names:
            if name not in tool_lookup:
                continue
            lines.append(format_tool_section(tool_lookup[name]))
            lines.append("")
            lines.append("---")
            lines.append("")

    # Write output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write("\n".join(lines))

    print(f"Generated: {output_path}")
    print(f"Total tools: {len(tools)}")
    print(f"Always loaded: {len(ALWAYS_LOADED_TOOLS)}")
    print(f"Deferred: {len(tools) - len(ALWAYS_LOADED_TOOLS)}")


if __name__ == "__main__":
    main()
