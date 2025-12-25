# Phase 2: Time-Series Telemetry Tools

## Overview

Phase 2 adds tools for querying actual telemetry data from the Valkyrie database. These build on Phase 1 discovery tools.

## Tools

### 1. `resolve_device` (High Priority)

**Purpose**: Confirm device selection before querying telemetry. Prevents wrong-device queries from ambiguous fuzzy matches.

**When to use**:
- User provides device name (not ID)
- Search term could match multiple devices
- LLM should call this BEFORE `get_device_telemetry` when uncertain

**Parameters**:
```python
search: str              # Device name search term
tenant_id: int | None    # Optional tenant filter
limit: int = 5           # Max candidates to return
```

**Response includes**:
- Ranked list of matching devices
- Match confidence (exact/partial/fuzzy)
- Tenant context for each match
- Device IDs for precise selection

**Example flow**:
```
User: "Show me power data for the compressor"
LLM: [calls resolve_device(search="compressor")]
Tool: "Found 3 devices matching 'compressor':
       1. Compressor 100HP (ID: 123) - Primarajuli [EXACT]
       2. Compressor 50HP (ID: 456) - Primarajuli [PARTIAL]
       3. Air Compressor (ID: 789) - Demo [PARTIAL]"
LLM: "I found 3 compressors. Which one did you mean?"
User: "The 100HP one"
LLM: [calls get_device_telemetry(device_id=123, ...)]
```

---

### 2. `get_device_telemetry` (High Priority)

**Purpose**: Core time-series query tool. Fetches aggregated telemetry data for a device.

**Parameters**:
```python
# Device selection (one required)
device_id: int | None
device_name: str | None

# Quantity selection (one required)
quantity_id: int | None
quantity_search: str | None  # Uses QUANTITY_ALIASES

# Time range (one approach required)
period: str | None           # "1h", "24h", "7d", "30d", "3M", "1Y"
start_date: str | None       # ISO format
end_date: str | None         # ISO format, defaults to now

# Aggregation control
bucket: str = "auto"         # "15min", "1hour", "4hour", "1day", "1week", "auto"
```

**Adaptive bucketing logic** (when `bucket="auto"`):

| Time Range | Bucket Size | Max Points |
|------------|-------------|------------|
| ≤ 1 hour   | 1 min       | 60         |
| ≤ 24 hours | 15 min      | 96         |
| ≤ 7 days   | 1 hour      | 168        |
| ≤ 30 days  | 4 hours     | 180        |
| ≤ 90 days  | 1 day       | 90         |
| > 90 days  | 1 week      | ~52/year   |

**Aggregation strategy**:

Return multiple stats per bucket for flexibility:
```python
{
    "bucket": "2024-01-01T00:00:00",
    "avg": 150.5,
    "min": 120.0,
    "max": 180.0,
    "sum": 451.5,    # Meaningful for cumulative quantities
    "count": 3       # Data quality indicator
}
```

The LLM picks which stat to highlight based on context:
- "Average power" → use `avg`
- "Peak demand" → use `max`
- "Total energy" → use `sum`
- "Any issues?" → show `min`/`max` range

**Quantity type handling** (from `quantities.aggregation_method`):
- **SUM quantities** (energy): Primary stat is `sum`, show delta between buckets
- **AVG quantities** (power, voltage, current): Primary stat is `avg`

**Data source**:
- Primary: `telemetry_15min_agg` (2 years retention)
- Fallback: `telemetry_data` (14 days, raw 1-min data) - only if finer resolution needed

---

### 3. `get_quantity_stats` (Medium Priority)

**Purpose**: Pre-flight validation before querying. Quick stats about data availability and value ranges.

**When to use**:
- Before expensive telemetry query
- To validate data exists for the requested period
- To understand typical value ranges (for anomaly context)

**Parameters**:
```python
device_id: int
quantity_id: int | None
quantity_search: str | None
period: str = "30d"
```

**Response includes**:
```python
{
    "device": {"id": 123, "name": "Compressor 100HP"},
    "quantity": {"id": 185, "name": "Active Power Total", "unit": "kW"},
    "period": {"start": "2024-01-01", "end": "2024-01-31"},
    "stats": {
        "data_points": 2880,
        "min": 45.2,
        "max": 187.5,
        "avg": 112.3,
        "first_reading": "2024-01-01T00:15:00",
        "last_reading": "2024-01-31T23:45:00",
        "gaps": 2  # Number of missing expected readings
    }
}
```

---

## Implementation Notes

### Date/Time Handling

- All timestamps in UTC
- Accept ISO 8601 format: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS`
- Period strings: `1h`, `24h`, `7d`, `30d`, `90d`, `1Y`
- Let Claude handle natural language → structured conversion

### Query Optimization

- Use `time_bucket()` for efficient TimescaleDB aggregation
- Index usage: `(device_id, quantity_id, bucket)`
- Limit result rows to prevent timeout (max ~500 points)
- For large ranges, force larger buckets

### Error Handling

- No data found → clear message with suggestion to check `get_device_data_range`
- Ambiguous device → suggest `resolve_device`
- Invalid date range → helpful error with valid range from `get_device_data_range`

---

## Future Tools (Phase 2+)

### `compare_periods`
Compare same device/quantity across two time periods.
```
"Compare this week's power vs last week"
```

### `get_peak_demand`
Find peak values with timestamps.
```
"When was peak power demand last month?"
```

### `detect_anomalies`
Identify unusual readings (spikes, drops, flatlines).
```
"Any anomalies in voltage this week?"
```

### `calculate_consumption`
Energy consumption with cost estimation.
```
"Total energy consumption for January"
```
