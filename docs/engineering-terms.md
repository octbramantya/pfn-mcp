# Engineering Terms → Quantity Mapping

This document defines the canonical quantity mappings for common engineering terms used in natural language queries.

**Purpose:** When users ask for "current" or "voltage" without specifying phase or type, the system should return the most commonly expected measurement.

**Action Required:** Engineering team to review and confirm/modify the suggested defaults.

---

## Electricity - Current

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "current" | **3324** | 3324 | 100ms Current Avg | Average across all phases |
| "neutral current" | 1056 | 1056 | 100ms Current N | Neutral line |
| "phase A current" | 501 | 501 | Current Phase A | Single phase |
| "phase B current" | 502 | 502 | Current Phase B | Single phase |
| "phase C current" | 503 | 503 | Current Phase C | Single phase |

**Available quantities:**
- 3324: 100ms Current Avg
- 1056: 100ms Current N
- 501: Current Phase A
- 502: Current Phase B
- 503: Current Phase C

---

## Electricity - Voltage

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "voltage" | **3332** | 3332 | 100ms Voltage L-N Avg | Line-to-neutral average |
| "line voltage" | 3331 | 3331 | 100ms Voltage L-L Avg | Line-to-line average |
| "voltage A-N" | 1060 | 1060 | 100ms Voltage A-N | Phase A to neutral |
| "voltage B-N" | 1061 | 1061 | 100ms Voltage B-N | Phase B to neutral |
| "voltage C-N" | 1062 | 1062 | 100ms Voltage C-N | Phase C to neutral |
| "voltage A-B" | 1057 | 1057 | 100ms Voltage A-B | Line-to-line |
| "voltage B-C" | 1058 | 1058 | 100ms Voltage B-C | Line-to-line |
| "voltage C-A" | 1059 | 1059 | 100ms Voltage C-A | Line-to-line |

**Available quantities:**
- 3332: 100ms Voltage L-N Avg
- 3331: 100ms Voltage L-L Avg
- 1057: 100ms Voltage A-B
- 1058: 100ms Voltage B-C
- 1059: 100ms Voltage C-A
- 1060: 100ms Voltage A-N
- 1061: 100ms Voltage B-N
- 1062: 100ms Voltage C-N

---

## Electricity - Power Factor

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "power factor", "pf" | **1072** | 1072 | 100ms True Power Factor Total | True PF, system total |
| "displacement power factor" | 1206 | 1206 | Displacement Power Factor Total | DPF total |
| "pf phase A" | 3325 | 3325 | 100ms Power Factor A | Per-phase |
| "pf phase B" | 3326 | 3326 | 100ms Power Factor B | Per-phase |
| "pf phase C" | 3327 | 3327 | 100ms Power Factor C | Per-phase |

**Available quantities:**
- 1072: 100ms True Power Factor Total
- 1206: Displacement Power Factor Total
- 3325: 100ms Power Factor A
- 3326: 100ms Power Factor B
- 3327: 100ms Power Factor C
- 1203: Displacement Power Factor A
- 1204: Displacement Power Factor B
- 1205: Displacement Power Factor C

---

## Electricity - Power (Instantaneous)

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "power", "kW" | **185** | 185 | Active Power | Real power, total |
| "reactive power", "kVAR" | 179 | 179 | Reactive Power | VAR, total |
| "apparent power", "kVA" | 530 | 530 | Apparent Power | VA, total |
| "power phase A" | 504 | 504 | Active Power Phase A | Per-phase |
| "power phase B" | 505 | 505 | Active Power Phase B | Per-phase |
| "power phase C" | 506 | 506 | Active Power Phase C | Per-phase |

**Available quantities:**
- 185: Active Power (total)
- 179: Reactive Power (total)
- 530: Apparent Power (total)
- 504-506: Active Power Phase A/B/C
- 507-509: Reactive Power Phase A/B/C
- 510-512: Apparent Power Phase A/B/C

---

## Electricity - Energy (Cumulative)

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "energy", "kWh" | **124** | 124 | Active Energy Delivered | Cumulative, billing |
| "consumption" | 124 | 124 | Active Energy Delivered | Same as energy |
| "net energy" | 130 | 130 | Active Energy Delivered-Received | Net metering |
| "total energy" | 190 | 190 | Active Energy Delivered+Received | Absolute total |
| "reactive energy" | 89 | 89 | Reactive Energy Delivered | kVARh |
| "apparent energy" | 481 | 481 | Apparent Energy Delivered | kVAh |

**Note:** For energy queries, recommend using `get_energy_consumption` tool instead of `get_device_telemetry`.

**Available quantities:**
- 124: Active Energy Delivered (is_cumulative=true)
- 130: Active Energy Delivered-Received (is_cumulative=true)
- 131: Active Energy Received
- 190: Active Energy Delivered+Received
- 89: Reactive Energy Delivered (is_cumulative=true)
- 95: Reactive Energy Delivered-Received
- 96: Reactive Energy Received (is_cumulative=true)
- 183: Reactive Energy Delivered + Received
- 62: Apparent Energy Delivered + Received (is_cumulative=true)
- 471: Apparent Energy Received
- 481: Apparent Energy Delivered

---

## Electricity - Frequency

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "frequency", "Hz" | **526** | 526 | Frequency | System frequency |

**Available quantities:**
- 526: Frequency (single quantity)

