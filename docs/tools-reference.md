# PFN MCP Tools Reference

<!-- Auto-generated from tools.yaml on 2026-01-15 15:45 -->
<!-- DO NOT EDIT MANUALLY - run: python scripts/generate_tools_reference.py -->

Total tools: **24**

---

## Quick Reference

| Tool | Category | Tenant-Aware | Defer Loading | Purpose |
|------|----------|--------------|---------------|---------|
| `list_tenants` | Discovery | No | Yes | List all available tenants in the Valkyrie data... |
| `list_devices` | Discovery | Yes | No | Search for devices by name |
| `list_quantities` | Discovery | No | Yes | List available measurement quantities (metrics) |
| `list_device_quantities` | Discovery | No | Yes | List quantities available for a specific device |
| `compare_device_quantities` | Discovery | No | Yes | Compare quantities available across multiple de... |
| `get_device_data_range` | Discovery | No | Yes | Get the time range of available data for a device |
| `find_devices_by_quantity` | Discovery | Yes | Yes | Find all devices that have data for a specific ... |
| `get_device_info` | Discovery | No | Yes | Get detailed device information including metadata |
| `check_data_freshness` | Discovery | Yes | Yes | Check when data was last received for device(s) |
| `get_tenant_summary` | Discovery | Yes | Yes | Get comprehensive tenant overview |
| `resolve_device` | Telemetry | Yes | No | Confirm device selection before querying telemetry |
| `get_device_telemetry` | Telemetry | Yes | No | Fetch time-series telemetry data for a device |
| `get_quantity_stats` | Telemetry | Yes | Yes | Pre-flight validation before telemetry queries |
| `get_energy_consumption` | Telemetry | Yes | No | Get energy consumption for a device |
| `get_electricity_cost` | Electricity Cost | Yes | No | ⚠️ DEPRECATED: Use get_wages_data instead |
| `get_electricity_cost_ranking` | Electricity Cost | Yes | Yes | Rank devices by electricity cost or consumption... |
| `compare_electricity_periods` | Electricity Cost | Yes | Yes | Compare electricity costs between two time periods |
| `list_tags` | Group Telemetry | Yes | Yes | List available device tags for grouping |
| `list_tag_values` | Group Telemetry | Yes | Yes | List all values for a specific tag key with dev... |
| `search_tags` | Group Telemetry | No | Yes | Search for device tags by value or key |
| `get_group_telemetry` | Group Telemetry | Yes | Yes | ⚠️ DEPRECATED: Use get_wages_data with tag_key/... |
| `compare_groups` | Group Telemetry | Yes | Yes | Compare electricity consumption across multiple... |
| `get_peak_analysis` | Peak Analysis | Yes | Yes | ⚠️ DEPRECATED: Use get_wages_data with agg_meth... |


---

## Tool Search Configuration

When using Anthropic's Tool Search Tool, configure `defer_loading` as follows:

### Always Loaded (Non-Deferred)
These 5 tools are loaded immediately for every request:

- `list_devices`
- `resolve_device`
- `get_device_telemetry`
- `get_energy_consumption`
- `get_electricity_cost`

### Deferred (Searchable)
These 19 tools are loaded on-demand via search:

- `list_tenants`
- `list_quantities`
- `list_device_quantities`
- `compare_device_quantities`
- `get_device_data_range`
- `find_devices_by_quantity`
- `get_device_info`
- `check_data_freshness`
- `get_tenant_summary`
- `get_quantity_stats`
- `get_electricity_cost_ranking`
- `compare_electricity_periods`
- `list_tags`
- `list_tag_values`
- `search_tags`
- `get_group_telemetry`
- `compare_groups`
- `get_peak_analysis`
- `get_wages_data`

### MCP Integration Example

```python
tools = [
    {"type": "tool_search_tool_bm25_20251119", "name": "tool_search"},
    {
        "type": "mcp_toolset",
        "mcp_server_name": "pfn-mcp",
        "default_config": {"defer_loading": True},
        "configs": {
            "list_devices": {"defer_loading": False},
            "resolve_device": {"defer_loading": False},
            "get_device_telemetry": {"defer_loading": False},
            "get_energy_consumption": {"defer_loading": False},
            "get_electricity_cost": {"defer_loading": False},
        }
    }
]
```


