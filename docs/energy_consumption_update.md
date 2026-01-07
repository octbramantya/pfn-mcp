# Energy Consumption Tool - Implementation Plan

> Reference document for implementing `get_energy_consumption` tool

## Problem Summary

`get_device_telemetry` returns cumulative meter readings for energy quantities instead of actual consumption. The tool ignores `is_cumulative` flag and applies AVG/MIN/MAX on cumulative values.

**Example from `docs/playground/energy_consumption.md`:**
- User asked for daily energy consumption
- Tool returned cumulative readings (~36M kWh)
- Manual calculation required: `MAX - MIN` per day to get actual consumption

## Solution Overview

1. **New tool**: `get_energy_consumption` - smart data source selection:
   - Daily+ buckets: `daily_energy_cost_summary` (fast, pre-materialized, includes cost)
   - Sub-daily buckets: `telemetry_intervals_cumulative` (view, on-the-fly, includes cost)
2. **Fix existing**: Add warning in `get_device_telemetry` for cumulative quantities
3. **Default behavior**: "energy" = Active Energy (quantity 124 or 131, auto-detect per device)

## Key Design Decisions

### Cost Calculation Logic

Same logic as `refresh_daily_energy_costs` database function:
- Use `get_utility_rate(tenant_id, device_id, timestamp)` to get rate_per_unit for each interval
- Calculate `cost = consumption * rate_per_unit`
- Function is `STABLE` and efficient (simple joins with time-of-use logic)

### Data Sources

| Query Type | Bucket | Data Source | Cost Included |
|------------|--------|-------------|---------------|
| Summary | 1day, 1week | `daily_energy_cost_summary` | Yes (pre-calculated) |
| Detail | 15min, 1hour, 4hour | `telemetry_intervals_cumulative` + `get_utility_rate()` | Yes (calculated inline) |

---

## Phase 1: New `get_energy_consumption` Tool

### 1.1 Create `src/pfn_mcp/tools/energy_consumption.py`

**Key functionality:**
- Query `telemetry_intervals_cumulative` view (not `telemetry_15min_agg`)
- Use `SUM(interval_value)` for consumption aggregation
- Filter `WHERE data_quality_flag = 'NORMAL'` by default
- Support optional `include_quality_info` parameter
- Reuse helpers from telemetry.py: `parse_period`, `select_bucket`, `_resolve_device_id`, `_resolve_quantity_id`

**Constants:**
```python
# Must match telemetry_intervals_cumulative view
CUMULATIVE_QUANTITY_IDS = {62, 89, 96, 124, 130, 131, 481}

# Active Energy = default for "energy" queries
# 124 = Active Energy Delivered, 131 = Active Energy Received
# Device-specific: some use 124, some use 131 based on modbus setup
ACTIVE_ENERGY_IDS = {124, 131}

# Energy quantity aliases for search
ENERGY_ALIASES = {
    "energy": ACTIVE_ENERGY_IDS,           # Default: Active Energy
    "active energy": ACTIVE_ENERGY_IDS,
    "reactive energy": {89, 96},
    "apparent energy": {62, 481},
}
```

**Device-specific quantity handling:**
- Different devices use different quantity IDs for Active Energy (124 vs 131)
- When `quantity_search="energy"` without explicit ID, auto-detect which ID the device has data for
- Query `telemetry_intervals_cumulative` to find which energy quantity exists for the device:

```python
async def _detect_energy_quantity(device_id: int) -> int | None:
    """Find which active energy quantity ID this device uses."""
    row = await db.fetch_one("""
        SELECT DISTINCT quantity_id
        FROM telemetry_intervals_cumulative
        WHERE device_id = $1 AND quantity_id IN (124, 131)
        LIMIT 1
    """, device_id)
    return row["quantity_id"] if row else None
```

**Smart Data Source Selection** (performance optimization):

