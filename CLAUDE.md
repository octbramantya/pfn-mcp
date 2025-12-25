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
└── tools/         # Tool implementations (one file per tool)
    ├── quantities.py  # list_quantities with QUANTITY_ALIASES for semantic search
    ├── devices.py     # list_devices with fuzzy match ranking
    └── tenants.py     # list_tenants with device counts
```

**Key patterns:**
- Each tool module exports `list_*()` async function and `format_*_response()` formatter
- Database queries use positional parameters (`$1`, `$2`) for asyncpg
- Server initializes DB pool on startup, closes in `finally` block

## Database Context

- **Tenants**: Multi-tenant system (tenants table with tenant_name, tenant_code)
- **Devices**: Power meters with display_name, device_code, linked to tenant_id
- **Quantities**: WAGE metrics (77 in use) - query `quantities` table, filter by `telemetry_15min_agg`
- **Telemetry**: Raw data in `telemetry_data` (14 days), aggregates in `telemetry_15min_agg` (2 years)

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
