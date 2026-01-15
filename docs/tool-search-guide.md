# Tool Search Integration Guide

This guide explains how to integrate Anthropic's Tool Search Tool with PFN MCP for optimal token efficiency and tool selection accuracy.

## Overview

The Tool Search Tool enables Claude to dynamically discover and load tools on-demand instead of loading all 23 tool definitions upfront. This:

- **Saves tokens**: ~10-20K tokens for 50 tools → only load what's needed
- **Improves accuracy**: Tool selection degrades with >30-50 tools; search helps
- **Scales**: Supports up to 10,000 tools

## Requirements

- **Beta header**: `advanced-tool-use-2025-11-20`
- **Models**: Claude Sonnet 4.5, Claude Opus 4.5 only
- **API version**: `2023-06-01`

## Tool Loading Strategy

### Always Loaded (5 tools)

These core tools are loaded immediately for every request:

| Tool | Reason |
|------|--------|
| `list_devices` | Device discovery - common first step |
| `resolve_device` | Required before telemetry queries |
| `get_device_telemetry` | Core telemetry access |
| `get_energy_consumption` | Most common consumption query |
| `get_electricity_cost` | Most common cost query |

### Deferred (18 tools)

These tools are loaded on-demand via search:

- `list_tenants`
- `list_quantities`
- `list_device_quantities`
- `compare_device_quantities`
- `get_device_data_range`
- `find_devices_by_quantity`
- `get_device_info`
- `check_data_freshness`
- `get_tenant_summary`
- `get_quantity_stats`
- `get_electricity_cost_ranking`
- `compare_electricity_periods`
- `list_tags`
- `list_tag_values`
- `search_tags`
- `get_group_telemetry`
- `compare_groups`
- `get_peak_analysis`

## Implementation

### Option A: Direct API with defer_loading

```python
import anthropic

client = anthropic.Anthropic()

response = client.beta.messages.create(
    model="claude-sonnet-4-5-20250929",
    betas=["advanced-tool-use-2025-11-20"],
    max_tokens=2048,
    system="You are PFN Energy Intelligence...",
    messages=[{"role": "user", "content": "What was yesterday's consumption?"}],
    tools=[
        # Tool search tool (always first, never deferred)
        {
            "type": "tool_search_tool_bm25_20251119",
            "name": "tool_search"
        },
        # Always loaded tools
        {
            "name": "resolve_device",
            "description": "Confirm device selection before querying telemetry...",
            "input_schema": {...}
            # No defer_loading = always loaded
        },
        {
            "name": "get_electricity_cost",
            "description": "Get electricity consumption and cost...",
            "input_schema": {...}
            # No defer_loading = always loaded
        },
        # Deferred tools
        {
            "name": "get_peak_analysis",
            "description": "Find peak values with timestamps...",
            "input_schema": {...},
            "defer_loading": True  # Loaded on-demand
        },
        # ... more deferred tools
    ]
)
```

### Option B: MCP Integration (Recommended)

Use with Anthropic's MCP connector for the cleanest integration:

```python
import anthropic

client = anthropic.Anthropic()

response = client.beta.messages.create(
    model="claude-sonnet-4-5-20250929",
    betas=["advanced-tool-use-2025-11-20", "mcp-client-2025-11-20"],
    max_tokens=2048,
    system="You are PFN Energy Intelligence...",
    messages=[{"role": "user", "content": "What was yesterday's consumption?"}],
    mcp_servers=[
        {
            "type": "url",
            "name": "pfn-mcp",
            "url": "https://your-mcp-server.example.com/sse"
        }
    ],
    tools=[
        # Tool search tool
        {
            "type": "tool_search_tool_bm25_20251119",
            "name": "tool_search"
        },
        # MCP toolset with defer_loading config
        {
            "type": "mcp_toolset",
            "mcp_server_name": "pfn-mcp",
            "default_config": {"defer_loading": True},
            "configs": {
                # Override: always load these 5 tools
                "list_devices": {"defer_loading": False},
                "resolve_device": {"defer_loading": False},
                "get_device_telemetry": {"defer_loading": False},
                "get_energy_consumption": {"defer_loading": False},
                "get_electricity_cost": {"defer_loading": False},
            }
        }
    ]
)
```

