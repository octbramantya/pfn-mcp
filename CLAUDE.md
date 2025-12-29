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
├── server.py      # MCP server entry point, tool registration (@mcp.list_tools, @mcp.call_tool)
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
    └── electricity_cost.py  # Electricity cost tools (daily aggregates, breakdowns)
```

**Key patterns:**
- Each tool module exports async function(s) and `format_*_response()` formatter
- Database queries use positional parameters (`$1`, `$2`) for asyncpg
- Server initializes DB pool on startup, closes in `finally` block
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
| `get_device_info` | Full device details including metadata (slave_id@IP) |
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
1. `git add` changed files
2. `bd sync`
3. `git commit`
4. `git push`
