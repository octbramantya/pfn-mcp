# Telemetry Improvements Plan

**Created:** 2026-01-07
**Status:** Completed
**Reference:** `docs/playground/time_format.md` (user feedback)

## Overview

Two improvements to telemetry tools based on user testing feedback:

1. **Timezone Display (UTC+7)** - Show timestamps in Asia/Jakarta timezone
2. **Smart Data Source Selection** - Use raw `telemetry_data` for short queries

---

## Feature 1: Timezone Display

### Problem
User requested "last 5 minutes" data but timestamps displayed in UTC, not local time (WIB/UTC+7).

### Current State
- All timestamps returned as naive UTC ISO strings (e.g., `2025-12-15T14:30:00`)
- Infrastructure exists but unused:
  - `datetime_utils.format_display_datetime()`
  - `config.display_timezone = "Asia/Jakarta"`

### Implementation

**Files to modify:**
- `src/pfn_mcp/tools/telemetry.py` - `format_telemetry_response()`
- `src/pfn_mcp/tools/discovery.py` - `format_device_data_range_response()`, `format_data_freshness_response()`
- `src/pfn_mcp/tools/peak_analysis.py` - `format_peak_analysis_response()`
- `src/pfn_mcp/tools/group_telemetry.py` - formatters
- `src/pfn_mcp/tools/electricity_cost.py` - formatters

**Changes:**
1. Import `format_display_datetime` from `datetime_utils`
2. Pass datetime objects (not just ISO strings) to formatters
3. Use `format_display_datetime(dt)` for all user-facing timestamps

### Effort: Low (infrastructure exists)

---

## Feature 2: Smart Data Source Selection

### Problem
User requested "last 5 minutes" but tool returned weekly aggregated data because it always uses `telemetry_15min_agg` (minimum 15-min resolution).

### Current State
- Always uses `telemetry_15min_agg` (15-min aggregated data)
- Adaptive bucketing implemented (15min → 1week) but source is fixed

### Target Behavior (from `docs/concept.md`)

| Query Duration | Data Source | Aggregation |
|----------------|-------------|-------------|
| <= 4 hours | `telemetry_data` | Raw 5-second |
| 4-24 hours | `telemetry_data` | 15-min buckets |
| > 24 hours | `telemetry_15min_agg` | Hourly → Weekly |

### Table Differences

| Aspect | telemetry_data | telemetry_15min_agg |
|--------|----------------|---------------------|
| Time column | `timestamp` | `bucket` |
| Value column | `value` | `aggregated_value` |
| Granularity | 5-second | 15-minute |
| Retention | 14 days | 2 years |

### Implementation

**File:** `src/pfn_mcp/tools/telemetry.py`

1. Add `select_data_source()` function
2. Add `_query_raw_telemetry()` for 5-second data
3. Add `_query_raw_aggregated_telemetry()` for raw data with 15-min buckets
4. Modify `get_device_telemetry()` to use data source selector
5. Update `tools.yaml` to add `5sec` bucket option

### Edge Cases
- Query older than 14 days → falls back to `telemetry_15min_agg`
- User specifies bucket manually → respect user choice when valid

### Effort: Medium

---

## Implementation Order

1. **Feature 1 (Timezone)** - Quick win, lower risk
2. **Feature 2 (Smart Source)** - Higher complexity, requires testing

---

## Beads Issues

- `pfn_mcp-drk`: Timezone display (UTC+7) in telemetry formatters
- `pfn_mcp-fof`: Smart data source selection for telemetry queries

---

## Files Summary

| File | Feature 1 | Feature 2 |
|------|-----------|-----------|
| `tools/telemetry.py` | Update formatter | Add selector + query builders |
| `tools/discovery.py` | Update formatters | - |
| `tools/peak_analysis.py` | Update formatter | - |
| `tools/group_telemetry.py` | Update formatters | - |
| `tools/electricity_cost.py` | Update formatters | - |
| `tools.yaml` | - | Add `5sec` bucket |