## Search Variants

### BM25 (Natural Language)

```json
{"type": "tool_search_tool_bm25_20251119", "name": "tool_search"}
```

Claude uses natural language queries like "energy consumption" or "peak analysis".

**Best for:** Most use cases. More intuitive tool discovery.

### Regex (Pattern Matching)

```json
{"type": "tool_search_tool_regex_20251119", "name": "tool_search"}
```

Claude constructs regex patterns like `"get_.*_cost"` or `"(?i)peak"`.

**Best for:** Precise tool name matching when you know the naming convention.

## Combining with Prompt Caching

For maximum efficiency, combine tool search with prompt caching:

```python
response = client.beta.messages.create(
    model="claude-sonnet-4-5-20250929",
    betas=["advanced-tool-use-2025-11-20"],
    max_tokens=2048,
    system=[
        {
            "type": "text",
            "text": CORE_PROMPT,  # Identity, rules (~1000 tokens)
            "cache_control": {"type": "ephemeral"}
        },
        {
            "type": "text",
            "text": f"Current tenant: {tenant_name}"  # Dynamic, not cached
        }
    ],
    tools=[...],  # With defer_loading
    messages=[...]
)
```

**Result:**
- System prompt: Cached (90% cost savings on hits)
- Tool definitions: Deferred (only load what's needed)
- Dynamic context: Fresh per request

## Response Handling

When Claude uses tool search, the response includes special block types:

```json
{
  "content": [
    {"type": "text", "text": "I'll search for tools..."},
    {
      "type": "server_tool_use",
      "id": "srvtoolu_01ABC",
      "name": "tool_search",
      "input": {"query": "peak analysis"}
    },
    {
      "type": "tool_search_tool_result",
      "tool_use_id": "srvtoolu_01ABC",
      "content": {
        "type": "tool_search_tool_search_result",
        "tool_references": [
          {"type": "tool_reference", "tool_name": "get_peak_analysis"}
        ]
      }
    },
    {
      "type": "tool_use",
      "id": "toolu_01XYZ",
      "name": "get_peak_analysis",
      "input": {"quantity_search": "power", "period": "24h"}
    }
  ]
}
```

The `tool_reference` blocks are automatically expanded into full tool definitions.

## Monitoring

Track tool search usage in response:

```python
usage = response.usage
print(f"Tool search requests: {usage.get('server_tool_use', {}).get('tool_search_requests', 0)}")
print(f"Input tokens: {usage['input_tokens']}")
print(f"Cache read tokens: {usage.get('cache_read_input_tokens', 0)}")
```

## Best Practices

1. **Keep 3-5 most-used tools always loaded** — avoids search overhead for common queries
2. **Use BM25 variant** — more natural for energy domain queries
3. **Write clear tool descriptions** — search includes names AND descriptions
4. **Combine with slash commands** — pre-defined tool chains skip search entirely
5. **Use system prompt v4** — optimized for tool search mode (~1000 tokens)

## Limitations

- **Beta feature** — may change
- **Model support** — Sonnet 4.5+ and Opus 4.5+ only (no Haiku)
- **Max tools** — 10,000 (plenty for PFN MCP's 23)
- **Not compatible with tool use examples** — can't provide example tool calls

## Files Reference

| File | Purpose |
|------|---------|
| `docs/tools-reference.md` | Auto-generated tool documentation with defer_loading recommendations |
| `docs/playground/sys-prompt-ver-4-toolsearch.md` | System prompt optimized for tool search |
| `src/pfn_mcp/prompts/` | Modular prompt components for caching |
| `scripts/generate_tools_reference.py` | Regenerate tools-reference.md after tool changes |
