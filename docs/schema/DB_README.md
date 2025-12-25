# Valkyrie Database Documentation

## Overview

This is the reference documentation for the **Valkyrie** PostgreSQL database, which uses TimescaleDB for time-series data management. The database powers an energy monitoring and cost analysis system for multi-tenant industrial facilities.

**Database Details:**
- **Server:** 88.222.213.96
- **Database:** valkyrie
- **PostgreSQL Version:** 16.10
- **Extensions:** TimescaleDB, pgAgent, pg_cron
- **Primary Timezone:** Asia/Jakarta (stored as UTC)

## Database Architecture

### Core Data Pipeline

The system follows this data flow for energy cost calculations:

```
telemetry_data (raw sensor data)
  ↓
  ↓ [TimescaleDB Continuous Aggregate - 15min intervals]
  ↓
telemetry_15min_agg (materialized hypertable)
  ↓
  ↓ [View - cumulative calculations]
  ↓
telemetry_intervals_cumulative (view)
  ↓
  ↓ [refresh_daily_energy_costs() function]
  ↓
daily_energy_cost_summary (final aggregated table)
```

### Key Components

1. **Time-Series Data:** Raw telemetry stored in hypertables with automatic partitioning
2. **Continuous Aggregates:** Automatic 15-minute rollups with configurable refresh policies
3. **Cost Calculation:** Multi-tenant energy cost analysis with time-of-use rates and shift periods
4. **Automated Jobs:** pgAgent schedules for backfill and periodic refresh operations

## Documentation Structure

### 📂 [schema/](./schema/)
Database schema documentation including tables, views, and constraints.

- **[full-schema.sql](./schema/full-schema.sql)** - Complete schema dump (auto-generated)
- **tables.md** *(coming soon)* - Table definitions with descriptions
- **views.md** *(coming soon)* - Views and their purposes
- **continuous-aggregates.md** *(coming soon)* - TimescaleDB continuous aggregates
- **relationships.md** *(coming soon)* - Foreign key relationships and ER diagrams

### 📂 [functions/](./functions/)
Stored procedures and functions documentation.

- **overview.md** *(coming soon)* - Index of all database functions
- **energy-costs.md** *(coming soon)* - Energy cost calculation functions
- **utility-rates.md** *(coming soon)* - Utility rate lookup functions
- **shift-management.md** *(coming soon)* - Shift period functions

### 📂 [jobs/](./jobs/)
Scheduled jobs and maintenance tasks.

- **pgagent-jobs.md** *(coming soon)* - All pgAgent scheduled jobs
- **maintenance.md** *(coming soon)* - Backup, vacuum, and other maintenance tasks

### 📄 Additional Documentation
- **data-dictionary.md** *(coming soon)* - Business meaning of key fields
- **common-queries.md** *(coming soon)* - Frequently used query patterns
- **architecture.md** *(coming soon)* - Detailed data flow diagrams

## Quick Reference

### Core Tables

| Table | Purpose | Key Info |
|-------|---------|----------|
| `tenants` | Multi-tenant organization data | Supports multiple industrial facilities |
| `devices` | IoT devices and sensors | Linked to tenants, provides telemetry |
| `telemetry_data` | Raw time-series data | TimescaleDB hypertable, partitioned by time |
| `telemetry_15min_agg` | 15-minute aggregates | Continuous aggregate, auto-refreshed |
| `daily_energy_cost_summary` | Daily cost rollups | Main reporting table |
| `tenant_shift_periods` | Work shift definitions | Supports cross-midnight shifts |
| `utility_sources` | Utility providers (PLN, etc.) | Grid, generator, solar, etc. |
| `utility_rates` | Time-of-use electricity rates | Indonesian PLN tariff structure |
| `device_utility_mappings` | Links devices to utility sources | Priority-based for multiple sources |

### Key Functions

| Function | Purpose |
|----------|---------|
| `refresh_daily_energy_costs()` | Processes 3-day rolling window for daily summary |
| `refresh_daily_energy_costs_with_logging()` | Same as above with execution logging |
| `get_utility_rate()` | Returns applicable utility rate for tenant/device/timestamp |
| `get_shift_period()` | Determines shift based on hour and tenant |

### Active Scheduled Jobs

