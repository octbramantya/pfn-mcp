# Phase 2 Telemetry Tools Extension

## Overview

This document extends the Phase 2 tools from `phase2-telemetry.md` with:
1. **Peak Analysis Tool** - Find peaks with timestamps
2. **Extended Group Telemetry** - Support all WAGE quantities, not just electricity cost

**Note**: `get_cost_summary` from concept.md is already covered by existing `get_electricity_cost` family.

**Related beads**:
- `pfn_mcp-l5z` - Phase 2: Telemetry Tools Extension (feature)
- `pfn_mcp-3tr` - Create get_peak_analysis tool (task)
- `pfn_mcp-86y` - Extend get_group_telemetry for all WAGE quantities (task)
- `pfn_mcp-rc5` - Register Phase 2 tools in server.py (task)

---

## 1. New Tool: `get_peak_analysis`

**Purpose**: Find peak values per time period with exact timestamps of when they occurred.

**Use Case**: "Daily peak power for Waterjet process last 30 days"

### Parameters

```python
async def get_peak_analysis(
    # Device (single)
    device_id: int | None = None,
    device_name: str | None = None,

    # Group (alternative)
    tag_key: str | None = None,
    tag_value: str | None = None,
    asset_id: int | None = None,

    # Quantity
    quantity_id: int | None = None,
    quantity_search: str | None = None,  # "power", "voltage", "current"

    # Time
    period: str | None = None,
    start_date: str | None = None,
    end_date: str | None = None,

    # Bucketing
    granularity: Literal["hour", "day", "week"] = "day",

    # Breakdown (for groups)
    breakdown: Literal["none", "device_daily"] = "none",
) -> dict
```

### Response for Single Device

```json
{
  "device": {"id": 101, "name": "WJL 1"},
  "quantity": {"id": 185, "name": "Active Power", "unit": "kW"},
  "granularity": "day",
  "peaks": [
    {"bucket": "2025-01-01", "peak_value": 150.5, "peak_timestamp": "2025-01-01T14:30:00"},
    {"bucket": "2025-01-02", "peak_value": 145.2, "peak_timestamp": "2025-01-02T11:15:00"}
  ],
  "overall_peak": {"value": 150.5, "timestamp": "2025-01-01T14:30:00"}
}
```

### Response for Group

Shows each device's peak (different power ratings make aggregate peak less meaningful):

```json
{
  "group": {"type": "tag", "label": "process=Waterjet", "device_count": 4},
  "quantity": {"id": 185, "name": "Active Power", "unit": "kW"},
  "period": "2025-01-01 to 2025-01-31",
  "device_peaks": [
    {"device": "WJL 1", "device_id": 101, "peak_value": 150.0, "peak_timestamp": "2025-01-01T14:30"},
    {"device": "WJL 2", "device_id": 102, "peak_value": 180.0, "peak_timestamp": "2025-01-05T09:15"},
    {"device": "WJL 3", "device_id": 103, "peak_value": 145.0, "peak_timestamp": "2025-01-03T16:00"}
  ],
  "group_peak": {"value": 180.0, "device": "WJL 2", "timestamp": "2025-01-05T09:15"}
}
```

### Optional Breakdown (`breakdown="device_daily"`)

When specified, shows each device's peak per day (useful for comparing load patterns):

```json
{
  "breakdown": [
    {"device": "WJL 1", "bucket": "2025-01-01", "peak_value": 148.0, "peak_timestamp": "..."},
    {"device": "WJL 1", "bucket": "2025-01-02", "peak_value": 150.0, "peak_timestamp": "..."},
    {"device": "WJL 2", "bucket": "2025-01-01", "peak_value": 175.0, "peak_timestamp": "..."}
  ]
}
```

### Key SQL Pattern

```sql
-- Peak per day with timestamp (finds the 15-min bucket with highest max_value per day)
WITH ranked AS (
    SELECT
        date_trunc('day', bucket) as day_bucket,
        bucket as peak_timestamp,
        device_id,
        max_value,
        ROW_NUMBER() OVER (
            PARTITION BY date_trunc('day', bucket)
            ORDER BY max_value DESC
        ) as rn
    FROM telemetry_15min_agg
    WHERE device_id = ANY($1::int[])
      AND quantity_id = $2
      AND bucket >= $3 AND bucket < $4
)
SELECT day_bucket, peak_timestamp, max_value, device_id
FROM ranked WHERE rn = 1
ORDER BY day_bucket;
```

---

## 2. Extended: `get_group_telemetry`

**Current**: Only electricity via `daily_energy_cost_summary`
**Extended**: Support any WAGE quantity via `telemetry_15min_agg`

### New Parameters

