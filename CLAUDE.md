# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PFN Energy Intelligence - A conversational AI interface for the Valkyrie energy monitoring database (PostgreSQL + TimescaleDB). Enables querying energy consumption, power demand, and WAGES (Water, Air, Gas, Electricity, Steam) metrics through natural language.

**Stack:**
- **Frontend:** Next.js/React (`frontend/`)
- **Backend:** FastAPI + Anthropic SDK (`src/pfn_mcp/chat/`)
- **Tools:** MCP server with tool definitions (`src/pfn_mcp/tools/`)
- **Database:** PostgreSQL + TimescaleDB

## Commands

```bash
# Backend
pip install -e ".[dev]"      # Install dependencies
pfn-mcp                       # Run MCP server (stdio)
pfn-chat                      # Run chat API server (HTTP)
ruff check src/               # Lint
ruff check src/ --fix         # Auto-fix lint issues
pytest                        # Run tests
pytest tests/test_file.py::test_name -v  # Single test

# Frontend
cd frontend
npm install                   # Install dependencies
npm run dev                   # Development server (port 3000)
npm run build                 # Production build
```

## Configuration

Copy `.env.example` to `.env`:
- `DATABASE_URL` - PostgreSQL connection string
- `DB_POOL_MIN_SIZE`, `DB_POOL_MAX_SIZE` - Connection pool settings
- `DB_QUERY_TIMEOUT` - Query timeout in seconds
- `ANTHROPIC_API_KEY` - For chat backend
- `KEYCLOAK_URL`, `KEYCLOAK_REALM` - For authentication

## Architecture

```
src/pfn_mcp/
├── chat/              # Chat API backend (Anthropic SDK)
│   ├── app.py         # FastAPI routes (/chat, /conversations)
│   ├── llm.py         # Claude client with streaming
│   ├── tool_executor.py   # Execute MCP tools from LLM calls
│   ├── tool_registry.py   # Load tools from tools.yaml
│   ├── prompts.py     # System prompts and workflows
│   ├── auth.py        # Keycloak JWT validation
│   ├── conversations.py   # Conversation persistence
│   └── config.py      # Chat-specific settings
├── server.py          # MCP server entry point, call_tool handlers
├── tools.yaml         # Tool schemas - SOURCE OF TRUTH
├── tool_schema.py     # YAML→Tool loader
├── db.py              # asyncpg connection pool
├── config.py          # Pydantic settings
├── sse_server.py      # SSE/HTTP transport (legacy)
├── prompts/           # Workflow definitions
│   └── workflows.md   # Slash command workflows (/daily-digest, etc.)
└── tools/             # Tool implementations
    ├── tenants.py     # list_tenants
    ├── devices.py     # list_devices with fuzzy match
    ├── quantities.py  # list_quantities with semantic search
    ├── aggregations.py    # list_aggregations (departments, facility)
    ├── discovery.py   # Data exploration tools
    ├── telemetry.py   # Time-series tools
    ├── electricity_cost.py  # Cost tools (deprecated)
    ├── group_telemetry.py   # Group tools (deprecated)
    ├── wages_data.py  # Unified WAGES tool
    └── formula_parser.py    # Device formula parser

frontend/
├── src/
│   ├── app/           # Next.js pages
│   │   ├── chat/      # Main chat interface
│   │   └── login/     # Auth pages
│   ├── components/    # React components
│   │   ├── ChatMessages.tsx
│   │   ├── ChatInput.tsx
│   │   ├── MessageBubble.tsx
│   │   └── Markdown.tsx
│   ├── contexts/      # React contexts (Auth, Conversations)
│   └── lib/           # Utilities (api, auth, sse, types)
```

**Key patterns:**
- Tool schemas defined in `tools.yaml` (name, description, params, tenant_aware)
- Chat backend calls tools directly via `tool_executor.py` (no MCP protocol)
- Frontend uses SSE for streaming responses
- Workflows defined in `prompts/workflows.md` for slash commands
- `/daily-digest` and `/weekly-summary` auto-discover SEU via `seu_type` tags
- Database queries use positional parameters (`$1`, `$2`) for asyncpg

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
| `get_date_info` | Get weekday name for a date (today, yesterday, or YYYY-MM-DD) |

## Available Tools (Phase 2 - Telemetry)