| Job ID | Name | Schedule | Purpose |
|--------|------|----------|---------|
| 3 | Backfill Telemetry 15min Aggregate | Daily 01:00 | Backfills 7 days to catch late data |
| 4 | Refresh Daily Energy Cost Summary | Every 30 min | Updates daily cost summary table |

## Common Use Cases

### Querying Energy Costs
```sql
-- Get daily energy costs for a tenant
SELECT
    daily_bucket AT TIME ZONE 'Asia/Jakarta' as date,
    device_id,
    shift_name,
    energy_kwh,
    total_cost_idr
FROM daily_energy_cost_summary
WHERE tenant_id = 3
  AND daily_bucket >= '2025-11-01'
ORDER BY daily_bucket, device_id;
```

### Checking Data Gaps
```sql
-- Find missing days in telemetry aggregates
SELECT
    d.date,
    COUNT(ta.*) as record_count
FROM generate_series('2025-11-01'::date, CURRENT_DATE, '1 day') d(date)
LEFT JOIN telemetry_15min_agg ta
    ON date_trunc('day', ta.bucket) = d.date
    AND ta.tenant_id = 3
GROUP BY d.date
HAVING COUNT(ta.*) = 0
ORDER BY d.date;
```

### Viewing Job Execution History
```sql
-- Check pgAgent job runs
SELECT
    j.jobname,
    l.jlgstart as start_time,
    l.jlgduration as duration,
    l.jlgstatus as status
FROM pgagent.pga_joblog l
JOIN pgagent.pga_job j ON l.jlgjobid = j.jobid
ORDER BY l.jlgstart DESC
LIMIT 20;
```

## Maintenance Notes

### Continuous Aggregate Refresh
The `telemetry_15min_agg` continuous aggregate has a 1-hour lookback window (Job ID 1004, runs every 5 minutes). A separate daily backfill job (Job ID 3) handles late-arriving data with a 7-day window.

### Known Issues
- **Late-arriving data:** Network outages can cause data gaps. The daily backfill job mitigates this.
- **Circular FK constraints:** TimescaleDB internal tables have circular constraints (normal behavior).

## How to Use This Documentation

### For Development
1. Start with this README for overview
2. Reference `schema/full-schema.sql` for exact table definitions
3. Check `functions/` for stored procedure logic
4. Use `common-queries.md` for query patterns

### For AI Assistant (Claude Code) Sessions
Include relevant documentation in your prompts:
- "Read docs/database/README.md for database overview"
- "Read docs/database/schema/full-schema.sql and search for table X"
- "Reference docs/database/functions/energy-costs.md for cost calculation logic"

### For Maintenance
1. Review `jobs/pgagent-jobs.md` for scheduled tasks
2. Check `maintenance.md` for backup and recovery procedures
3. Monitor `daily_energy_refresh_log` table for job execution status

## Getting Started

### Connecting to the Database
```bash
# Using psql
psql -h 88.222.213.96 -U postgres -d valkyrie

# Using pg_dump (requires PostgreSQL 16 client)
pg_dump -h 88.222.213.96 -U postgres -d valkyrie --schema-only
```

### Useful System Queries
```sql
-- List all hypertables
SELECT * FROM timescaledb_information.hypertables;

-- List continuous aggregates
SELECT * FROM timescaledb_information.continuous_aggregates;

-- Check chunk statistics
SELECT * FROM timescaledb_information.chunks;

-- View active jobs
SELECT * FROM timescaledb_information.jobs;
```

## Version History

- **2025-11-17:** Initial documentation structure created
  - Generated full schema dump (17,134 lines)
  - Created directory structure
  - Added README with overview and navigation

## Contributing

When updating this documentation:
1. **Schema changes:** Re-run `pg_dump` to update `schema/full-schema.sql`
2. **New functions:** Document in appropriate `functions/` file
3. **New jobs:** Update `jobs/pgagent-jobs.md`
4. **Keep in sync:** Ensure documentation matches actual database state

## Support

For issues or questions:
- Review the documentation in this directory
- Check `daily_energy_refresh_log` for job execution logs
- Examine `pgagent.pga_joblog` for scheduled job status
- Consult TimescaleDB documentation: https://docs.timescale.com/

---

**Last Updated:** 2025-11-17
**Maintained By:** Database Team
**Database Version:** PostgreSQL 16.10 with TimescaleDB