```python
async def get_group_telemetry(
    # Existing group parameters...
    tag_key: str | None = None,
    tag_value: str | None = None,
    asset_id: int | None = None,

    # NEW: Quantity parameters
    quantity_id: int | None = None,
    quantity_search: str | None = None,  # "voltage", "power", "water"

    # Existing time/breakdown parameters...
) -> dict
```

### Behavior

- If `quantity_id`/`quantity_search` provided → Query `telemetry_15min_agg`
- If not provided → Use existing `daily_energy_cost_summary` logic (backwards compatible)

### Aggregation Rules

| Quantity Type | Aggregation |
|---------------|-------------|
| Instantaneous (power, voltage) | AVG of avgs, MAX of maxes, MIN of mins |
| Cumulative (energy, volume) | SUM of sums |

### New Response Shape (when quantity specified)

```json
{
  "group": {"type": "tag", "label": "building=Factory A", "result_type": "aggregated_group", "devices": [...]},
  "quantity": {"id": 185, "name": "Active Power", "unit": "kW"},
  "summary": {
    "avg_value": 234.5,
    "max_value": 1500.0,
    "min_value": 50.2,
    "period": "2025-01-01 to 2025-01-07"
  },
  "breakdown": [...]
}
```

---

## Files to Modify

| File | Action |
|------|--------|
| `src/pfn_mcp/tools/peak_analysis.py` | **CREATE** - New peak analysis tool |
| `src/pfn_mcp/tools/group_telemetry.py` | **MODIFY** - Add quantity parameters and telemetry_15min_agg query path |
| `src/pfn_mcp/server.py` | **MODIFY** - Register new tool, update get_group_telemetry schema |

---

## Implementation Sequence

### Step 1: Create `peak_analysis.py`

1. Create new file with:
   - `get_peak_analysis()` function
   - `format_peak_analysis_response()` formatter
   - Reuse `_resolve_tag_devices()` and `_resolve_asset_devices()` from group_telemetry.py
   - Reuse `_resolve_quantity_id()` pattern from telemetry.py

2. Key implementation details:
   - Use window function (ROW_NUMBER) to find peak timestamp per bucket period
   - For groups: find peak across all devices, return which device had it
   - Return both per-period peaks AND overall peak

### Step 2: Extend `group_telemetry.py`

1. Add quantity resolution:
   - Import/copy `_resolve_quantity_id()` helper
   - Add `quantity_id` and `quantity_search` parameters

2. Add branching logic in `get_group_telemetry()`:
   ```python
   if quantity_id or quantity_search:
       # NEW: Query telemetry_15min_agg
       return await _get_quantity_group_telemetry(...)
   else:
       # EXISTING: Use daily_energy_cost_summary
       # (current implementation)
   ```

3. Create `_get_quantity_group_telemetry()` helper:
   - Query telemetry_15min_agg with device IDs from group
   - Aggregate using appropriate method based on quantity type
   - Support device and daily breakdowns

4. Update `format_group_telemetry_response()`:
   - Handle new response shape when quantity is specified
   - Show quantity name and unit in output

### Step 3: Update `server.py`

1. Add `get_peak_analysis` tool registration
2. Update `get_group_telemetry` tool schema with quantity parameters
3. Add call handler for `get_peak_analysis`

---

## Testing Checklist

- [ ] Peak analysis - single device, daily granularity
- [ ] Peak analysis - device group, returns each device's peak
- [ ] Peak analysis - hourly and weekly granularity
- [ ] Peak analysis - device_daily breakdown
- [ ] Group telemetry - no quantity (backwards compatible, electricity)
- [ ] Group telemetry - instantaneous quantity (voltage: AVG aggregation)
- [ ] Group telemetry - cumulative quantity (water volume: SUM aggregation)
- [ ] Group telemetry - device breakdown for quantities
- [ ] Error handling - invalid quantity for group
- [ ] Error handling - no data for requested quantity

---

## Future Features (Out of Scope for Now)

These features can be added incrementally, building on the current and planned tools:

| Feature | Integration Approach | Potential Tool/Extension |
|---------|---------------------|--------------------------|
| **Percentiles** | Extend peak analysis | Add `include_percentiles=true` → returns p50, p75, p90, p95 in summary |
| **Rolling Averages** | Extend `get_device_telemetry` | Add `rolling_window="7d"` → adds smoothed values to data points |
| **Trend Analysis** | Extend telemetry tools | Add `include_trend=true` → returns `trend: {slope, direction, r_squared}` |
| **Anomaly Detection** | New specialized tool | `detect_anomalies(device/group, quantity, method="zscore"/"iqr")` |
| **Forecasting** | New specialized tool | `forecast_telemetry(device/group, quantity, horizon="7d")` - requires time-series models |

**Integration Pattern**:
- Simple stats (percentiles, rolling avg): Parameter extensions to existing tools
- Analysis features (anomaly, trend): Can be new tools OR mode parameters
- Predictive (forecast): Separate tool with more complexity (Phase 3+)
