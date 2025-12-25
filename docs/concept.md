# MCP Server for Valkyrie Database - Concept Document

**Created:** 2025-12-02
**Updated:** 2025-12-25
**Status:** Design Decisions Finalized
**Database:** Valkyrie (PostgreSQL 16.10 + TimescaleDB)

---

## Executive Summary

This document outlines the concept for an MCP (Model Context Protocol) server that provides a natural language interface to the Valkyrie energy monitoring database. The goal is to enable engineers and users to answer common energy-related questions without requiring manual SQL query writing.

---

## Problem Statement

**Current State:**
- Engineers and users need energy consumption data answers regularly
- Each query requires a standby engineer to write and execute SQL
- Common questions are repetitive but require SQL knowledge
- Response time depends on engineer availability

**Target State:**
- Natural language queries via Claude Desktop
- Self-service access to common energy metrics
- Instant responses for routine questions
- Engineer time freed for complex analysis

---

## Use Case Examples

### 1. Device Energy Consumption
> "How much does Device A consume energy for the last week?"

**Data Sources:**
- `telemetry_15min_agg` (15-minute aggregates)
- `daily_energy_cost_summary` (daily rollups)
- `devices` (device lookup)
- Energy quantities: IDs 62, 89, 96, 124, 130, 481

### 2. Device Group Averages
> "What's the average weekly consumption for Device Group B?"

**Data Sources:**
- `assets` (device grouping hierarchy)
- `asset_connections` (parent-child relationships)
- Aggregation across multiple devices

### 3. Peak Demand Analysis
> "When was the peak power demand during the last month and how much was the power draw during that week?"

**Data Sources:**
- `telemetry_15min_agg` for time-series peaks
- Power quantities for demand metrics
- Time-based aggregation and ranking

### 4. Cost Analysis
> "What was the total energy cost for Tenant X in November?"

**Data Sources:**
- `daily_energy_cost_summary`
- `utility_rates` (time-of-use rates)
- `tenant_shift_periods` (shift definitions)

---

## Proposed MCP Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                      Claude Desktop                          │
│                   (Natural Language UI)                       │
└─────────────────────┬───────────────────────────────────────┘
                      │ MCP Protocol
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    MCP Server                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   Tool Layer                         │    │
│  │  - get_device_energy_consumption                    │    │
│  │  - get_device_group_consumption                     │    │
│  │  - get_peak_demand                                  │    │
│  │  - get_energy_costs                                 │    │
│  │  - list_devices                                     │    │
│  │  - list_tenants                                     │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Query Builder Layer                     │    │
│  │  - Parameter validation                              │    │
│  │  - Time range parsing                                │    │
│  │  - Device/Tenant resolution                          │    │
│  │  - Query construction                                │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Database Connection                     │    │
│  │  - Connection pooling                                │    │
│  │  - Read-only access                                  │    │
│  │  - Query timeout limits                              │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────┬───────────────────────────────────────┘
                      │ PostgreSQL Protocol
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                 Valkyrie Database                            │
│              (PostgreSQL + TimescaleDB)                      │
└─────────────────────────────────────────────────────────────┘
```

### Proposed MCP Tools

| Tool Name | Purpose | Key Parameters |
|-----------|---------|----------------|
| `get_device_energy` | Single device energy consumption | device_id/name, time_range, aggregation |
| `get_group_energy` | Device group/asset energy | asset_id/name, time_range, aggregation |
| `get_peak_demand` | Peak power demand analysis | device/tenant, time_range, top_n |
| `get_energy_costs` | Cost analysis | tenant, time_range, breakdown_by |
| `list_devices` | Browse available devices | tenant_id, search_term, device_type |
| `list_tenants` | Browse tenants | - |
| `get_device_hierarchy` | Show device/asset relationships | tenant_id, root_asset |
| `compare_devices` | Side-by-side comparison | device_ids[], time_range, metrics |

### Resource Endpoints (Optional)

MCP also supports "resources" for read-only data access:

| Resource | URI Pattern | Description |
|----------|-------------|-------------|
| Device Info | `device://{tenant_id}/{device_id}` | Device metadata and recent stats |
| Tenant Summary | `tenant://{tenant_id}/summary` | Tenant overview with device counts |
| Quantity Codes | `quantities://list` | Available measurement types |

---

## Technical Considerations

### Security

1. **Read-Only Access**
   - Database user with SELECT-only permissions
   - No INSERT, UPDATE, DELETE capabilities
   - Connection string secured via environment variables

2. **Query Limits**
   - Maximum time range restrictions (e.g., 1 year)
   - Query timeout limits (e.g., 30 seconds)
   - Result set size limits

3. **Tenant Isolation**
   - Consider whether users should access all tenants or be restricted
   - Implement tenant filtering if multi-tenant access is needed

### Performance

1. **Existing Aggregations**
   - Leverage `telemetry_15min_agg` continuous aggregate
   - Use `daily_energy_cost_summary` for cost queries
   - Avoid raw `telemetry_data` queries when possible

2. **Query Optimization**
   - Pre-built parameterized queries
   - Proper index utilization
   - TimescaleDB chunk pruning