| Bucket Size | Data Source | Reason |
|-------------|-------------|--------|
| `1day`, `1week` | `daily_energy_cost_summary` | Pre-materialized table, fast |
| `15min`, `1hour`, `4hour` | `telemetry_intervals_cumulative` | View, calculates on-the-fly |

```python
def select_energy_data_source(bucket: str) -> str:
    if bucket in ("1day", "1week"):
        return "daily_energy_cost_summary"  # Fast, pre-calculated
    else:
        return "telemetry_intervals_cumulative"  # Sub-daily granularity
```

**Query for daily+ buckets** (fast - uses materialized table, includes cost):
```sql
-- daily_energy_cost_summary has SHIFT_RATE grouping, SUM across shifts/rates
SELECT
    daily_bucket as time_bucket,
    SUM(total_consumption) as consumption,
    SUM(total_cost) as cost,
    COUNT(DISTINCT shift_period) as shift_count,
    COUNT(DISTINCT rate_code) as rate_count
FROM daily_energy_cost_summary
WHERE device_id = $1
  AND quantity_id = $2
  AND daily_bucket >= $3 AND daily_bucket < $4
GROUP BY daily_bucket
ORDER BY daily_bucket
```

**Query for sub-daily buckets** (view + inline cost calculation):
```sql
-- Same logic as refresh_daily_energy_costs but inline
WITH interval_data AS (
    SELECT
        time_bucket($1::interval, tic.bucket) as time_bucket,
        tic.bucket as timestamp_sample,
        tic.tenant_id,
        tic.device_id,
        tic.interval_value
    FROM telemetry_intervals_cumulative tic
    WHERE tic.device_id = $2
      AND tic.quantity_id = $3
      AND tic.bucket >= $4 AND tic.bucket < $5
      AND tic.data_quality_flag = 'NORMAL'
),
with_rates AS (
    SELECT
        id.*,
        (SELECT rate_per_unit FROM get_utility_rate(id.tenant_id, id.device_id, id.timestamp_sample) LIMIT 1) as rate_per_unit,
        (SELECT rate_code FROM get_utility_rate(id.tenant_id, id.device_id, id.timestamp_sample) LIMIT 1) as rate_code
    FROM interval_data id
)
SELECT
    time_bucket,
    SUM(interval_value) as consumption,
    SUM(interval_value * COALESCE(rate_per_unit, 0)) as cost,
    COUNT(*) as interval_count,
    array_agg(DISTINCT rate_code) as rate_codes
FROM with_rates
GROUP BY time_bucket
ORDER BY time_bucket
```

### 1.2 Add schema to `tools.yaml`

```yaml
- name: get_energy_consumption
  tenant_aware: true
  description: >-
    Get energy consumption for a device.
    Returns actual consumption (not meter readings) calculated from interval deltas.
    Handles meter resets and data anomalies automatically.
    For non-energy quantities, use get_device_telemetry instead.
  params:
    - name: device_id
      type: integer
      description: Device ID (preferred over device_name)
    - name: device_name
      type: string
      description: Device name (fuzzy search)
    - name: quantity_id
      type: integer
      description: "Energy quantity ID (e.g., 124 for Active Energy Delivered)"
    - name: quantity_search
      type: string
      description: "Quantity search: energy, active energy, reactive energy, apparent energy"
    - name: period
      type: string
      description: "Time period: 1h, 24h, 7d, 30d, 3M, 1Y"
    - name: start_date
      type: string
      description: Start date (ISO format, alternative to period)
    - name: end_date
      type: string
      description: End date (ISO format, defaults to now)
    - name: bucket
      type: string
      description: "Bucket size: 15min, 1hour, 4hour, 1day, 1week, auto"
      default: auto
    - name: include_quality_info
      type: boolean
      description: "Include data quality breakdown in response (default: false)"
      default: false
```

### 1.3 Add handler to `server.py`

Import and add call_tool handler for `get_energy_consumption`.

---

## Phase 2: Fix `get_device_telemetry` Warning

### 2.1 Modify `telemetry.py`