---

## Discovery Tools

### `list_tenants`

**Tenant-aware:** No | **Defer loading:** Yes

List all available tenants in the Valkyrie database

**Parameters:**

_No parameters_


---

### `list_devices`

**Tenant-aware:** Yes | **Defer loading:** No (always loaded)

Search for devices by name. Supports fuzzy matching. Returns device info with tenant context.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `search` | string | No | Search term to filter devices by name |
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `limit` | integer | No | Maximum number of results per page (default: 20) |
| `offset` | integer | No | Number of results to skip for pagination (default: 0) |


---

### `list_quantities`

**Tenant-aware:** No | **Defer loading:** Yes

List available measurement quantities (metrics). Supports semantic search: 'voltage', 'power', 'energy', 'current', 'power factor', 'thd', 'frequency', 'water', 'air'. Categories: Electricity, Water, Air, Gas.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `category` | string | No | Filter by WAGE category. Accepts: electricity/electrical, water, air, gas |
| `search` | string | No | Semantic search term: voltage, power, energy, current, power factor, thd, fre... |


---

### `list_device_quantities`

**Tenant-aware:** No | **Defer loading:** Yes

List quantities available for a specific device. Shows what measurements exist in telemetry for the device. Supports semantic search for quantity types.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID to query |
| `device_name` | string | No | Device name (fuzzy search) |
| `search` | string | No | Filter by quantity type: voltage, power, energy, current, thd, etc. |


---

### `compare_device_quantities`

**Tenant-aware:** No | **Defer loading:** Yes

Compare quantities available across multiple devices. Shows shared quantities and per-device breakdown. Useful for finding common measurements between devices.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_ids` | array[integer] | No | List of device IDs to compare |
| `device_names` | array[string] | No | List of device names (fuzzy search) |
| `search` | string | No | Filter by quantity type: voltage, power, etc. |


---

### `get_device_data_range`

**Tenant-aware:** No | **Defer loading:** Yes

Get the time range of available data for a device. Shows earliest/latest data timestamps, days of data, and quantity breakdown. Essential for knowing what date ranges to query.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID to query |
| `device_name` | string | No | Device name (fuzzy search) |
| `quantity_id` | integer | No | Optional: check specific quantity |
| `quantity_search` | string | No | Optional: filter by quantity type (voltage, power, etc.) |


---

### `find_devices_by_quantity`

**Tenant-aware:** Yes | **Defer loading:** Yes

Find all devices that have data for a specific quantity. Useful for finding which devices track a particular metric. Groups results by tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `quantity_id` | integer | No | Quantity ID to search for |
| `quantity_search` | string | No | Quantity search term (voltage, power, energy, etc.) |
| `tenant` | string | No | Tenant name or code to filter results (e.g., 'PRS') |


---

### `get_device_info`

**Tenant-aware:** No | **Defer loading:** Yes

Get detailed device information including metadata. Shows manufacturer, model, Modbus address (slave_id + IP), location, and communication protocol. Can search by: device_id, device_name (fuzzy), or ip_address + slave_id. Use ip_address + slave_id for direct Modbus lookup (avoids brute-force search).

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID to query |
| `device_name` | string | No | Device name (fuzzy search) |
| `ip_address` | string | No | IP address for Modbus search (requires slave_id) |
| `slave_id` | integer | No | Modbus slave ID for Modbus search (requires ip_address) |
| `tenant` | string | No | Tenant name or code filter (optional, narrows search) |


---

### `check_data_freshness`

**Tenant-aware:** Yes | **Defer loading:** Yes

Check when data was last received for device(s). Identifies offline, stale, or recently active meters. Can check single device or all devices for a tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID to check |
| `device_name` | string | No | Device name (fuzzy search) |
| `tenant` | string | No | Tenant name or code to check all devices (e.g., 'PRS') |
| `hours_threshold` | integer | No | Hours to consider data 'stale' (default: 24) |


---

### `get_tenant_summary`

**Tenant-aware:** Yes | **Defer loading:** Yes

Get comprehensive tenant overview. Shows device counts, data range, quantity coverage by category, and device models. Good starting point for tenant analysis.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant_id` | integer | No | Tenant ID to query |
| `tenant_name` | string | No | Tenant name (fuzzy search) |