3. **Caching (Optional)**
   - Consider caching for frequently accessed reference data
   - Device lists, tenant lists, quantity codes

### Implementation Options

| Approach | Language | Pros | Cons |
|----------|----------|------|------|
| Python + `mcp` SDK | Python | Official SDK, mature ecosystem | Requires Python runtime |
| TypeScript + `@modelcontextprotocol/sdk` | TypeScript | Official SDK, npm ecosystem | Node.js runtime |
| Direct stdio | Any | Flexible, lightweight | Manual protocol handling |

**Recommendation:** Python with `mcp` SDK, given the existing Python project structure.

---

## Existing Database Functions to Leverage

The database already has useful functions that could be wrapped by MCP tools:

| Existing Function | Potential MCP Tool |
|-------------------|-------------------|
| `get_15min_telemetry_for_user` | `get_device_energy` |
| `get_bucketed_telemetry_for_user` | `get_device_energy` (aggregated) |
| `get_telemetry_statistics_for_user` | `get_device_stats` |
| `get_quantities_interval` | `get_interval_consumption` |
| `refresh_daily_energy_costs` | Reference for cost logic |
| `get_shift_period` | `get_shift_info` |
| `get_all_downstream_assets` | `get_device_hierarchy` |

---

## Implementation Phases

### Phase 1: Foundation & Data Mapping

**Goal:** Establish the semantic layer that maps database quantities to human-readable metrics.

| Deliverable | Description |
|-------------|-------------|
| Quantities Mapping | Document all `quantities` entries with semantic categorization (WAGE) |
| Metric Aliases | Map natural language terms → quantity IDs (e.g., "energy" → [62, 89, 96, 124, 130, 481]) |
| Aggregation Rules | Define how each quantity type should be aggregated (SUM, AVG, MAX, MIN) |
| Unit Conversions | Handle unit display (kW, MW, kWh, m³, etc.) |

**Phase 1 Tools:**
- `list_quantities` - Browse available metrics with categories and units
- `list_devices` - Browse devices with fuzzy search
- `list_tenants` - Browse available tenants

**Reference:** See [quantities-mapping.md](./quantities-mapping.md) for the complete mapping specification.

### Phase 2: Core Query Tools

**Goal:** Implement device and group-level queries across all WAGE categories.

| Tool | Supported Metrics |
|------|-------------------|
| `get_device_telemetry` | Any quantity - energy, power, voltage, current, flow, pressure, etc. |
| `get_group_telemetry` | Aggregate by tag/asset hierarchy |
| `get_peak_analysis` | Peak demand (power), peak flow, etc. |
| `get_cost_summary` | Energy costs with time-of-use rates |

**Phase 2 Features:**
- Smart time range selection (auto-select `telemetry_data` vs `telemetry_15min_agg`)
- Adaptive bucketing based on query duration
- Fuzzy device matching with disambiguation
- Multi-quantity queries (e.g., "show power and power factor")

### Phase 3: Advanced Analytics

**Goal:** Comparative analysis, trends, and insights.

| Tool | Purpose |
|------|---------|
| `compare_devices` | Side-by-side device comparison |
| `get_trend_analysis` | Period-over-period comparisons |
| `detect_anomalies` | Flag unusual consumption patterns |
| `get_power_quality` | Voltage/current unbalance, power factor analysis |
| `export_data` | CSV/JSON export for external analysis |

### Phase 4: Production Readiness

**Goal:** Multi-tenant authentication and web interface.

- Web-based chat UI with tenant isolation
- Authentication using repurposed `auth_*` tables
- Rate limiting (if needed based on Phase 2-3 monitoring)
- Audit logging

---

## Design Decisions

### Architecture Overview

The final product is a **two-tiered solution**:

```
┌─────────────────────────────────────────────────────────────┐
│                    Web-Based Chat UI                         │
│            (Primary User Interface - like Claude Web)        │
│                 - Tenant-isolated authentication             │
│                 - Repurposed auth_* tables                   │
└─────────────────────┬───────────────────────────────────────┘
                      │ API Calls
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                      MCP Server                              │
│               (Linux VPS - same as PostgreSQL)               │
│                   - Multi-user support                       │
│                   - 99.9% uptime target                      │
└─────────────────────┬───────────────────────────────────────┘
                      │ PostgreSQL Protocol
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   Valkyrie Database                          │
│               (PostgreSQL + TimescaleDB)                     │
└─────────────────────────────────────────────────────────────┘
```

**Prototyping Phase:** Skip authentication and access control for proof-of-concept.

**Value Proposition:** Natural language accessibility complementing existing Grafana dashboards and raw SQL queries.

---

### Data Source Strategy

#### Telemetry Tables

| Table | Granularity | Retention | Use Case |
|-------|-------------|-----------|----------|
| `telemetry_data` | 5-second | 14 days | Short queries (< 24 hours) |
| `telemetry_15min_agg` | 15-minute | 2 years | Medium/long queries (> 24 hours) |

#### Smart Time Range Query Strategy

No hard limits on time range. Instead, implement **adaptive bucketing**:

