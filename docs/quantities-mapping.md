# Quantities Mapping Specification

**Created:** 2025-12-25
**Status:** Template - Pending Database Population
**Purpose:** Semantic layer mapping between database quantities and human-readable metrics

---

## Overview

This document defines the mapping between the `quantities` table in the Valkyrie database and the natural language terms users might use when querying data through the MCP server.

### Database Schema Reference

```sql
CREATE TABLE public.quantities (
    id integer NOT NULL,
    quantity_code character varying(50) NOT NULL,    -- e.g., "ACTIVE_POWER_L1"
    quantity_name character varying(255) NOT NULL,   -- e.g., "Active Power Phase L1"
    unit character varying(50),                      -- e.g., "kW"
    category character varying(100),                 -- e.g., "ELECTRICAL"
    data_type character varying(50) DEFAULT 'NUMERIC',
    aggregation_method character varying(50) DEFAULT 'SUM',
    description text,
    is_active boolean DEFAULT true,
    is_cumulative boolean DEFAULT false
);
```

---

## WAGE Categories

Telemetry data is organized into four primary categories:

| Category | Code | Description | Example Quantities |
|----------|------|-------------|-------------------|
| **W**ater | WATER | Water flow and consumption | Flow rate, volume, pressure |
| **A**ir | AIR | Compressed air systems | Pressure, flow rate, volume |
| **G**as | GAS | Natural gas consumption | Flow rate, volume, pressure |
| **E**lectricity | ELECTRICAL | Power and energy metrics | Power, energy, voltage, current, power factor |

---

## Semantic Alias Groups

Users can query using natural language terms. The MCP server resolves these to specific quantity IDs.

### Energy Consumption

**Natural language terms:** "energy", "consumption", "energy consumption", "kWh", "how much energy"

| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| 124 | `ACTIVE_ENERGY_TOTAL` | Active Energy Total | kWh | Primary energy metric |
| 62 | `ACTIVE_ENERGY_IMPORT` | Active Energy Import | kWh | Grid import |
| 89 | `ACTIVE_ENERGY_EXPORT` | Active Energy Export | kWh | Solar/generator export |
| 96 | `ACTIVE_ENERGY_L1` | Active Energy Phase L1 | kWh | Per-phase energy |
| 130 | `ACTIVE_ENERGY_L2` | Active Energy Phase L2 | kWh | Per-phase energy |
| 481 | `ACTIVE_ENERGY_L3` | Active Energy Phase L3 | kWh | Per-phase energy |

**Aggregation:** SUM (cumulative consumption over time period)

---

### Power Demand

**Natural language terms:** "power", "demand", "load", "peak demand", "peak power", "kW"

| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| 185 | `ACTIVE_POWER_TOTAL` | Active Power Total | kW | Primary power metric |
| TBD | `ACTIVE_POWER_L1` | Active Power Phase L1 | kW | Per-phase power |
| TBD | `ACTIVE_POWER_L2` | Active Power Phase L2 | kW | Per-phase power |
| TBD | `ACTIVE_POWER_L3` | Active Power Phase L3 | kW | Per-phase power |
| TBD | `APPARENT_POWER` | Apparent Power | kVA | For sizing calculations |
| TBD | `REACTIVE_POWER` | Reactive Power | kVAR | For PF correction |

**Aggregation:**
- Average: `AVG` (typical demand)
- Peak: `MAX` (peak demand analysis)

---

### Power Quality

**Natural language terms:** "power quality", "power factor", "PF", "voltage", "current", "unbalance"

#### Power Factor
| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `POWER_FACTOR_TOTAL` | Power Factor Total | - | Target: > 0.85 |
| TBD | `POWER_FACTOR_L1` | Power Factor Phase L1 | - | Per-phase PF |
| TBD | `POWER_FACTOR_L2` | Power Factor Phase L2 | - | Per-phase PF |
| TBD | `POWER_FACTOR_L3` | Power Factor Phase L3 | - | Per-phase PF |

**Aggregation:** AVG

