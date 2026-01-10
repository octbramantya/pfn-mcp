# Open WebUI Model System Prompt

Configuration for LLM models in Open WebUI to provide domain knowledge for energy monitoring queries.

**Location:** Open WebUI Admin → Workspace → Models → [Model] → System Prompt

---

## System Prompt Content

```
## Energy Monitoring Domain Knowledge

When users ask about electrical measurements, use these canonical mappings:

| User says | Use quantity_id | Quantity name |
|-----------|-----------------|---------------|
| "current" | 3324 | 100ms Current Avg |
| "voltage" | 3332 | 100ms Voltage L-N Avg |
| "power factor", "pf" | 1072 | 100ms True Power Factor Total |
| "power", "kW" | 185 | Active Power |
| "reactive power", "kVAR" | 179 | Reactive Power |
| "apparent power", "kVA" | 530 | Apparent Power |
| "frequency" | 526 | Frequency |
| "thd" | 1119 | THD Voltage L-N |
| "voltage unbalance" | 1117 | Voltage Unbalance L-N |

For phase-specific measurements (e.g., "current phase A"), use the full name in quantity_search.

**Indonesian Electricity Terms:**
- WBP (Waktu Beban Puncak) = Peak Period - higher rate
- LWBP (Luar WBP) = Off-Peak Period - lower rate
- SHIFT1: Night (22:00-06:00), SHIFT2: Day (06:00-14:00), SHIFT3: Evening (14:00-22:00)

For energy/consumption queries, use `get_energy_consumption` tool, not `get_device_telemetry`.
```

---

## Purpose

This system prompt provides domain knowledge that helps LLMs:

1. **Resolve ambiguous quantity terms** - When users say "current", the model knows to use quantity ID 3324 (100ms Current Avg) instead of picking alphabetically
2. **Understand Indonesian electricity terminology** - WBP/LWBP rate codes and shift periods
3. **Choose correct tools** - Direct energy queries to `get_energy_consumption` instead of `get_device_telemetry`

---

## Related Files

| File | Purpose |
|------|---------|
| `src/pfn_mcp/tools.yaml` | Tool descriptions with canonical mappings |
| `src/pfn_mcp/tools/quantities.py` | QUANTITY_ALIASES for server-side resolution |
| `docs/engineering-terms.md` | Engineering reference for quantity mappings |

---

## Maintenance

When adding new quantity mappings:
1. Update `QUANTITY_ALIASES` in `quantities.py`
2. Update tool descriptions in `tools.yaml`
3. Update this system prompt
4. Apply changes in Open WebUI Admin UI
