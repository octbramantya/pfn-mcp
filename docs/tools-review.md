# PFN MCP Tools Review

## Tenant-Aware Tools Matrix

This document tracks tenant_aware flag consistency across all tools.

| Tool | tenant_aware | Has tenant param | Status |
|------|-------------|------------------|--------|
| list_tenants | false | No | OK |
| list_devices | true | Yes | OK |
| list_quantities | false | No | OK |
| list_device_quantities | false | No | OK |
| compare_device_quantities | false | No | OK |
| get_device_data_range | false | No | OK |
| find_devices_by_quantity | true | Yes | OK |
| get_device_info | false | Yes (optional) | OK |
| check_data_freshness | true | Yes | OK |
| get_tenant_summary | true | No (uses tenant_id/name) | OK - Special case |
| resolve_device | true | Yes | OK |
| get_device_telemetry | true | Yes | OK - Fixed 2025-01 |
| get_quantity_stats | true | Yes | OK - Fixed 2025-01 |
| get_energy_consumption | true | Yes | OK - Fixed 2025-01 |
| get_electricity_cost | true | Yes | OK |
| get_electricity_cost_ranking | true | Yes | OK |
| compare_electricity_periods | true | Yes | OK |
| list_tags | true | Yes | OK - Fixed 2025-01 |
| list_tag_values | true | Yes | OK - Fixed 2025-01 |
| search_tags | false | No | OK |
| get_group_telemetry | true | Yes | OK - Fixed 2025-01 |
| compare_groups | true | Yes | OK - Fixed 2025-01 |
| get_peak_analysis | true | Yes | OK - Fixed 2025-01 |

## Design Decisions

### Tenant Parameter Behavior

- **Optional parameter**: `tenant: str | None = None`
- **None = superuser mode**: No filtering, access to all devices
- **With tenant**: Filters results to devices belonging to that tenant

### Resolution Pattern

All tenant-aware tools follow this pattern:

```python
async def tool_function(
    tenant: str | None = None,
    # ... other params
) -> dict:
    # 1. Resolve tenant first
    tenant_id = None
    if tenant:
        tenant_id, _, error = await resolve_tenant(tenant)
        if error:
            return {"error": error}

    # 2. Pass tenant_id to device/group resolvers
    device_id, info, error = await _resolve_device_id(
        device_id, device_name, tenant_id
    )
```

### Tag and Group Filtering

- **Tag queries**: Filter by devices in tenant
- **Group aggregations**: Only include devices accessible to tenant
- **Asset hierarchy**: Filtered to devices within tenant

## Shared Resolvers

Located in `src/pfn_mcp/tools/resolve.py`:

### resolve_tenant()

```python
async def resolve_tenant(
    tenant: str | None,
) -> tuple[int | None, dict | None, str | None]:
```

- Fuzzy match on tenant_name or tenant_code
- Priority: exact code > exact name > starts-with > contains
- Returns `(None, None, None)` for None input (superuser mode)

### resolve_device()

```python
async def resolve_device(
    device_id: int | None = None,
    device_name: str | None = None,
    tenant_id: int | None = None,
) -> tuple[int | None, dict | None, str | None]:
```

- Unified device resolution with tenant filtering
- By ID: exact lookup, validates tenant access
- By name: fuzzy search within tenant scope

## Files Modified (2025-01 Tenant Fix)

1. `tools.yaml` - Added tenant param to 8 tools
2. `server.py` - Pass tenant to tool implementations
3. `resolve.py` - Added unified `resolve_device()`
4. `telemetry.py` - Updated `_resolve_device_id()`, `get_device_telemetry()`,
   `get_quantity_stats()`
5. `energy_consumption.py` - Updated `get_energy_consumption()`
6. `group_telemetry.py` - Updated `list_tags()`, `list_tag_values()`,
   `get_group_telemetry()`, `compare_groups()`, helper functions
7. `peak_analysis.py` - Updated `get_peak_analysis()`

## Known Issues

### check_data_freshness Timeout

The `check_data_freshness` query can timeout on large datasets. This is a
pre-existing performance issue unrelated to tenant filtering.

## Completed Refactoring

### Quantity Alias Consolidation (2025-01)

Extracted `expand_quantity_aliases()` helper to `quantities.py` and updated 6 locations:
- `quantities.py` (list_quantities)
- `telemetry.py` (_resolve_quantity_id)
- `discovery.py` (get_device_data_range, find_devices_by_quantity)
- `device_quantities.py` (list_device_quantities, compare_device_quantities)

```python
def expand_quantity_aliases(search: str) -> list[str]:
    """Expand semantic search term to quantity code patterns."""
```
