# Electricity Cost Tools - Phase 2 Specification

**Created:** 2025-12-27
**Status:** Design
**Related:** [concept.md](./concept.md), [phase2-telemetry.md](./phase2-telemetry.md)

---

## Overview

This document specifies the MCP tools for querying electricity consumption and cost data. These tools query the pre-aggregated `daily_energy_cost_summary` table, which provides daily breakdowns by shift period and time-of-use rate.

> **Note:** This specification covers **electricity** only. Water, Air, and Gas (WAG) will have separate tool specifications as their tariff structures differ significantly.

---

## Data Source

### Table: `daily_energy_cost_summary`

Pre-aggregated daily data populated by `refresh_daily_energy_costs()` via pgAgent (runs daily).

| Column | Type | Description |
|--------|------|-------------|
| `daily_bucket` | timestamp | Date in Jakarta time (UTC+7) |
| `tenant_id` | integer | Tenant reference |
| `device_id` | integer | Device/meter reference |
| `quantity_id` | integer | Energy type (124 = Active Energy Delivered) |
| `shift_period` | varchar | Operational shift (SHIFT1, SHIFT2, SHIFT3) |
| `rate_code` | varchar | PLN rate code (WBP, LWBP1, LWBP2, PV) |
| `rate_per_unit` | numeric | Rate in Rp/kWh at calculation time |
| `utility_source_id` | integer | Utility source (PLN Grid, Solar PV) |
| `total_consumption` | numeric | Energy consumed (kWh) |
| `total_cost` | numeric | Calculated cost (Rp) |
| `interval_count` | numeric | Number of 15-min intervals |
| `avg_interval_consumption` | numeric | Average per interval |
| `max_interval_consumption` | numeric | Peak interval value |
| `min_interval_consumption` | numeric | Minimum interval value |

**Data retention:** Continuous from 2025-08-21
**Refresh frequency:** Daily at 00:30 WIB

### Tracked Energy Quantities

| ID | Name | Primary Use |
|----|------|-------------|
| **124** | Active Energy Delivered | **Primary** - billable consumption |
| 89 | Reactive Energy Delivered | Power factor penalty calculation |
| 481 | Apparent Energy Delivered | Total apparent power |
| 130 | Active Energy Delivered-Received | Net metering (solar export offset) |
| 131 | Active Energy Received | Energy exported to grid |

---

## Rate Structure

### PLN Time-of-Use Rates

Indonesia's PLN (state electricity company) uses time-of-use pricing:

| Rate Code | Name | Hours (WIB) | Typical Rate |
|-----------|------|-------------|--------------|
| **WBP** | Waktu Beban Puncak (Peak) | 18:00-22:00 | Rp 1,553.67/kWh |
| **LWBP1** | Luar WBP 1 (Off-Peak 1) | 22:00-00:00 | Rp 1,035.78/kWh |
| **LWBP2** | Luar WBP 2 (Off-Peak 2) | 00:00-18:00 | Rp 1,035.78/kWh |
| **PV** | Solar PV | All hours | Rp 968.45/kWh |

> Rates are tenant-specific and stored in `utility_rates` table. Values above are examples from Primarajuli Sukses.

### Shift Periods

Shifts are defined per-tenant in `tenant_shift_periods`:

**Primarajuli Sukses (3 shifts):**
| Shift | Hours |
|-------|-------|
| SHIFT1 | 07:00-15:00 |
| SHIFT2 | 15:00-23:00 |
| SHIFT3 | 23:00-07:00 |

**Indo Oil Perkasa (2 shifts):**
| Shift | Hours |
|-------|-------|
| SHIFT1 | 07:00-19:00 |
| SHIFT2 | 19:00-07:00 |

### Data Granularity

Each device-day is stored as **multiple rows** for each shift × rate combination:

```
Device: AJL 1 | Date: 2025-12-26

  SHIFT1 + LWBP2:  943.22 kWh × Rp 1,035.78 = Rp   976,968
  SHIFT2 + LWBP1:  110.66 kWh × Rp 1,035.78 = Rp   114,619
  SHIFT2 + LWBP2:  347.00 kWh × Rp 1,035.78 = Rp   359,415
  SHIFT2 + WBP:    451.19 kWh × Rp 1,553.67 = Rp   701,000
  SHIFT3 + LWBP1:  115.57 kWh × Rp 1,035.78 = Rp   119,705
  SHIFT3 + LWBP2:  781.84 kWh × Rp 1,035.78 = Rp   809,814
  ─────────────────────────────────────────────────────────
  TOTAL:         2,749.48 kWh              = Rp 3,081,523
```

---

## Proposed Tools

