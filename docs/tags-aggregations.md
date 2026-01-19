# Device Tags & Meter Aggregations Guide

This document explains when and how to add entries to `device_tags` and `meter_aggregations` tables.

## Quick Reference

| Table | Purpose | When to Use |
|-------|---------|-------------|
| `device_tags` | Label devices with attributes | "Which devices are compressors?" |
| `meter_aggregations` | Define formulas for calculations | "What's yarn division consumption?" (=Main - Fabric) |

**Key difference:** Tags are labels on devices. Aggregations are math formulas.

---

## Device Tags

### What Are Tags?

Tags are key-value labels attached to individual devices. They enable grouping and filtering.

```
Device 62 (Waterjet-1):
  - process = Waterjet
  - building = Factory A
  - equipment_type = Loom
```

### When to Add Tags

Add a tag when you need to answer questions like:
- "What's the total consumption for all Waterjet machines?"
- "Which devices are in Building B?"
- "Show me all compressors"

### Current Tag Keys

| Tag Key | Purpose | Example Values |
|---------|---------|----------------|
| `process` | Production process | Waterjet, Dyeing, Airjet, Weaving |
| `building` | Physical location | Factory A, Factory B, Utility |
| `equipment_type` | Type of equipment | Compressor, Pump, Motor, Loom, Chiller |

### How to Add Tags

```sql
-- Add single tag
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES (62, 'equipment_type', 'Loom', 'classification', true);

-- Add multiple tags to one device
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES
  (62, 'process', 'Waterjet', 'classification', true),
  (62, 'building', 'Factory A', 'location', true);

-- Tag multiple devices with same value
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES
  (70, 'equipment_type', 'Compressor', 'classification', true),
  (71, 'equipment_type', 'Compressor', 'classification', true),
  (72, 'equipment_type', 'Compressor', 'classification', true);
```

### Tag Categories

Use these categories for organization:
- `classification` - Equipment type, process
- `location` - Building, area, floor
- `ownership` - Department, cost center

### Verification

```sql
-- List all tags for a device
SELECT tag_key, tag_value
FROM device_tags
WHERE device_id = 62 AND is_active = true;

-- List all devices with a specific tag
SELECT d.device_id, d.display_name, dt.tag_value
FROM device_tags dt
JOIN devices d ON d.device_id = dt.device_id
WHERE dt.tag_key = 'equipment_type' AND dt.is_active = true
ORDER BY dt.tag_value, d.display_name;

-- Count devices per tag value
SELECT tag_value, COUNT(*) as device_count
FROM device_tags
WHERE tag_key = 'process' AND is_active = true
GROUP BY tag_value
ORDER BY device_count DESC;
```

---

## Meter Aggregations

### What Are Aggregations?

Aggregations are named formulas that calculate totals from multiple devices. They support addition AND subtraction.

```
facility = 94 + 11 + 27      (Main + Genset + Solar)
yarn_division = 94 - 84      (Main minus Fabric sub-meter)
```

### When to Add Aggregations

Add an aggregation when you need:
- **Subtraction**: Derived values like "Main meter minus sub-meters"
- **Named totals**: Predefined scope like "facility total" or "division total"
- **Complex formulas**: Combinations that can't be expressed with tags

### Current Aggregations

| Name | Formula | Description |
|------|---------|-------------|
| `facility` | 94+11+27 | Total facility (Main + Genset + Solar) |
| `yarn_division` | 94-84 | Yarn division (Main - Fabric sub-meter) |
| `fabric_division` | 84+11+27 | Fabric division meters |

### How to Add Aggregations

```sql
-- Add new aggregation
INSERT INTO meter_aggregations (tenant_id, name, aggregation_type, formula, description)
VALUES (
  1,                          -- tenant_id (PRS = 1)
  'utility_building',         -- name (used in API calls)
  'device_group',             -- aggregation_type
  '70+71+72',                 -- formula (device IDs)
  'Utility building total (Compressor 1 + 2 + 3)'
);

-- Add aggregation with subtraction
INSERT INTO meter_aggregations (tenant_id, name, aggregation_type, formula, description)
VALUES (
  1,
  'production_only',
  'device_group',
  '94-70-71-72',              -- Main minus utility devices
  'Production consumption (excludes utilities)'
);
```

### Formula Syntax

| Pattern | Meaning | Example |
|---------|---------|---------|
| `A+B+C` | Sum of devices | `94+11+27` |
| `A-B` | Difference | `94-84` |
| `A-B-C` | Chained subtraction | `94-70-71` |
| `(A+B)-C` | Grouped operations | `(94+11)-(84)` |

**Note:** Device IDs in formulas refer to `device_id` column in `devices` table.

### Verification

```sql
-- List all aggregations for a tenant
SELECT name, formula, description
FROM meter_aggregations
WHERE tenant_id = 1
ORDER BY name;

-- Verify device IDs in formula exist
SELECT device_id, display_name
FROM devices
WHERE device_id IN (94, 11, 27);  -- Replace with your formula IDs
```

---

## Decision Tree

```
Need to group devices?
│
├─ By attribute (type, location, process)?
│   └─ Use TAGS
│      Example: tag_key="equipment_type", tag_value="Compressor"
│
├─ Need subtraction (A minus B)?
│   └─ Use AGGREGATION
│      Example: aggregation="yarn_division" (formula: 94-84)
│
├─ Named organizational unit?
│   └─ Use AGGREGATION
│      Example: aggregation="facility"
│
└─ Discovery needed ("what types exist?")?
    └─ Use TAGS (supports list_tag_values)
```

---

## Common Scenarios

### Scenario 1: "Add new compressor to monitoring"

New device ID 75 is a compressor in the utility building.

```sql
-- Add tags
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES
  (75, 'equipment_type', 'Compressor', 'classification', true),
  (75, 'building', 'Utility', 'location', true);
```

### Scenario 2: "Track new production line separately"

New sub-meter (device 85) measures Line 3. Need to track Line 3 and exclude it from existing totals.

```sql
-- Option A: Add as tag for simple grouping
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES (85, 'production_line', 'Line 3', 'classification', true);

-- Option B: Add aggregation if you need derived calculation
INSERT INTO meter_aggregations (tenant_id, name, aggregation_type, formula, description)
VALUES (1, 'lines_1_2_only', 'device_group', '94-85', 'Lines 1-2 (excludes Line 3)');
```

### Scenario 3: "Group devices by department for cost allocation"

```sql
-- Add department tags to devices
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, is_active)
VALUES
  (62, 'department', 'Production', 'ownership', true),
  (63, 'department', 'Production', 'ownership', true),
  (70, 'department', 'Facilities', 'ownership', true),
  (71, 'department', 'Facilities', 'ownership', true);
```

---

## Checklist Before Adding

### For Tags
- [ ] Tag key exists or is a new logical grouping
- [ ] Tag value is consistent with existing values (check spelling/casing)
- [ ] Device ID is correct (verify in `devices` table)
- [ ] `is_active = true` for active tags

### For Aggregations
- [ ] All device IDs in formula exist
- [ ] Name is unique within tenant
- [ ] Formula syntax is correct (use `+` and `-` only)
- [ ] Description explains what the aggregation represents

---

## Support

For questions about device classification or formula definitions, contact the energy monitoring team.
