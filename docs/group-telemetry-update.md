# Group Telemetry Enhancement: Time-Series & Output Modes

## Problem

When `get_group_telemetry` returns multiple devices for instantaneous quantities (voltage, power, current):
1. AVGs all values across all devices and time into a single number (meaningless)
2. Shows percentage in device breakdown (nonsense for instantaneous values)
3. Loses device context for min/max

**Example:** 5 compressors, query "Voltage Phase A"
- Current: Returns `avg_value=225V` (useless - which machine is at 225V?)
- Expected: Per-device values: Comp-01=220V, Comp-02=230V, etc.

## Solution

Expand `get_group_telemetry` with new `output` parameter and smart handling for instantaneous quantities.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Output format | Time-aligned rows: `[{time, device_1, device_2, ...}]` |
| Row limit | Based on result rows (~200 max), not device count |
| Bucketing for instantaneous | Nearest-value to bucket START (not AVG) |
| Default output | `"summary"` (explicit request for detail) |
| Data source | Add smart selection (raw vs aggregated) |

## Output Parameter

```python
get_group_telemetry(
    tag_key="building",
    tag_value="Factory B",
    quantity_search="voltage",
    output="summary" | "timeseries" | "per_device"  # default: "summary"
)
```

### Output Modes

**`output="summary"` (default)** - Current behavior
```python
{
    "summary": {
        "average_value": 225.3,
        "min_value": 210.2,
        "max_value": 232.1,
    }
}
```

**`output="timeseries"`** - Time-aligned rows per device
```python
{
    "timeseries": [
        {"time": "2025-01-07T00:00", "Compressor-01": 220.5, "Compressor-02": 230.2},
        {"time": "2025-01-07T01:00", "Compressor-01": 221.0, "Compressor-02": 229.8},
    ],
    "devices": ["Compressor-01", "Compressor-02"],
    "bucket": "1hour",
    "point_count": 168,
}
```

**`output="per_device"`** - Per-device aggregation
```python
{
    "per_device": [
        {"device": "Compressor-01", "avg": 220.5, "min": 218.2, "max": 225.1},
        {"device": "Compressor-02", "avg": 230.2, "min": 227.8, "max": 232.5},
    ]
}
```

## Smart Bucketing

Calculate optimal bucket size to keep total result rows under ~200:

```python
def select_group_bucket(time_range: timedelta, device_count: int, max_rows: int = 200) -> str:
    """
    Select bucket size to keep total rows under limit.

    Example: 7 days, 5 devices
    - 15min: 672 buckets × 5 = 3360 rows (too many)
    - 1hour: 168 buckets × 5 = 840 rows (too many)
    - 4hour: 42 buckets × 5 = 210 rows (close)
    - 1day: 7 buckets × 5 = 35 rows (fits)
    """
    target_buckets = max_rows // device_count
    # Select smallest bucket that fits
```

## Nearest-Value Sampling (Instantaneous)

For instantaneous quantities (voltage, power, current), instead of AVG:

```sql
-- Pick 15-min bucket nearest to the START of each larger bucket
-- Example: For 1-hour bucket at 10:00, picks the 10:00 15-min bucket
SELECT DISTINCT ON (device_id, time_bucket($1, bucket))
    time_bucket($1, bucket) as time_bucket,
    device_id,
    aggregated_value as value
FROM telemetry_15min_agg
WHERE device_id = ANY($2)
  AND quantity_id = $3
  AND bucket >= $4
  AND bucket < $5
ORDER BY device_id, time_bucket($1, bucket),
         bucket ASC  -- Picks earliest (nearest to bucket start)
```

**Why nearest-value instead of AVG?**
- AVG of voltages over 1 hour (e.g., 220V, 225V, 223V, 221V) = 222.25V is meaningless
- Sampling at bucket start preserves actual readings at regular intervals
- More representative of what a user would see on a dashboard

## Files to Modify

| File | Changes |
|------|---------|
| `src/pfn_mcp/tools/group_telemetry.py` | Smart bucketing, nearest-value sampling, output param |
| `src/pfn_mcp/tools.yaml` | Add `output` parameter schema |
| `tests/test_phase2_group_telemetry.py` | Add tests |
| `prototype/pfn_tool_wrapper.py` | Add `output` parameter |

## Open WebUI Wrapper Usage

```python
# String format for Open WebUI
get_group_telemetry(
    tags="building:Factory B,equipment_type:Compressor",
    period="7d",
    quantity_search="voltage",
    output="timeseries"
)
```
