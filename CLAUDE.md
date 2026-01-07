# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PFN MCP Server - A Model Context Protocol server providing natural language access to the Valkyrie energy monitoring database (PostgreSQL + TimescaleDB). Enables querying energy consumption, power demand, and WAGE (Water, Air, Gas, Electricity) metrics without SQL.

## Commands

```bash
# Install dependencies
pip install -e ".[dev]"

# Run the MCP server
pfn-mcp

# Lint
ruff check src/

# Auto-fix lint issues
ruff check src/ --fix

# Run tests
pytest

# Run single test
pytest tests/test_file.py::test_name -v
```

## Configuration

Copy `.env.example` to `.env` with database credentials:
- `DATABASE_URL` - PostgreSQL connection string
- `DB_POOL_MIN_SIZE`, `DB_POOL_MAX_SIZE` - Connection pool settings
- `DB_QUERY_TIMEOUT` - Query timeout in seconds

## Architecture

```
src/pfn_mcp/
├── server.py      # MCP server entry point, call_tool handlers
├── tools.yaml     # Tool schemas - SOURCE OF TRUTH for all tool definitions
├── tool_schema.py # YAML→Tool loader (yaml_to_tools, get_tool_metadata)
├── db.py          # asyncpg connection pool (init_pool, fetch_all, fetch_one, fetch_val)
├── config.py      # Pydantic settings from environment
├── sse_server.py  # SSE/HTTP transport for remote deployment (VPS)
└── tools/         # Tool implementations (one file per tool group)
    ├── tenants.py           # list_tenants
    ├── devices.py           # list_devices with fuzzy match ranking
    ├── quantities.py        # list_quantities with QUANTITY_ALIASES for semantic search
    ├── device_quantities.py # list_device_quantities, compare_device_quantities
    ├── discovery.py         # Data exploration tools (data range, freshness, info)
    ├── telemetry.py         # Phase 2 time-series tools (resolve_device, etc.)
    ├── electricity_cost.py  # Electricity cost tools (daily aggregates, breakdowns)
    ├── group_telemetry.py   # Group telemetry tools (by tag or asset hierarchy)
    └── peak_analysis.py     # Peak analysis tools (find peak values with timestamps)
```

**Key patterns:**
- Tool schemas defined in `tools.yaml` (name, description, params, tenant_aware)
- `server.py` loads schemas via `yaml_to_tools()` and contains call_tool handlers
- Each tool module exports async function(s) and `format_*_response()` formatter
- Database queries use positional parameters (`$1`, `$2`) for asyncpg
- Semantic search via `QUANTITY_ALIASES` dict in quantities.py

## Available Tools (Phase 1)

| Tool | Description |
|------|-------------|
| `list_tenants` | List all tenants with device counts |
| `list_devices` | Search devices by name (fuzzy match) |
| `list_quantities` | List measurement types with semantic search (voltage, power, etc.) |
| `list_device_quantities` | What quantities exist for a specific device |
| `compare_device_quantities` | Find shared quantities across multiple devices |
| `get_device_data_range` | Time range of available data for a device |
| `find_devices_by_quantity` | Which devices have data for a specific quantity |
| `get_device_info` | Full device details; search by ID, name, or IP+slave_id |
| `check_data_freshness` | Identify offline/stale/online meters |
| `get_tenant_summary` | Tenant overview with device counts and models |

## Available Tools (Phase 2 - Telemetry)

| Tool | Description |
|------|-------------|
| `resolve_device` | Confirm device selection before telemetry queries (exact/partial/fuzzy match confidence) |
| `get_device_telemetry` | Fetch time-series data with adaptive bucketing (15min→1week based on range) |
| `get_quantity_stats` | Pre-flight validation: data availability, completeness %, value ranges |

## Available Tools (Phase 2 - Electricity Cost)

| Tool | Description |
|------|-------------|
| `get_electricity_cost` | Query cost/consumption for device or tenant with optional breakdown |
| `get_electricity_cost_breakdown` | Detailed breakdown by shift (SHIFT1/2/3), rate (WBP/LWBP), or source (PLN/Solar) |
| `get_electricity_cost_ranking` | Rank devices by cost or consumption within a tenant |
| `compare_electricity_periods` | Compare costs between two periods (month-over-month, custom ranges) |

Period formats supported: `7d`, `30d`, `1M`, `2025-12`, `2025-12-01 to 2025-12-15`

## Available Tools (Phase 2 - Group Telemetry)

| Tool | Description |
|------|-------------|
| `list_tags` | List available device tags for grouping (by process, building, area, etc.) |
| `list_tag_values` | List all values for a tag key with device counts |
| `get_group_telemetry` | Aggregated telemetry for a group - default: electricity; with quantity: any WAGE metric |
| `compare_groups` | Compare consumption across multiple groups side-by-side |

Grouping options:
- **Tag-based**: Use `tag_key` + `tag_value` (e.g., process=Waterjet, building=Factory A)
- **Asset-based**: Use `asset_id` to get all downstream devices in hierarchy

## Available Tools (Phase 2 - Peak Analysis)

| Tool | Description |
|------|-------------|
| `get_peak_analysis` | Find peak values with timestamps for device or group (any WAGE quantity) |

Features:
- Supports single device or group (tag/asset)
- Returns top N peaks per bucket (1hour/1day/1week)
- Shows which device caused each peak in groups
- Optional `device_daily` breakdown for per-device peaks
- Aggregation: uses `telemetry_15min_agg` with adaptive bucketing

## Database Context

- **Tenants**: Multi-tenant system (tenants table with tenant_name, tenant_code)
- **Devices**: Power meters with display_name, device_code, linked to tenant_id
  - `metadata` JSONB contains: `device_info` (manufacturer, model), `data_concentrator` (slave_id, ip_address, port), `location`, `communication`
  - Unique key for admins: `slave_id@ip_address` combination
- **Quantities**: WAGE metrics (77 in use) - query `quantities` table, filter by `telemetry_15min_agg`
- **Telemetry**: Raw data in `telemetry_data` (14 days), aggregates in `telemetry_15min_agg` (2 years)
- **Cost Data**: `daily_energy_cost_summary` table with pre-calculated costs by shift and rate
  - Columns: daily_bucket, device_id, tenant_id, shift_period, rate_code, total_consumption, total_cost
  - Rate codes: WBP (peak), LWBP1/LWBP2 (off-peak), PV (solar)
  - Refreshed daily by pgAgent
- **Device Tags**: `device_tags` table for flexible device grouping
  - Columns: device_id, tag_key, tag_value, tag_category, is_active
  - Example tags: process=Waterjet, building=Factory A
  - Used by `get_group_telemetry` for aggregating consumption by group
- **Assets**: `assets` table with hierarchical structure (parent_id, utility_path)
  - Database functions: `get_all_downstream_assets()`, `get_downstream_devices_by_depth()`

Primary quantity IDs for energy: 124 (Active Energy Delivered), 185 (Active Power)

## Issue Tracking

Uses **beads** (`bd`) for issue tracking:
```bash
bd ready                    # Find available work
bd update <id> --status in_progress
bd close <id>
bd sync                     # Sync with git (run before push)
```

## Session End Protocol

Before completing work, always:
1. `/tool-update` - Sync MCP tools with Open WebUI wrapper (if tools were modified)
2. `git add` changed files
3. `bd sync`
4. `git commit`
5. `git push`
