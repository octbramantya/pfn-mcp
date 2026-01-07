# Tagging System Enhancement: `search_tags` Tool

## Problem

Users ask "What's energy for PRS?" but the system can't resolve "PRS" without knowing the `tag_key`. Current tools require prior knowledge of tag structure:

| Tool | Limitation |
|------|------------|
| `list_tags(tag_key)` | Requires knowing tag_key to filter |
| `list_tag_values(tag_key)` | Requires tag_key parameter |

**Gap**: No search by `tag_value` alone.

## Solution

New tool: `search_tags(search)` - searches both `tag_value` AND `tag_key` (case-insensitive, ranked by match quality).

```
User: "PRS"
  → search_tags("PRS")
  → [{"tag_key": "tenant", "tag_value": "PRS", "device_count": 1}]
  → get_group_telemetry(tag_key="tenant", tag_value="PRS")
```

## Implementation

### Files to Modify

| File | Change |
|------|--------|
| `src/pfn_mcp/tools/group_telemetry.py` | Add `search_tags()` + formatter |
| `src/pfn_mcp/tools.yaml` | Register tool schema |
| `src/pfn_mcp/server.py` | Add call_tool handler |
| `tests/test_phase2_group_telemetry.py` | Add test cases |

### 1. Function: `search_tags()` in `group_telemetry.py`

```python
async def search_tags(
    search: str,
    limit: int = 10,
) -> dict:
    """Search for device tags by value or key."""
```

**SQL Query** (ranked matching):
```sql
SELECT
    dt.tag_key,
    dt.tag_value,
    dt.tag_category,
    COUNT(DISTINCT dt.device_id) as device_count,
    array_agg(DISTINCT d.display_name ORDER BY d.display_name) as devices,
    CASE
        WHEN LOWER(dt.tag_value) = LOWER($1) THEN 0          -- exact value
        WHEN LOWER(dt.tag_value) LIKE LOWER($1) || '%' THEN 1  -- value starts with
        WHEN LOWER(dt.tag_value) LIKE '%' || LOWER($1) || '%' THEN 2  -- value contains
        WHEN LOWER(dt.tag_key) = LOWER($1) THEN 3            -- exact key
        WHEN LOWER(dt.tag_key) LIKE LOWER($1) || '%' THEN 4    -- key starts with
        WHEN LOWER(dt.tag_key) LIKE '%' || LOWER($1) || '%' THEN 5   -- key contains
        ELSE 6
    END as match_rank
FROM device_tags dt
JOIN devices d ON dt.device_id = d.id
WHERE dt.is_active = true AND d.is_active = true
  AND (dt.tag_value ILIKE '%' || $1 || '%' OR dt.tag_key ILIKE '%' || $1 || '%')
GROUP BY dt.tag_key, dt.tag_value, dt.tag_category
ORDER BY match_rank, device_count DESC
LIMIT $2
```

**Response Structure**:
```python
{
    "search_term": "PRS",
    "total_matches": 2,
    "matches": [
        {
            "tag_key": "tenant",
            "tag_value": "PRS",
            "category": "organization",
            "device_count": 1,
            "devices": ["PRS Main Meter"],
            "has_more_devices": False,
            "match_type": "value",       # "value" or "key"
            "match_quality": "exact",    # "exact", "starts_with", "contains"
        },
    ],
}
```

### 2. Formatter: `format_search_tags_response()`

Output format:
```markdown
## Tag Search Results for 'PRS' (2 found)

### tenant=PRS [exact]
**Devices**: 1
**Category**: organization
  - PRS Main Meter

---
**Tip**: Use `get_group_telemetry(tag_key="tenant", tag_value="PRS")` to query this group.
```

### 3. Tool Schema in `tools.yaml`

```yaml
- name: search_tags
  tenant_aware: false
  description: >-
    Search for device tags by value or key.
    Finds tags where tag_value or tag_key matches the search term.
    Use when you don't know which tag_key a value belongs to.
    Returns matching tag key/value pairs ranked by match quality.
  params:
    - name: search
      type: string
      description: "Search term to match against tag_value and tag_key"
      required: true
    - name: limit
      type: integer
      description: "Maximum results to return (default: 10)"
      default: 10
```

### 4. Handler in `server.py`

```python
elif name == "search_tags":
    search = arguments.get("search")
    if not search:
        return [TextContent(type="text", text="Error: search is required")]
    result = await group_telemetry_tool.search_tags(
        search=search,
        limit=arguments.get("limit", 10),
    )
    response = group_telemetry_tool.format_search_tags_response(result)
    return [TextContent(type="text", text=response)]
```

### 5. Tests in `test_phase2_group_telemetry.py`

| Test | Description |
|------|-------------|
| `test_search_tags_by_value` | Exact value match returns correct tag |
| `test_search_tags_by_key` | Key search finds matching tags |
| `test_search_tags_no_results` | Non-existent term returns empty |
| `test_search_tags_partial_match` | Partial value finds matches |
| `test_search_tags_case_insensitive` | Case variations work |
| `test_search_tags_limit` | Limit parameter restricts results |
| `test_search_tags_has_device_info` | Results include device info |

## Execution Sequence

1. Add `search_tags()` and formatter to `group_telemetry.py`
2. Add tool schema to `tools.yaml`
3. Add handler to `server.py`
4. Add tests to `test_phase2_group_telemetry.py`
5. Run `ruff check src/` and `pytest tests/test_phase2_group_telemetry.py -v`
6. Run `/tool-update` to sync Open WebUI wrapper
