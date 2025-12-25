# Quantities Mapping Specification

**Created:** 2025-12-25
**Updated:** 2025-12-25
**Status:** Populated from Production Database
**Purpose:** Semantic layer mapping between database quantities and human-readable metrics

---

## Overview

This document defines the mapping between the `quantities` table in the Valkyrie database and the natural language terms users can use when querying data through the MCP server.

**Total quantities in use:** 77 (from `telemetry_15min_agg`)

### Database Schema Reference

```sql
CREATE TABLE public.quantities (
    id integer NOT NULL,
    quantity_code character varying(50) NOT NULL,
    quantity_name character varying(255) NOT NULL,
    unit character varying(50),
    category character varying(100),
    data_type character varying(50) DEFAULT 'NUMERIC',
    aggregation_method character varying(50) DEFAULT 'SUM',
    description text,
    is_active boolean DEFAULT true,
    is_cumulative boolean DEFAULT false
);
```

---

## WAGE Categories Summary

| Category | Code | Count | Description |
|----------|------|-------|-------------|
| **W**ater | Water | 4 | Water flow, volume, temperature |
| **A**ir | Air | 1 | Air velocity |
| **G**as | - | 0 | No gas quantities currently in use |
| **E**lectricity | Electricity | 72 | Power, energy, voltage, current, power factor, THD |

---

## Semantic Alias Groups

The `list_quantities` tool supports semantic aliases that map natural language terms to quantity patterns.

### Implementation Reference

```python
# From src/pfn_mcp/tools/quantities.py
QUANTITY_ALIASES = {
    "energy": ["ACTIVE_ENERGY", "APPARENT_ENERGY", "REACTIVE_ENERGY"],
    "power": ["ACTIVE_POWER", "APPARENT_POWER", "REACTIVE_POWER"],
    "voltage": ["VOLTAGE"],
    "current": ["CURRENT"],
    "power factor": ["POWER_FACTOR", "TRUE_POWER_FAC", "DISPLACEMENT_POWER_F"],
    "frequency": ["FREQUENCY"],
    "thd": ["THD"],
    "unbalance": ["UNBALANCE"],
    "water": ["WATER"],
    "air": ["AIR"],
    "temperature": ["TEMPERATURE"],
    "flow": ["FLOW"],
    "volume": ["VOLUME"],
}
```

---

## Electricity Quantities (72)

### Energy Consumption

**Natural language terms:** "energy", "consumption", "kWh"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 124 | `PME_129_ACTIVE_ENERGY_DELIVE` | Active Energy Delivered | SUM | cumulative |
| 130 | `PME_135_ACTIVE_ENERGY_DELIVE` | Active Energy Delivered-Received | SUM | cumulative |
| 190 | `PME_198_ACTIVE_ENERGY_DELIVE` | Active Energy Delivered+Received | SUM | instantaneous |
| 131 | `PME_139_ACTIVE_ENERGY_RECEIV` | Active Energy Received | SUM | instantaneous |
| 62 | `PME_63_APPARENT_ENERGY_DELI` | Apparent Energy Delivered + Received | SUM | cumulative |
| 481 | `PME_489_APPARENT_ENERGY_DELI` | Apparent Energy Delivered | SUM | instantaneous |
| 471 | `PME_479_APPARENT_ENERGY_RECE` | Apparent Energy Received | SUM | instantaneous |
| 89 | `PME_91_REACTIVE_ENERGY_DELI` | Reactive Energy Delivered | SUM | cumulative |
| 183 | `PME_191_REACTIVE_ENERGY_DELI` | Reactive Energy Delivered + Received | SUM | instantaneous |
| 95 | `PME_97_REACTIVE_ENERGY_DELI` | Reactive Energy Delivered-Received | SUM | instantaneous |
| 96 | `PME_101_REACTIVE_ENERGY_RECE` | Reactive Energy Received | SUM | cumulative |

**Primary metric:** ID 124 (Active Energy Delivered) - use for total consumption queries.

---

### Power Demand

**Natural language terms:** "power", "demand", "load", "kW"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 185 | `PME_193_ACTIVE_POWER` | Active Power | LATEST | instantaneous |
| 504 | `PME_518_ACTIVE_POWER_PHASE_A` | Active Power Phase A | LATEST | instantaneous |
| 505 | `PME_519_ACTIVE_POWER_PHASE_B` | Active Power Phase B | LATEST | instantaneous |
| 506 | `PME_520_ACTIVE_POWER_PHASE_C` | Active Power Phase C | LATEST | instantaneous |
| 530 | `PME_544_APPARENT_POWER` | Apparent Power | LATEST | instantaneous |
| 510 | `PME_524_APPARENT_POWER_PHASE` | Apparent Power Phase A | LATEST | instantaneous |
| 511 | `PME_525_APPARENT_POWER_PHASE` | Apparent Power Phase B | LATEST | instantaneous |
| 512 | `PME_526_APPARENT_POWER_PHASE` | Apparent Power Phase C | LATEST | instantaneous |
| 179 | `PME_187_REACTIVE_POWER` | Reactive Power | LATEST | instantaneous |
| 507 | `PME_521_REACTIVE_POWER_PHASE` | Reactive Power Phase A | LATEST | instantaneous |
| 508 | `PME_522_REACTIVE_POWER_PHASE` | Reactive Power Phase B | LATEST | instantaneous |
| 509 | `PME_523_REACTIVE_POWER_PHASE` | Reactive Power Phase C | LATEST | instantaneous |

