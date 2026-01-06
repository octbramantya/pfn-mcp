# PFN MCP Server - Phase 1 & 2 Testing

**Test Date:** 2026-01-06
**Tester:** Automated pytest suite
**MCP Connection:** Local stdio with remote database

## Latest Test Results

**Run:** `pytest tests/ -v`
**Total:** 77 tests (57 scenarios + 20 datetime unit tests)
**Passed:** 55 (71%)
**Failed:** 21 (27%)
**Skipped:** 1

### Bug Fixes Applied
- ✅ **pfn_mcp-2uh**: Fixed datetime timezone bug (asyncpg encoding issue)
- ✅ **pfn_mcp-e9v**: Fixed resolve_device response structure
- ✅ **pfn_mcp-ij7**: Fixed list_tags test assertion
- ✅ **pfn_mcp-9d6**: Fixed check_data_freshness test

### Remaining Failures (not datetime related)
- Schema mismatch: `min_value`/`max_value` columns don't exist in `telemetry_15min_agg`
- Missing test data for certain tags (process, building)
- Peak analysis tools reference non-existent columns

---

## Phase 1: Discovery & Data Mapping

### 1.1 Tenant & Device Discovery

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 1 | "List all tenants in the system" | `list_tenants` | ☐ Pass ☐ Fail | |
| 2 | "How many devices does each tenant have?" | `list_tenants` | ☐ Pass ☐ Fail | |
| 3 | "Search for devices with 'pump' in the name" | `list_devices` | ☐ Pass ☐ Fail | |
| 4 | "Find all devices containing 'MC-1'" | `list_devices` | ☐ Pass ☐ Fail | Should NOT match MC-10, MC-11, etc. |
| 5 | "Show me details about device MC-1 including its IP address and slave ID" | `get_device_info` | ☐ Pass ☐ Fail | |

**Comments:**
```




```

---

### 1.2 Quantity & Metric Discovery

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 6 | "What types of measurements are available?" | `list_quantities` | ☐ Pass ☐ Fail | |
| 7 | "List all voltage-related quantities" | `list_quantities` | ☐ Pass ☐ Fail | Semantic search test |
| 8 | "What power metrics can I query?" | `list_quantities` | ☐ Pass ☐ Fail | Semantic search test |
| 9 | "Show me water and gas measurement types" | `list_quantities` | ☐ Pass ☐ Fail | WAGE category test |

**Comments:**
```




```

---

### 1.3 Device-Quantity Mapping

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 10 | "What quantities are available for device MC-1?" | `list_device_quantities` | ☐ Pass ☐ Fail | |
| 11 | "Which devices have power factor data?" | `find_devices_by_quantity` | ☐ Pass ☐ Fail | |
| 12 | "Compare what quantities MC-1 and MC-2 have in common" | `compare_device_quantities` | ☐ Pass ☐ Fail | |

**Comments:**
```




```

---

### 1.4 Data Availability & Freshness

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 13 | "What's the data range for MC-1?" | `get_device_data_range` | ☐ Pass ☐ Fail | |
| 14 | "Which meters are currently offline?" | `check_data_freshness` | ☐ Pass ☐ Fail | |
| 15 | "Check data freshness for all devices in tenant PRS" | `check_data_freshness` | ☐ Pass ☐ Fail | Tenant filter test |
| 16 | "Give me a summary of tenant IOP" | `get_tenant_summary` | ☐ Pass ☐ Fail | |

**Comments:**
```




```

---

## Phase 2: Telemetry Queries

### 2.1 Device Resolution (Pre-flight)

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 17 | "Resolve device 'pump'" | `resolve_device` | ☐ Pass ☐ Fail | Should show disambiguation options |
| 18 | "Confirm which device is MC-1" | `resolve_device` | ☐ Pass ☐ Fail | Should show exact match |

**Comments:**
```




```

---

