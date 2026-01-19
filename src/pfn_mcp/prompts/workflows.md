# PFN Energy Intelligence - Workflow Shortcuts

Slash commands are pre-defined tool chains that skip exhaustive tool search.

## /daily-digest

**Trigger:** "morning report", "how was yesterday", "daily overview"

**Execute:**
```
get_wages_data(tenant="[TENANT]", aggregation="facility", period="7d", breakdown="daily")
```

**Identify dates from context:**
- Today = [CURRENT_DATE] → day in progress (still accumulating)
- Yesterday = [YESTERDAY_DATE] → full day data (use this for report)
- Day before = [DAY_BEFORE_YESTERDAY]

**IMPORTANT:** The last entry in daily breakdown may be TODAY's data (lower kWh is normal - day still in progress).
Always match dates explicitly - "yesterday" means [YESTERDAY_DATE], NOT the last row.

**Present:**
1. Yesterday's ([YESTERDAY_DATE]) total consumption (kWh) and cost (IDR)
2. Comparison vs day-before ([DAY_BEFORE_YESTERDAY]) (% change)
3. Comparison vs 7-day average (% change)
4. Optionally mention today's consumption so far

Format as brief executive summary (4-6 lines).

---

## /dept-breakdown [group_by]

**Trigger:** "breakdown by department", "consumption by process"

**Default:** group_by = "equipment_type"
**Options:** "equipment_type", "process", "building"

**Execute:**
```
get_wages_data(tenant="[TENANT]", tag_key="[group_by]", period="yesterday", breakdown="device")
```

**Present:** Ranked table with consumption and % of total.

---

## /peak-report

**Trigger:** "peak current", "peak power", "when was max demand"

**Execute:**
```
get_wages_data(tenant="[TENANT]", aggregation="facility", quantity_search="power", agg_method="max", period="24h")
```

**Present:** Peak times, values, and devices responsible.

---

## /weekly-summary

**Trigger:** "weekly report", "last week summary"

**Execute:**
```
get_wages_data(tenant="[TENANT]", aggregation="facility", period="7d")
get_wages_data(tenant="[TENANT]", aggregation="facility", period="7d", breakdown="device")
```

**Present:**
- Total consumption and cost
- Top 5 cost drivers
- Week-over-week trend

---

## /device-status [device_name]

**Trigger:** "is [device] online", "check [device]"

**Execute:**
```
check_data_freshness(device_name="[device]")
```

**Present:** Online/offline/stale status with last data timestamp.

---

## /compare [A] vs [B]

**Trigger:** "compare X and Y", "X versus Y consumption"

**Execute:** `compare_groups()` or `compare_electricity_periods()` depending on context.

---

## /anomalies

**Trigger:** "any issues", "unusual consumption", "problems today"

**Execute:**
```
get_wages_data(tenant="[TENANT]", aggregation="facility", period="7d", breakdown="daily")
```

**Analyze:** Identify deviations >15% from average.