**Primary metric:** ID 185 (Active Power) - use for demand/load queries.

---

### Power Factor

**Natural language terms:** "power factor", "PF", "displacement"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 1072 | `PME_1104_100MS_TRUE_POWER_FAC` | 100ms True Power Factor Total | LATEST | instantaneous |
| 3325 | `PME_3475_100MS_POWER_FACTOR_A` | 100ms Power Factor A | LATEST | instantaneous |
| 3326 | `PME_3476_100MS_POWER_FACTOR_B` | 100ms Power Factor B | LATEST | instantaneous |
| 3327 | `PME_3477_100MS_POWER_FACTOR_C` | 100ms Power Factor C | LATEST | instantaneous |
| 1206 | `PME_1262_DISPLACEMENT_POWER_F` | Displacement Power Factor Total | LATEST | instantaneous |
| 1203 | `PME_1259_DISPLACEMENT_POWER_F` | Displacement Power Factor A | LATEST | instantaneous |
| 1204 | `PME_1260_DISPLACEMENT_POWER_F` | Displacement Power Factor B | LATEST | instantaneous |
| 1205 | `PME_1261_DISPLACEMENT_POWER_F` | Displacement Power Factor C | LATEST | instantaneous |

**Primary metric:** ID 1072 (100ms True Power Factor Total) - use for PF queries.

---

### Voltage

**Natural language terms:** "voltage", "V", "volts"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 1060 | `PME_1092_100MS_VOLTAGE_A-N` | 100ms Voltage A-N | LATEST | instantaneous |
| 1061 | `PME_1093_100MS_VOLTAGE_B-N` | 100ms Voltage B-N | LATEST | instantaneous |
| 1062 | `PME_1094_100MS_VOLTAGE_C-N` | 100ms Voltage C-N | LATEST | instantaneous |
| 1057 | `PME_1089_100MS_VOLTAGE_A-B` | 100ms Voltage A-B | LATEST | instantaneous |
| 1058 | `PME_1090_100MS_VOLTAGE_B-C` | 100ms Voltage B-C | LATEST | instantaneous |
| 1059 | `PME_1091_100MS_VOLTAGE_C-A` | 100ms Voltage C-A | LATEST | instantaneous |
| 3331 | `PME_3481_100MS_VOLTAGE_L-L_AV` | 100ms Voltage L-L Avg | LATEST | instantaneous |
| 3332 | `PME_3482_100MS_VOLTAGE_L-N_AV` | 100ms Voltage L-N Avg | LATEST | instantaneous |

---

### Voltage Unbalance

**Natural language terms:** "voltage unbalance", "unbalance"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 1116 | `PME_1148_VOLTAGE_UNBALANCE_L-` | Voltage Unbalance L-L | LATEST | instantaneous |
| 1117 | `PME_1149_VOLTAGE_UNBALANCE_L-` | Voltage Unbalance L-N | LATEST | instantaneous |
| 2048 | `PME_2106_VOLTAGE_UNBALANCE_A-` | Voltage Unbalance A-B | LATEST | instantaneous |
| 2049 | `PME_2107_VOLTAGE_UNBALANCE_A-` | Voltage Unbalance A-N | LATEST | instantaneous |
| 2050 | `PME_2108_VOLTAGE_UNBALANCE_B-` | Voltage Unbalance B-C | LATEST | instantaneous |
| 2051 | `PME_2109_VOLTAGE_UNBALANCE_B-` | Voltage Unbalance B-N | LATEST | instantaneous |
| 2052 | `PME_2110_VOLTAGE_UNBALANCE_C-` | Voltage Unbalance C-A | LATEST | instantaneous |
| 2053 | `PME_2111_VOLTAGE_UNBALANCE_C-` | Voltage Unbalance C-N | LATEST | instantaneous |
| 2054 | `PME_2112_VOLTAGE_UNBALANCE_L-` | Voltage Unbalance L-L Worst | LATEST | instantaneous |
| 2055 | `PME_2113_VOLTAGE_UNBALANCE_L-` | Voltage Unbalance L-N Worst | LATEST | instantaneous |

---

### Current

**Natural language terms:** "current", "amps", "A"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 501 | `PME_515_CURRENT_PHASE_A` | Current Phase A | LATEST | instantaneous |
| 502 | `PME_516_CURRENT_PHASE_B` | Current Phase B | LATEST | instantaneous |
| 503 | `PME_517_CURRENT_PHASE_C` | Current Phase C | LATEST | instantaneous |
| 1056 | `PME_1088_100MS_CURRENT_N` | 100ms Current N | LATEST | instantaneous |
| 3324 | `PME_3474_100MS_CURRENT_AVG` | 100ms Current Avg | LATEST | instantaneous |