#### Voltage
| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `VOLTAGE_L1N` | Voltage L1-N | V | Phase to neutral |
| TBD | `VOLTAGE_L2N` | Voltage L2-N | V | Phase to neutral |
| TBD | `VOLTAGE_L3N` | Voltage L3-N | V | Phase to neutral |
| TBD | `VOLTAGE_L1L2` | Voltage L1-L2 | V | Line to line |
| TBD | `VOLTAGE_L2L3` | Voltage L2-L3 | V | Line to line |
| TBD | `VOLTAGE_L3L1` | Voltage L3-L1 | V | Line to line |
| TBD | `VOLTAGE_UNBALANCE` | Voltage Unbalance | % | Quality indicator |

**Aggregation:** AVG (with MIN/MAX for range analysis)

#### Current
| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `CURRENT_L1` | Current Phase L1 | A | Per-phase current |
| TBD | `CURRENT_L2` | Current Phase L2 | A | Per-phase current |
| TBD | `CURRENT_L3` | Current Phase L3 | A | Per-phase current |
| TBD | `CURRENT_N` | Neutral Current | A | Should be low |
| TBD | `CURRENT_UNBALANCE` | Current Unbalance | % | Quality indicator |

**Aggregation:** AVG (with MAX for peak analysis)

---

### Gas Consumption

**Natural language terms:** "gas", "natural gas", "gas consumption", "cubic meter", "m³"

| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `GAS_VOLUME` | Gas Volume | m³ | Cumulative consumption |
| TBD | `GAS_FLOW_RATE` | Gas Flow Rate | m³/h | Instantaneous flow |

**Aggregation:** SUM (volume), AVG (flow rate)

---

### Water Consumption

**Natural language terms:** "water", "water consumption", "flow", "water flow"

| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `WATER_VOLUME` | Water Volume | m³ | Cumulative consumption |
| TBD | `WATER_FLOW_RATE` | Water Flow Rate | m³/h | Instantaneous flow |

**Aggregation:** SUM (volume), AVG (flow rate)

---

### Compressed Air

**Natural language terms:** "air", "compressed air", "air pressure", "air flow"

| Quantity ID | Quantity Code | Quantity Name | Unit | Notes |
|-------------|---------------|---------------|------|-------|
| TBD | `AIR_PRESSURE` | Air Pressure | bar | System pressure |
| TBD | `AIR_FLOW_RATE` | Air Flow Rate | m³/min | Instantaneous flow |
| TBD | `AIR_VOLUME` | Air Volume | m³ | Cumulative consumption |

**Aggregation:** AVG (pressure), SUM (volume), AVG (flow rate)

---

## Aggregation Method Reference

| Method | Use Case | Example |
|--------|----------|---------|
| `SUM` | Cumulative quantities | Energy (kWh), Volume (m³) |
| `AVG` | Instantaneous measurements | Power (kW), Voltage (V), Power Factor |
| `MAX` | Peak analysis | Peak demand, maximum current |
| `MIN` | Minimum analysis | Minimum voltage (sag detection) |
| `COUNT` | Data availability | Number of readings in period |

---

## Unit Display Formatting

| Unit | Display Format | Scale Options |
|------|----------------|---------------|
| kWh | `{value:,.2f} kWh` | MWh for large values (> 1000 kWh) |
| kW | `{value:,.2f} kW` | MW for large values (> 1000 kW) |
| V | `{value:,.1f} V` | - |
| A | `{value:,.2f} A` | - |
| m³ | `{value:,.2f} m³` | - |
| % | `{value:.1f}%` | - |

---

## Implementation Tasks

### Phase 1 Deliverables

- [ ] Query actual `quantities` table and populate all TBD entries
- [ ] Verify quantity IDs match production database
- [ ] Add any missing quantities discovered in database
- [ ] Create SQL views or functions for alias resolution
- [ ] Implement unit scaling logic

### Query to Populate This Document

```sql
SELECT
    id,
    quantity_code,
    quantity_name,
    unit,
    category,
    aggregation_method,
    is_cumulative,
    description
FROM public.quantities
WHERE is_active = true
ORDER BY category, quantity_name;
```

---

## Related Documentation

- [Concept Document](./concept.md) - Overall MCP server design
- [Database README](./schema/DB_README.md) - Database overview
- [Full Schema](./schema/full-schema.sql) - Complete database schema

---

**Document Status:** Template awaiting database population
**Next Action:** Execute query against production database to populate quantity IDs