1. Add `CUMULATIVE_QUANTITY_IDS` constant
2. Update `_resolve_quantity_id` to include `is_cumulative` in SELECT
3. In `get_device_telemetry`, detect cumulative quantities and add warning:

```python
if is_cumulative:
    result["warning"] = {
        "type": "cumulative_quantity",
        "message": "Values shown are meter readings, not consumption. Use get_energy_consumption for actual consumption.",
        "recommendation": "get_energy_consumption",
    }
```

### 2.2 Update `format_telemetry_response`

Display warning in human-readable output.

---

## Phase 3: Update Documentation

### 3.1 Update `tools.yaml` description for `get_device_telemetry`

Add note: "For energy quantities, use `get_energy_consumption` instead."

### 3.2 Update `CLAUDE.md`

Add `get_energy_consumption` to Available Tools table.

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/pfn_mcp/tools/energy_consumption.py` | **NEW** - Core tool implementation |
| `src/pfn_mcp/tools/telemetry.py` | Add cumulative detection + warning |
| `src/pfn_mcp/tools.yaml` | Add new tool schema, update telemetry description |
| `src/pfn_mcp/server.py` | Add handler for new tool |
| `CLAUDE.md` | Update available tools documentation |

---

## Response Format Examples

**Daily bucket response (includes cost):**
```
## Energy Consumption: Incoming Factory A&B
**Quantity**: Active Energy Delivered
**Period**: 2026-01-01 to 2026-01-04 (WIB)
**Bucket**: 1day (4 points)

### Summary
- **Total Consumption**: 130,480.00 kWh
- **Total Cost**: Rp 145,234,560

### Daily Breakdown
| Date       | Consumption | Cost           |
|------------|-------------|----------------|
| 2026-01-01 | 6,488 kWh   | Rp 7,234,567   |
| 2026-01-02 | 41,784 kWh  | Rp 46,543,210  |
| 2026-01-03 | 42,784 kWh  | Rp 47,654,321  |
| 2026-01-04 | 39,424 kWh  | Rp 43,802,462  |
```

**Hourly bucket response (with cost):**
```
## Energy Consumption: Incoming Factory A&B
**Quantity**: Active Energy Delivered
**Period**: 2026-01-04 00:00 to 2026-01-04 12:00 (WIB)
**Bucket**: 1hour (12 points)

### Summary
- **Total Consumption**: 3,245.67 kWh
- **Total Cost**: Rp 3,567,234

### Hourly Breakdown
| Time  | Consumption | Cost        | Rate  |
|-------|-------------|-------------|-------|
| 00:00 | 256.45 kWh  | Rp 265,678  | LWBP2 |
| 01:00 | 248.32 kWh  | Rp 257,234  | LWBP2 |
...
| 18:00 | 312.56 kWh  | Rp 485,432  | WBP   |  (peak rate)
...
```

---

## Database References

### telemetry_intervals_cumulative view
Provides clean interval consumption calculated from cumulative meter readings:
- `interval_value`: Consumption per 15-min interval (delta)
- `cumulative_value`: Raw meter reading
- `data_quality_flag`: NORMAL, DATA_ANOMALY, DEVICE_RESET_EVENT, etc.

### daily_energy_cost_summary table
Pre-calculated daily consumption and cost:
- `total_consumption`: Sum of interval consumption
- `total_cost`: Calculated with utility rates
- Grouped by: device, quantity, shift_period, rate_code

### get_utility_rate() function
Looks up rate for a timestamp:
- Input: tenant_id, device_id, timestamp
- Output: rate_per_unit, rate_code, utility_source_id
- Uses time-of-use logic (WBP = 18-22, LWBP1 = 22-0, LWBP2 = 0-18)

---

## Implementation Order

1. Create `energy_consumption.py` module
2. Add schema to `tools.yaml`
3. Add handler to `server.py`
4. Add warning to `telemetry.py`
5. Update documentation
6. Run `/tool-update` skill
7. Test with sample queries