---

## Electricity - THD (Harmonics)

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "THD", "harmonics" | ? | ? | ? | **NEEDS DECISION** |
| "THD voltage" | 1119 | 1119 | THD Voltage L-N | Line-to-neutral |
| "THD current" | ? | ? | ? | **NEEDS DECISION** |

**Available quantities:**
- 1118: THD Voltage L-L
- 1119: THD Voltage L-N
- 2034-2039: THD Voltage per phase (A-B, A-N, B-C, B-N, C-A, C-N)
- 2097-2100: THD RMS Current A/B/C/N

**Question for engineering:** What's the default THD metric engineers expect?

---

## Electricity - Unbalance

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "current unbalance" | 1202 | 1202 | Current Unbalance Worst | Worst case |
| "voltage unbalance" | 1117 | 1117 | Voltage Unbalance L-N | Voltage Unbalance L-N |

**Available quantities:**
- 1199-1201: Current Unbalance A/B/C
- 1202: Current Unbalance Worst
- 1116: Voltage Unbalance L-L
- 1117: Voltage Unbalance L-N
- 2048-2055: Voltage Unbalance per phase and worst

**Question for engineering:** What's the default voltage unbalance metric?

---

## Water

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "Flow rate" | 3787 | 3787 | Water Volume Flow Rate (m³/h) | Flow rate |
| "Volume" | 5696 | 5696 | Water Volume Supply (m³) | Cumulative |
| "supply temperature" | 3923 | 3937 | Water Temperature Return | Supply temperature |

**Available quantities:**
- 3787: Water Volume Flow Rate (m³/h)
- 3777: Water Volume Current Day Total (m³)
- 5696: Water Volume Supply (m³)
- 3923: Water Temperature Supply (deg C)
- 3937: Water Temperature Return (deg C)

**Question for engineering:** Default for "water temperature" - supply or return?
**Notes**: Flow and volume used interchangebly between water and air monitoring devices

---

## Air

| Engineering Term | Suggested Default | Quantity ID | Quantity Name | Notes |
|------------------|-------------------|-------------|---------------|-------|
| "air velocity" | 5906 | 5906 | Air Velocity (m/s) | Only air metric |

**Available quantities:**
- 5906: Air Velocity (m/s)
**Notes**: Flow and volume used interchangebly between water and air monitoring devices
---

## Summary - Confirmed Defaults

| Term | Quantity ID | Quantity Name | Status |
|------|-------------|---------------|--------|
| current | 3324 | 100ms Current Avg | ✅ Suggested |
| voltage | 3332 | 100ms Voltage L-N Avg | ✅ Suggested |
| power factor / pf | 1072 | 100ms True Power Factor Total | ✅ Suggested |
| power / kW | 185 | Active Power | ✅ Suggested |
| reactive power | 179 | Reactive Power | ✅ Suggested |
| apparent power | 530 | Apparent Power | ✅ Suggested |
| energy / kWh | 124 | Active Energy Delivered | ✅ Suggested |
| frequency | 526 | Frequency | ✅ Suggested |
| THD | ? | ? | ❓ Needs decision |
| voltage unbalance | ? | ? | ❓ Needs decision |
| water temperature | ? | ? | ❓ Needs decision |

---

## Questions for Engineering Review

1. **THD default:** When user asks for "THD", what's the expected measurement?
   - THD Voltage L-N (1119)?
   - THD Current (which phase)?
   - Or require explicit "THD voltage" / "THD current"?
   - **Answer: THD Voltage L-N**

2. **Voltage unbalance default:** What metric?
   - Voltage Unbalance L-N (1117)?
   - Voltage Unbalance L-N Worst (2055)?
   - **Answer: Voltage Unbalance L-N**

3. **Water temperature:** Supply (3923) or Return (3937)?
   - **Answer: supply**

4. **Any missing terms?** Are there other common engineering terms that should be mapped?

---

## Indonesian Electricity Terminology

### Rate Codes (Time-of-Use Pricing)

| Code | Indonesian | English | Description |
|------|------------|---------|-------------|
| WBP | Waktu Beban Puncak | Peak Period | Higher electricity rate (~Rp 1,550/kWh) |
| LWBP | Luar Waktu Beban Puncak | Off-Peak Period | Lower electricity rate (~Rp 1,035/kWh) |
| LWBP1 | - | Morning Off-Peak | Early morning hours |
| LWBP2 | - | Night Off-Peak | Late night hours |

### Work Shifts

| Shift | Typical Hours | Description |
|-------|---------------|-------------|
| SHIFT1 | 22:00 - 06:00 | Night shift |
| SHIFT2 | 06:00 - 14:00 | Day shift |
| SHIFT3 | 14:00 - 22:00 | Evening shift |

### Utility Sources

| Source | Description |
|--------|-------------|
| PLN | State electricity company (grid power) |
| Solar/PV | On-site solar photovoltaic generation |

### Common User Queries → Tool Mapping

| User asks about... | Use group_by | Notes |
|--------------------|--------------|-------|
| "peak vs off-peak" | `rate` | Shows WBP vs LWBP breakdown |
| "daily rate breakdown" | `daily_rate` | Per-day WBP/LWBP distribution |
| "shift productivity" | `shift` | By work shift |
| "PLN vs solar" | `source` | Grid vs on-site generation |