| Query Duration | Data Source | Default Aggregation |
|----------------|-------------|---------------------|
| ≤ 4 hours | `telemetry_data` | Raw 5-second intervals |
| 4 hours - 24 hours | `telemetry_data` | 15-minute buckets |
| 1 day - 1 week | `telemetry_15min_agg` | Hourly buckets |
| 1 week - 1 month | `telemetry_15min_agg` | Daily buckets |
| > 1 month | `telemetry_15min_agg` | Weekly buckets |

**Drill-down Support:** Present high-level aggregation first, allow users to request finer granularity.

---

### Device & Entity Resolution

#### Device Identification

- **User-facing:** Query by `display_name` (human-readable)
- **Internal:** Resolve to `devices.id` (primary key for all relationships)
- **Fuzzy Matching:** Required - users may type "pump 1", "Pump-1", or "PUMP1"

> **Implementation Note:** Fuzzy matching must handle prefix conflicts. Example: "MC-1" query should NOT match "MC-10". Consider using word boundary matching or ranked results with disambiguation.

#### Device Grouping

Use `tags` table for logical groupings:
- Groups by process, building, area, etc.
- Admin-created (not user-created)
- Devices can have multiple tags

---

### Telemetry Scope (WAGE)

MCP covers **all telemetry types**, not just energy:

| Category | Example Quantities | Use Cases |
|----------|-------------------|-----------|
| **W**ater | Flow rate, volume | Consumption tracking |
| **A**ir | Pressure, flow | Compressed air systems |
| **G**as | Volume, flow rate | Natural gas consumption |
| **E**lectricity | Active power, energy, PF, current, voltage | Peak load, power quality, consumption |

#### Quantity Resolution

- `quantities` table maps `id` → `quantity_name`
- Implement semantic mapping: "energy consumption" → relevant quantity IDs
- `daily_energy_cost_summary` provides pre-calculated energy costs with time-of-use rates

---

### Timezone Handling

| Layer | Timezone | Notes |
|-------|----------|-------|
| Database storage | UTC | All timestamps in UTC |
| User display | Asia/Jakarta (WIB, UTC+7) | Convert on output |
| Query input | Asia/Jakarta | Convert to UTC for queries |

---

### Response Behavior

| Aspect | Default Behavior | User Override |
|--------|------------------|---------------|
| Format | Text and tables | Charts/visualizations on request |
| Detail level | Individual data points | Summarize by week/month/quarter on request |
| Calculation explanation | Hidden | Show on explicit request |

---

### Database Schema Strategy

| Schema | Owner | Purpose |
|--------|-------|---------|
| `prs.*` | Backend team | Tenant-specific (PRS) calculations |
| `iop.*` | Backend team | Tenant-specific (IOP) calculations |
| `mcp.*` | MCP project | New query logic for MCP tools |

**Principle:** Reuse existing database functions where possible. Grafana dashboard queries can be adapted.

---

### Error Handling

#### Data Gaps

Data gaps occur due to:
1. **Partial transmission:** Modbus noise causes incomplete data for a time period
2. **Total outage:** Edge server power loss (connectivity loss is buffered and synced later)

**Handling:** Return `NULL` for missing data, **never zero**.

> Zero is a valid measurement (e.g., 0 Ampere during scheduled downtime). Null indicates no data available.

#### Ambiguous Queries

When fuzzy matching returns multiple devices:
1. Present ranked list of matches to user
2. Ask for clarification before proceeding
3. Show device context (tenant, location, tags) to help disambiguation

---

### Rate Limiting (TBD)

Rate limiting is under consideration. Factors to evaluate:

| Pros | Cons |
|------|------|
| Prevents runaway queries | Adds complexity |
| Protects database performance | May frustrate legitimate use |
| Ensures fair multi-user access | Requires tuning thresholds |

**Decision:** Defer to implementation phase. Monitor query patterns first.

---

### Security

- **Access Control:** All tenant data accessible to authenticated tenant users
- **No sensitive fields:** No field exclusions required
- **Read-only:** MCP uses SELECT-only database permissions

---

## Evaluation Summary

### Feasibility: HIGH

- Database schema is well-documented
- Existing aggregation tables reduce query complexity
- TimescaleDB optimizations in place
- Existing functions provide proven query patterns

### Complexity: MEDIUM

- Multi-tenant architecture requires careful access control
- Device/asset hierarchy adds resolution complexity
- Time-of-use rates and shift periods add business logic

### Value: HIGH

- Reduces engineer time on routine queries
- Enables self-service for common questions
- Claude's natural language understanding maps well to these use cases

### Recommended Next Steps

1. Answer the open questions above
2. Define the initial tool set (Phase 1 scope)
3. Set up a read-only database user for MCP
4. Create a proof-of-concept with 1-2 tools
5. Test with real user questions
6. Iterate based on feedback

---

## References

- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Database Schema](schema/full-schema.sql)
- [Database README](schema/DB_README.md)

---

**Document Status:** Design decisions finalized, ready for implementation
**Next Action:** Initialize beads and create Phase 1 task breakdown