---

## Telemetry Tools

### `resolve_device`

**Tenant-aware:** Yes | **Defer loading:** No (always loaded)

Confirm device selection before querying telemetry. Returns ranked candidates with match confidence (exact/partial/fuzzy). Use BEFORE get_device_telemetry when user provides device name, not ID. Prevents wrong-device queries from ambiguous fuzzy matches.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `search` | string | Yes | Device name search term |
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `limit` | integer | No | Maximum candidates to return (default: 5) |


---

### `get_device_telemetry`

**Tenant-aware:** Yes | **Defer loading:** No (always loaded)

Fetch time-series telemetry data for a device. Returns aggregated data (avg, min, max, sum, count) with adaptive bucketing. Smart data source selection: uses raw 1-minute data for queries ≤4h (within 14 days), 15-min aggregated for 4-24h, and pre-aggregated data for longer periods.
**Default quantity mappings** (when user doesn't specify phase): - "current" → 100ms Current Avg (ID: 3324) - average across phases - "voltage" → 100ms Voltage L-N Avg (ID: 3332) - line-to-neutral average - "power factor" / "pf" → True Power Factor Total (ID: 1072) - "power" → Active Power (ID: 185) - "frequency" → Frequency (ID: 526) - "thd" → THD Voltage L-N (ID: 1119) For phase-specific data, use explicit names like "Current Phase A" or quantity IDs.
**For energy/consumption queries, use get_energy_consumption instead** - this tool returns meter readings, not actual consumption values.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID (preferred over device_name) |
| `device_name` | string | No | Device name (fuzzy search) |
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `quantity_id` | integer | No | Quantity ID (preferred over quantity_search) |
| `quantity_search` | string | No | Quantity search term. Default mappings: "current"→3324, "voltage"→3332, "powe... |
| `period` | string | No | Time period: 1h, 24h, 7d, 30d, 3M, 1Y |
| `start_date` | string | No | Start date (ISO format, alternative to period) |
| `end_date` | string | No | End date (ISO format, defaults to now) |
| `bucket` | string | No | Bucket size: 1min (raw data), 15min, 1hour, 4hour, 1day, 1week, auto. Auto se... |


---

### `get_quantity_stats`

**Tenant-aware:** Yes | **Defer loading:** Yes

Pre-flight validation before telemetry queries. Returns data availability stats: point count, min/max/avg values, first/last timestamps, data completeness percentage, and gaps. Use to verify data exists before calling get_device_telemetry.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | Yes | Device ID to query |
| `tenant` | string | No | Tenant name or code to validate device access (e.g., 'PRS') |
| `quantity_id` | integer | No | Quantity ID (preferred over quantity_search) |
| `quantity_search` | string | No | Quantity search: voltage, power, energy, etc. |
| `period` | string | No | Time period to check (default: 30d) |


---

### `get_energy_consumption`

**Tenant-aware:** Yes | **Defer loading:** No (always loaded)

Get energy consumption for a device. Returns actual consumption (not cumulative meter readings) calculated from interval deltas. Handles meter resets and data anomalies automatically. Smart data source: daily_energy_cost_summary for daily+, telemetry_intervals_cumulative for sub-daily. Default quantity: Active Energy. Use for energy queries instead of get_device_telemetry.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device_id` | integer | No | Device ID (preferred over device_name) |
| `device_name` | string | No | Device name (fuzzy search) |
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `quantity_id` | integer | No | Energy quantity ID (e.g., 124 for Active Energy Delivered) |
| `quantity_search` | string | No | Quantity search: energy, active energy, reactive energy, apparent energy |
| `period` | string | No | Time period: 1h, 24h, 7d, 30d, 3M, 1Y (default: 7d) |
| `start_date` | string | No | Start date (ISO format, alternative to period) |
| `end_date` | string | No | End date (ISO format, defaults to now) |
| `bucket` | string | No | Bucket size: 15min, 1hour, 4hour, 1day, 1week, auto |
| `include_quality_info` | boolean | No | Include data quality breakdown in response (default: false) |


---

## Electricity Cost Tools

### `get_electricity_cost`

**Tenant-aware:** Yes | **Defer loading:** No (always loaded)

⚠️ DEPRECATED: Use get_wages_data instead. Get electricity consumption and cost for a device or tenant. Queries pre-aggregated daily cost data with time-of-use (TOU) rates.
**Indonesian Electricity Rate Codes:** - WBP (Waktu Beban Puncak) = Peak Period (~Rp 1,550/kWh) - LWBP (Luar WBP) = Off-Peak Period (~Rp 1,035/kWh)
  - LWBP1: Morning off-peak
  - LWBP2: Night off-peak

**Work Shifts:** - SHIFT1: Night (22:00-06:00) - SHIFT2: Day (06:00-14:00) - SHIFT3: Evening (14:00-22:00)
**Group by options:** - none: Summary totals only (default) - daily: Per-day breakdown - shift: By work shift (SHIFT1/2/3) - rate: By electricity rate (WBP/LWBP) - source: By utility source (PLN/Solar) - shift_rate: Combined shift and rate matrix - daily_rate: Per-day breakdown by rate (compare rate distribution across days) - daily_shift: Per-day breakdown by shift
Period formats: '7d', '1M', '2025-12', or 'YYYY-MM-DD to YYYY-MM-DD'.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device` | string | No | Device name (fuzzy match) |
| `tenant` | string | No | Tenant name (fuzzy match) |
| `period` | string | No | Time period: '7d', '30d', '1M', '2025-12', or 'YYYY-MM-DD to YYYY-MM-DD' (def... |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |
| `group_by` | string | No | Grouping type: 'none' (summary only), 'daily', 'shift', 'rate', 'source', 'sh... |


---

### `get_electricity_cost_ranking`

**Tenant-aware:** Yes | **Defer loading:** Yes

Rank devices by electricity cost or consumption within a tenant. Shows top consumers with percentage of total. Use for identifying high-cost equipment or usage patterns.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | Yes | Tenant name (fuzzy match, required) |
| `period` | string | No | Time period: '7d', '30d', '1M' (default: 30d) |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |
| `metric` | string | No | Ranking metric: 'cost' or 'consumption' (default: cost) |
| `limit` | integer | No | Number of results (default: 10) |


---

### `compare_electricity_periods`

**Tenant-aware:** Yes | **Defer loading:** Yes

Compare electricity costs between two time periods. Shows consumption and cost for each period with change metrics. Use for month-over-month or custom period comparisons.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device` | string | No | Device name (fuzzy match) |
| `tenant` | string | No | Tenant name (fuzzy match) |
| `period1` | string | Yes | First period (e.g., '2025-11', '30d') |
| `period2` | string | Yes | Second period (e.g., '2025-12', '30d') |


---

## Group Telemetry Tools

### `list_tags`

**Tenant-aware:** Yes | **Defer loading:** Yes

List available device tags for grouping. Tags allow flexible grouping by process, building, area, etc. Shows tag keys, values, and device counts by category. Filters to tags used by devices in the user's tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | No | Tenant name or code to filter tags by devices (e.g., 'PRS') |
| `tag_key` | string | No | Filter by specific tag key (e.g., 'process', 'building') |
| `tag_category` | string | No | Filter by tag category (e.g., 'location', 'production') |


---

### `list_tag_values`

**Tenant-aware:** Yes | **Defer loading:** Yes

List all values for a specific tag key with device counts. Shows which devices belong to each tag value. Use to explore available groupings before get_group_telemetry. Filters to tags used by devices in the user's tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | No | Tenant name or code to filter tags by devices (e.g., 'PRS') |
| `tag_key` | string | Yes | Tag key to list values for (e.g., 'process', 'building') |


---

### `search_tags`

**Tenant-aware:** No | **Defer loading:** Yes

Search for device tags by value or key. Finds tags where tag_value or tag_key matches the search term. Use when you don't know which tag_key a value belongs to. Returns matching tag key/value pairs ranked by match quality. Example: search "PRS" to find tenant=PRS tag.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `search` | string | Yes | Search term to match against tag_value and tag_key |
| `limit` | integer | No | Maximum results to return (default: 10) |


---

### `get_group_telemetry`

**Tenant-aware:** Yes | **Defer loading:** Yes

⚠️ DEPRECATED: Use get_wages_data with tag_key/tag_value instead. Get aggregated telemetry for a group of devices. Default: electricity consumption/cost. With quantity: any WAGES metric (power, water flow, air pressure, etc.). Group by: single tag (tag_key + tag_value), multiple tags with AND logic (tags array), or asset hierarchy (asset_id). Supports breakdown by device or daily. Auto-filters to devices in the user's tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `tag_key` | string | No | Tag key for single-tag grouping (e.g., 'process', 'building') |
| `tag_value` | string | No | Tag value to match (e.g., 'Waterjet', 'Factory A') |
| `tags` | array[object] | No | Multi-tag AND query. List of {key, value} objects. Example: [{"key": "buildin... |
| `asset_id` | integer | No | Asset ID for hierarchy-based grouping |
| `quantity_id` | integer | No | Quantity ID for WAGE metrics (omit for electricity cost) |
| `quantity_search` | string | No | Quantity search: power, voltage, water flow, air pressure, etc. (omit for ele... |
| `period` | string | No | Time period: '7d', '1M', '2025-12' (default: 7d) |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |
| `breakdown` | string | No | Breakdown type: 'none', 'device', 'daily' (default: none). Only used with out... |
| `output` | string | No | Output format: 'summary' (aggregated totals/averages), 'timeseries' (time-ali... |


---

### `compare_groups`

**Tenant-aware:** Yes | **Defer loading:** Yes

Compare electricity consumption across multiple groups. Each group can be defined by tag or asset. Returns consumption, cost, and percentage for each group. Auto-filters to devices in the user's tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `groups` | array[object] | Yes | List of groups to compare. Each group needs either (tag_key + tag_value) or a... |
| `period` | string | No | Time period: '7d', '1M', '2025-12' (default: 7d) |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |


---

## Peak Analysis Tools

### `get_peak_analysis`

**Tenant-aware:** Yes | **Defer loading:** Yes

⚠️ DEPRECATED: Use get_wages_data with agg_method="max" instead. Find peak values with timestamps for a device or group. Returns top N peaks per bucket (hour/day/week). Shows which device caused each peak. Supports any WAGES quantity: power, flow, pressure, etc. Auto-filters to devices in the user's tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | No | Tenant name or code to filter devices (e.g., 'PRS') |
| `device_id` | integer | No | Single device ID |
| `device_name` | string | No | Single device name (fuzzy search) |
| `tag_key` | string | No | Tag key for group (e.g., 'process', 'building') |
| `tag_value` | string | No | Tag value for group (e.g., 'Waterjet') |
| `asset_id` | integer | No | Asset ID for hierarchy-based grouping |
| `quantity_id` | integer | No | Quantity ID (e.g., 185 for Active Power) |
| `quantity_search` | string | No | Quantity search: power, flow, pressure, voltage, etc. |
| `period` | string | No | Time period: '7d', '30d', '1M' (default: 7d) |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |
| `bucket` | string | No | Bucket size: '1hour', '1day', '1week' (auto if omitted) |
| `top_n` | integer | No | Number of top peaks to return (default: 10) |
| `breakdown` | string | No | Breakdown: 'none' or 'device_daily' (default: none) |


---