| Tool | Description |
|------|-------------|
| `resolve_device` | Confirm device selection before telemetry queries (exact/partial/fuzzy match confidence) |
| `get_device_telemetry` | Fetch time-series data with adaptive bucketing (15min→1week based on range). For energy, use `get_energy_consumption` instead |
| `get_quantity_stats` | Pre-flight validation: data availability, completeness %, value ranges |
| `get_energy_consumption` | Get actual energy consumption (not meter readings) with cost. Smart data source: daily or sub-daily |

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
| `list_aggregations` | List named meter aggregations (facility totals, departments) |
| `get_group_telemetry` | Aggregated telemetry for a group - default: electricity; with quantity: any WAGES metric |
| `compare_groups` | Compare consumption across multiple groups side-by-side |

Grouping options:
- **Tag-based**: Use `tag_key` + `tag_value` (e.g., process=Waterjet, building=Factory A)
- **Asset-based**: Use `asset_id` to get all downstream devices in hierarchy

## Available Tools (Phase 2 - Peak Analysis)

| Tool | Description |
|------|-------------|
| `get_peak_analysis` | Find peak values with timestamps for device or group (any WAGES quantity) |

Features:
- Supports single device or group (tag/asset)
- Returns top N peaks per bucket (1hour/1day/1week)
- Shows which device caused each peak in groups
- Optional `device_daily` breakdown for per-device peaks
- Aggregation: uses `telemetry_15min_agg` with adaptive bucketing

## Available Tools (Phase 3 - Unified WAGES)

| Tool | Description |
|------|-------------|
| `get_wages_data` | **Unified tool** for all WAGES telemetry - replaces overlapping cost/group/peak tools |

**Scope options (use one):**
- `device_id` / `device_name`: Single device
- `tag_key` + `tag_value`: Tag-based group
- `tags`: Multi-tag AND query
- `asset_id`: Asset hierarchy
- `aggregation`: Named aggregation from `meter_aggregations` (e.g., "facility", "yarn_division")
- `formula`: Inline device formula (e.g., "94+11+27", "94-84")

**Data sources:**
- Energy/cost queries: Uses `daily_energy_cost_summary` (omit quantity params)
- WAGES telemetry: Uses `telemetry_15min_agg` (set `quantity_id` or `quantity_search`)

**Aggregation methods:** `sum` (default for energy), `avg` (default for power), `max` (peak), `min`

**Breakdowns:** `none`, `device`, `daily`, `shift`, `rate`, `shift_rate`

## Database Context

- **Tenants**: Multi-tenant system (tenants table with tenant_name, tenant_code)
- **Devices**: Power meters with display_name, device_code, linked to tenant_id
  - `metadata` JSONB contains: `device_info` (manufacturer, model), `data_concentrator` (slave_id, ip_address, port), `location`, `communication`
  - Unique key for admins: `slave_id@ip_address` combination
- **Quantities**: WAGES metrics (77 in use) - query `quantities` table, filter by `telemetry_15min_agg`
- **Telemetry**: Raw data in `telemetry_data` (14 days), aggregates in `telemetry_15min_agg` (2 years)
- **Cost Data**: `daily_energy_cost_summary` table with pre-calculated costs by shift and rate
  - Columns: daily_bucket, device_id, tenant_id, shift_period, rate_code, total_consumption, total_cost
  - Rate codes: WBP (peak), LWBP1/LWBP2 (off-peak), PV (solar)
  - Refreshed daily by pgAgent
- **Device Tags**: `device_tags` table for flexible device grouping
  - Columns: device_id, tag_key, tag_value, tag_category, is_active
  - Example tags: process=Waterjet, building=Factory A
  - SEU tags: `seu_type=compressor` (PRS), `seu_type=press_machine` (IOP)
  - Used by `get_group_telemetry` and workflows for aggregating consumption by group
- **Assets**: `assets` table with hierarchical structure (parent_id, utility_path)
  - Database functions: `get_all_downstream_assets()`, `get_downstream_devices_by_depth()`
- **Meter Aggregations**: `meter_aggregations` table for named formula-based device groups
  - Columns: tenant_id, name, aggregation_type, formula, description
  - Formula syntax: `94+11+27` (sum), `94-84` (difference), `(94+11+27)-(84)` (grouped)
  - Example: PRS facility = `94+11+27` (Main + Genset + Solar)
  - Used by `get_wages_data` with `aggregation` parameter

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