### 2.2 Time-Series Telemetry

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 19 | "Show power consumption for MC-1 over the last 24 hours" | `get_device_telemetry` | ☐ Pass ☐ Fail | Should use raw data |
| 20 | "What was the energy usage for MC-2 last week?" | `get_device_telemetry` | ☐ Pass ☐ Fail | Should use 15min agg |
| 21 | "Get voltage data for MC-1 from December 1-15, 2025" | `get_device_telemetry` | ☐ Pass ☐ Fail | Custom date range |
| 22 | "Show me the current readings for MC-1 yesterday" | `get_device_telemetry` | ☐ Pass ☐ Fail | Current quantity |

**Comments:**
```




```

---

### 2.3 Quantity Statistics

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 23 | "What's the data completeness for MC-1's power data last month?" | `get_quantity_stats` | ☐ Pass ☐ Fail | |
| 24 | "Show statistics for active power on MC-1" | `get_quantity_stats` | ☐ Pass ☐ Fail | |

**Comments:**
```




```

---

## Phase 2: Electricity Cost Analysis

### 2.4 Basic Cost Queries

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 25 | "What was the electricity cost for MC-1 last month?" | `get_electricity_cost` | ☐ Pass ☐ Fail | |
| 26 | "Show total energy consumption for tenant PRS in December 2025" | `get_electricity_cost` | ☐ Pass ☐ Fail | Tenant-level query |
| 27 | "Get electricity costs for the last 7 days" | `get_electricity_cost` | ☐ Pass ☐ Fail | Relative time |

**Comments:**
```




```

---

### 2.5 Cost Breakdowns

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 28 | "Break down MC-1's electricity cost by shift" | `get_electricity_cost_breakdown` | ☐ Pass ☐ Fail | SHIFT1/2/3 |
| 29 | "Show me the cost breakdown by rate (WBP/LWBP) for MC-2" | `get_electricity_cost_breakdown` | ☐ Pass ☐ Fail | WBP/LWBP rates |
| 30 | "What's the PLN vs Solar breakdown for tenant IOP?" | `get_electricity_cost_breakdown` | ☐ Pass ☐ Fail | Source breakdown |

**Comments:**
```




```

---

### 2.6 Cost Ranking & Comparison

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 31 | "Rank all devices by electricity cost for December 2025" | `get_electricity_cost_ranking` | ☐ Pass ☐ Fail | |
| 32 | "Which device consumed the most energy last month?" | `get_electricity_cost_ranking` | ☐ Pass ☐ Fail | Top 1 |
| 33 | "Compare November vs December electricity costs for tenant PRS" | `compare_electricity_periods` | ☐ Pass ☐ Fail | MoM comparison |
| 34 | "How does this week's cost compare to last week for MC-1?" | `compare_electricity_periods` | ☐ Pass ☐ Fail | WoW comparison |

**Comments:**
```




```

---

## Phase 2: Group Telemetry

### 2.7 Tag Discovery

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 35 | "What tags are available for grouping devices?" | `list_tags` | ☐ Pass ☐ Fail | |
| 36 | "List all values for the 'process' tag" | `list_tag_values` | ☐ Pass ☐ Fail | |
| 37 | "Show me all buildings in the system" | `list_tag_values` | ☐ Pass ☐ Fail | building tag |

**Comments:**
```




```

---

### 2.8 Group Consumption

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 38 | "What's the total energy consumption for the Waterjet process?" | `get_group_telemetry` | ☐ Pass ☐ Fail | Tag-based group |
| 39 | "Show power usage for all devices in Building A last week" | `get_group_telemetry` | ☐ Pass ☐ Fail | Building group |
| 40 | "Get aggregated consumption for asset group 'Main Distribution'" | `get_group_telemetry` | ☐ Pass ☐ Fail | Asset-based group |

**Comments:**
```




```

---

### 2.9 Group Comparison

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 41 | "Compare energy consumption between Waterjet and Laser processes" | `compare_groups` | ☐ Pass ☐ Fail | |
| 42 | "Which process group uses the most electricity?" | `compare_groups` | ☐ Pass ☐ Fail | Ranking behavior |