### 1. `get_electricity_cost`

Primary tool for electricity cost queries. Returns consumption and cost for a device or tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device` | string | No* | Device name (fuzzy match) |
| `tenant` | string | No* | Tenant name (fuzzy match) |
| `period` | string | No | Time period (default: "7d"). Formats: "7d", "1M", "2025-12" |
| `start_date` | string | No | Explicit start date (YYYY-MM-DD) |
| `end_date` | string | No | Explicit end date (YYYY-MM-DD) |
| `breakdown` | string | No | Breakdown type: "none", "daily", "shift", "rate", "source" |

*At least one of `device` or `tenant` is required.

**Response:**

```json
{
  "summary": {
    "total_consumption_kwh": 2749.48,
    "total_cost_rp": 3081523.18,
    "avg_rate_per_kwh": 1120.76,
    "period": "2025-12-26 to 2025-12-26",
    "device": "AJL 1",
    "tenant": "Primarajuli Sukses"
  },
  "breakdown": [
    {
      "date": "2025-12-26",
      "consumption_kwh": 2749.48,
      "cost_rp": 3081523.18
    }
  ]
}
```

**Example queries:**
- "What was AJL 1's electricity cost last week?"
- "Show me Primarajuli Sukses total electricity cost for December"
- "How much did the Chiller 1 consume this month?"

---

### 2. `get_electricity_cost_breakdown`

Detailed breakdown analysis by shift, rate, or utility source.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device` | string | Yes | Device name (fuzzy match) |
| `period` | string | No | Time period (default: "7d") |
| `group_by` | string | No | Grouping: "shift", "rate", "source", "shift_rate" (default) |

**Response (group_by="shift"):**

```json
{
  "device": "AJL 1",
  "period": "2025-12-01 to 2025-12-27",
  "breakdown": [
    {
      "shift": "SHIFT1",
      "consumption_kwh": 25123.45,
      "cost_rp": 26028345.67,
      "percentage": 33.2
    },
    {
      "shift": "SHIFT2",
      "consumption_kwh": 26789.12,
      "cost_rp": 31245678.90,
      "percentage": 35.4
    },
    {
      "shift": "SHIFT3",
      "consumption_kwh": 23456.78,
      "cost_rp": 24301234.56,
      "percentage": 31.4
    }
  ]
}
```

**Example queries:**
- "Break down AJL 1's electricity cost by shift"
- "Show peak vs off-peak electricity usage for Chiller 1"
- "How much electricity comes from solar vs PLN for the factory?"

---

### 3. `get_electricity_cost_ranking`