---

### Current Unbalance

**Natural language terms:** "current unbalance"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 1199 | `PME_1255_CURRENT_UNBALANCE_A` | Current Unbalance A | LATEST | instantaneous |
| 1200 | `PME_1256_CURRENT_UNBALANCE_B` | Current Unbalance B | LATEST | instantaneous |
| 1201 | `PME_1257_CURRENT_UNBALANCE_C` | Current Unbalance C | LATEST | instantaneous |
| 1202 | `PME_1258_CURRENT_UNBALANCE_WO` | Current Unbalance Worst | LATEST | instantaneous |

---

### THD (Total Harmonic Distortion)

**Natural language terms:** "THD", "harmonics", "distortion"

#### THD Voltage

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 1118 | `PME_1150_THD_VOLTAGE_L-L` | THD Voltage L-L | LATEST | instantaneous |
| 1119 | `PME_1151_THD_VOLTAGE_L-N` | THD Voltage L-N | LATEST | instantaneous |
| 2034 | `PME_2092_THD_VOLTAGE_A-B` | THD Voltage A-B | LATEST | instantaneous |
| 2035 | `PME_2093_THD_VOLTAGE_A-N` | THD Voltage A-N | LATEST | instantaneous |
| 2036 | `PME_2094_THD_VOLTAGE_B-C` | THD Voltage B-C | LATEST | instantaneous |
| 2037 | `PME_2095_THD_VOLTAGE_B-N` | THD Voltage B-N | LATEST | instantaneous |
| 2038 | `PME_2096_THD_VOLTAGE_C-A` | THD Voltage C-A | LATEST | instantaneous |
| 2039 | `PME_2097_THD_VOLTAGE_C-N` | THD Voltage C-N | LATEST | instantaneous |

#### THD Current

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 2097 | `PME_2197_THD_RMS_CURRENT_A` | THD RMS Current A | LATEST | instantaneous |
| 2098 | `PME_2198_THD_RMS_CURRENT_B` | THD RMS Current B | LATEST | instantaneous |
| 2099 | `PME_2199_THD_RMS_CURRENT_C` | THD RMS Current C | LATEST | instantaneous |
| 2100 | `PME_2200_THD_RMS_CURRENT_N` | THD RMS Current N | LATEST | instantaneous |

---

### Frequency

**Natural language terms:** "frequency", "Hz"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 526 | `PME_540_FREQUENCY` | Frequency | LATEST | instantaneous |

---

## Water Quantities (4)

**Natural language terms:** "water", "flow", "temperature"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 3923 | `PME_4155_WATER_TEMPERATURE_SU` | Water Temperature Supply (deg C) | LATEST | instantaneous |
| 3937 | `PME_4169_WATER_TEMPERATURE_RE` | Water Temperature Return (deg C) | LATEST | instantaneous |
| 3787 | `PME_3998_WATER_VOLUME_FLOW_RA` | Water Volume Flow Rate (m^3/h) | SUM | instantaneous |
| 5696 | `PME_6034_WATER_VOLUME_SUPPLY_` | Water Volume Supply (m^3) | SUM | instantaneous |

**Note:** ID 3777 (`Water Volume Current Day Total`) is categorized as Electricity in the database but is actually a water metric.

---

## Air Quantities (1)

**Natural language terms:** "air", "velocity"

| ID | Quantity Code | Quantity Name | Aggregation | Type |
|----|---------------|---------------|-------------|------|
| 5906 | `PME_6243_AIR_VELOCITY_MS` | Air Velocity (m/s) | LATEST | instantaneous |

---

## Aggregation Method Reference

| Method | Use Case | Example Quantities |
|--------|----------|-------------------|
| `SUM` | Cumulative quantities | Energy (kWh), Volume (m^3) |
| `LATEST` | Instantaneous measurements | Power (kW), Voltage (V), Current (A) |
| `AVG` | Average over period | (Use LATEST with time bucketing) |
| `MAX` | Peak analysis | (Derived from LATEST values) |

**Note:** The database uses `LATEST` for most instantaneous quantities. For aggregation over time periods, apply `AVG` or `MAX` in the query.

---

## Implementation Status

### Completed

- [x] Query actual `quantities` table and populate all entries
- [x] Verify quantity IDs match production database
- [x] Document all 77 quantities currently in use
- [x] Implement `list_quantities` tool with semantic aliases

### Pending

- [ ] Add unit information to database (currently NULL for most quantities)
- [ ] Implement unit scaling logic (kW → MW, kWh → MWh)

---

## Related Documentation

- [Concept Document](./concept.md) - Overall MCP server design
- [Tool Implementation](../src/pfn_mcp/tools/quantities.py) - list_quantities tool

---

**Document Status:** Populated from production database
**Last Updated:** 2025-12-25