**Comments:**
```




```

---

## Phase 2: Peak Analysis

### 2.10 Device Peak Analysis

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 43 | "When was the peak power demand for MC-1 last month?" | `get_peak_analysis` | ☐ Pass ☐ Fail | |
| 44 | "Show me the top 5 peak power readings for MC-2 this week" | `get_peak_analysis` | ☐ Pass ☐ Fail | top_n parameter |
| 45 | "Find the peak voltage for MC-1 in December" | `get_peak_analysis` | ☐ Pass ☐ Fail | Non-power quantity |

**Comments:**
```




```

---

### 2.11 Group Peak Analysis

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 46 | "What was the peak demand for the Waterjet process group?" | `get_peak_analysis` | ☐ Pass ☐ Fail | Group peak |
| 47 | "Show peak analysis for Building A with daily breakdown" | `get_peak_analysis` | ☐ Pass ☐ Fail | Per-device breakdown |
| 48 | "Which device caused the highest peak in the Laser group?" | `get_peak_analysis` | ☐ Pass ☐ Fail | Device attribution |

**Comments:**
```




```

---

## Combined Scenarios (Real-World Use Cases)

### 2.12 Energy Manager Questions

| # | Prompt | Expected Tools | Result | Notes |
|---|--------|----------------|--------|-------|
| 49 | "I need to understand MC-1's energy profile. Show me: device details, last month's consumption, peak demand times, cost breakdown by shift" | Multiple tools | ☐ Pass ☐ Fail | Multi-tool orchestration |
| 50 | "Compare the energy efficiency between Process A and Process B for the last quarter" | `compare_groups` | ☐ Pass ☐ Fail | Long time range |

**Comments:**
```




```

---

### 2.13 Troubleshooting Scenarios

| # | Prompt | Expected Tool | Result | Notes |
|---|--------|---------------|--------|-------|
| 51 | "Which meters haven't reported data in the last hour?" | `check_data_freshness` | ☐ Pass ☐ Fail | Stale detection |
| 52 | "Show me all devices with power factor below 0.85 yesterday" | `get_device_telemetry` | ☐ Pass ☐ Fail | Threshold filtering |

**Comments:**
```




```

---

### 2.14 Management Reporting

| # | Prompt | Expected Tools | Result | Notes |
|---|--------|----------------|--------|-------|
| 53 | "Prepare a tenant summary for PRS including: total devices, December energy consumption, top 5 highest-cost devices, month-over-month cost comparison" | Multiple tools | ☐ Pass ☐ Fail | Comprehensive report |

**Comments:**
```




```

---

## Edge Cases

| # | Prompt | Expected Behavior | Result | Notes |
|---|--------|-------------------|--------|-------|
| 54 | "Search for device 'nonexistent'" | Empty results, helpful message | ☐ Pass ☐ Fail | |
| 55 | "Get telemetry for MC-1 from 2020" | Error or no data message | ☐ Pass ☐ Fail | Outside retention |
| 56 | "Show cost breakdown for a device with no cost data" | Graceful handling | ☐ Pass ☐ Fail | |
| 57 | "Compare devices that have no shared quantities" | Empty comparison result | ☐ Pass ☐ Fail | |

**Comments:**
```




```

---

## Summary

| Category | Total | Pass | Fail | Blocked |
|----------|-------|------|------|---------|
| Phase 1: Discovery | 16 | | | |
| Phase 2: Telemetry | 8 | | | |
| Phase 2: Electricity Cost | 10 | | | |
| Phase 2: Group Telemetry | 8 | | | |
| Phase 2: Peak Analysis | 6 | | | |
| Combined Scenarios | 5 | | | |
| Edge Cases | 4 | | | |
| **Total** | **57** | | | |

---

## Issues Found

| Issue # | Test # | Description | Severity | Status |
|---------|--------|-------------|----------|--------|
| | | | | |
| | | | | |
| | | | | |

---

## General Observations

```




```