Rank devices by consumption or cost within a tenant.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tenant` | string | Yes | Tenant name |
| `period` | string | No | Time period (default: "30d") |
| `metric` | string | No | Ranking metric: "cost" (default), "consumption" |
| `limit` | integer | No | Number of results (default: 10) |

**Response:**

```json
{
  "tenant": "Primarajuli Sukses",
  "period": "2025-12-01 to 2025-12-27",
  "metric": "cost",
  "ranking": [
    {
      "rank": 1,
      "device": "Incoming PLN 1",
      "consumption_kwh": 2262800.00,
      "cost_rp": 2544128410.32,
      "percentage_of_total": 29.4
    },
    {
      "rank": 2,
      "device": "Incoming Factory A&B",
      "consumption_kwh": 1105220.00,
      "cost_rp": 1248746725.80,
      "percentage_of_total": 14.4
    }
  ]
}
```

**Example queries:**
- "What are the top 10 electricity consumers this month?"
- "Which devices have the highest electricity cost?"
- "Rank devices by peak hour consumption"

---

### 4. `compare_electricity_periods`

Compare electricity costs between two time periods.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `device` | string | No* | Device name |
| `tenant` | string | No* | Tenant name |
| `period1` | string | Yes | First period (e.g., "2025-11") |
| `period2` | string | Yes | Second period (e.g., "2025-12") |

*At least one of `device` or `tenant` is required.

**Response:**

```json
{
  "device": "AJL 1",
  "comparison": {
    "period1": {
      "label": "November 2025",
      "consumption_kwh": 78234.56,
      "cost_rp": 87654321.00
    },
    "period2": {
      "label": "December 2025",
      "consumption_kwh": 82345.67,
      "cost_rp": 92345678.00
    },
    "change": {
      "consumption_kwh": 4111.11,
      "consumption_percent": 5.3,
      "cost_rp": 4691357.00,
      "cost_percent": 5.4
    }
  }
}
```

**Example queries:**
- "Compare this month's electricity cost to last month"
- "How does December consumption compare to November?"

---

## Implementation Notes

### Device Resolution

Use existing `resolve_device` tool pattern for fuzzy matching. Cost tools should:
1. Accept device name as string
2. Resolve to `device_id` using fuzzy match
3. Return disambiguation options if multiple matches

### Period Parsing

Support multiple period formats:
- Relative: "7d", "30d", "3M", "1Y"
- Month: "2025-12", "December 2025"
- Range: "2025-12-01 to 2025-12-15"
- Named: "last week", "this month", "yesterday"

### Cost Calculation

Cost is pre-calculated in the summary table:
```
total_cost = total_consumption × rate_per_unit
```

For aggregations, sum the `total_cost` column directly (do not recalculate from average rates).

### NULL Handling

Some devices lack utility source mappings, resulting in:
- `rate_code = NULL`
- `utility_source_id = NULL`
- `total_cost = NULL`

These should be flagged in responses as "cost not available - utility mapping required".

---

## Data Quality Issues

### Devices Without Utility Mapping

The following devices have consumption data but **no cost calculation** due to missing utility source configuration. Site team should add entries to `device_utility_mappings` table.

**Primarajuli Sukses:**

| Device | Code | Affected Period | Rows |
|--------|------|-----------------|------|
| Air Dryer | DRY | 2025-12-01 to present | 80 |
| Comp. CUCUK | COMP-10 | 2025-12-01 to present | 74 |
| Compressor SCR 2200 | COMP-08 | 2025-09-28 to present | 271 |
| Compressor SCR AIKI | COMP-09 | 2025-10-06 to 2025-12-17 | 138 |
| Heater Total | HMC-00 | 2025-09-28 to present | 271 |
| LVMDB TF 630kvA | LV630 | 2025-11-10 to present | 142 |
| LVMDB Texture | LVTX | 2025-11-12 to present | 137 |
| MC 3 | MC3 | 2025-09-28 to present | 87 |
| MC ATY | MCATY | 2025-09-28 to present | 271 |
| MC302 (9-22) | MC302-2 | 2025-09-28 to 2025-12-15 | 147 |
| MC303 (1-9) | MC303 | 2025-09-28 to present | 220 |
| PLTS B | PVB | 2025-10-12 to 2025-11-24 | 5 |
| SIPPA | SIPPA | 2025-12-12 to present | 47 |
| WJL 4 | WJL4 | 2025-10-05 to present | 251 |
| WWTP | WWTP | 2025-12-12 to present | 47 |
| Workshop | WRS | 2025-12-01 to present | 80 |

**Action Required:** Add entries to `device_utility_mappings` linking these devices to appropriate `utility_source_id` (typically PLN_MAIN = 1 for grid-connected devices).

```sql
-- Example fix for missing mappings
INSERT INTO device_utility_mappings (device_id, utility_source_id, mapping_type, is_active, effective_from)
SELECT d.id, 1, 'PRIMARY', true, '2025-01-01'
FROM devices d
WHERE d.device_code IN ('DRY', 'COMP-10', 'COMP-08', 'COMP-09', 'HMC-00',
                         'LV630', 'LVTX', 'MC3', 'MCATY', 'MC302-2',
                         'MC303', 'SIPPA', 'WJL4', 'WWTP', 'WRS')
AND d.tenant_id = 3  -- Primarajuli Sukses
AND NOT EXISTS (
    SELECT 1 FROM device_utility_mappings dum
    WHERE dum.device_id = d.id AND dum.is_active = true
);
```

> **Note:** PLTS B (PVB) should map to Solar PV source, not PLN Grid.

---

## Related Tables

| Table | Purpose |
|-------|---------|
| `utility_sources` | Utility providers (PLN, Solar PV) per tenant |
| `utility_rates` | Time-of-use rate definitions |
| `tenant_shift_periods` | Shift hour definitions per tenant |
| `device_utility_mappings` | Links devices to utility sources |
| `telemetry_intervals_cumulative` | Source data for refresh function |

---

## Future Considerations

### Water, Air, Gas (WAG) Extensions

Each utility type will need separate tools due to different:
- **Rate structures:** Water may have tiered pricing, gas may have seasonal rates
- **Units:** m³ for water/gas, Nm³ for compressed air
- **Billing cycles:** May differ from electricity

Proposed naming convention:
- `get_electricity_cost` (this spec)
- `get_water_cost` (future)
- `get_gas_cost` (future)
- `get_compressed_air_cost` (future)

### Reactive Power Penalties

PLN charges penalties for poor power factor (< 0.85). Future enhancement could include:
- Power factor analysis per device
- Reactive energy cost estimation
- Recommendations for capacitor banks
