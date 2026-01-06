# Tool Modification: Tenant String Injection Support

This document describes the changes made to support tenant string injection from the frontend (Open WebUI + Keycloak).

## Background

The frontend team implemented a Keycloak-based tenant injection approach where:
- Users belong to Keycloak groups that map to tenant codes (e.g., `PRS`, `COBA`)
- Open WebUI passes `tenant_code: str` to MCP tools via the `{user.extra.tenant}` template
- See `docs/tenant-code-injection.md` for the full frontend implementation

## Problem

4 MCP tools expected `tenant_id: int` but the frontend sends `tenant_code: str`:

| Tool | Before | After |
|------|--------|-------|
| `list_devices` | `tenant_id: int` | `tenant: str` |
| `find_devices_by_quantity` | `tenant_id: int` | `tenant: str` |
| `check_data_freshness` | `tenant_id: int` | `tenant: str` |
| `resolve_device` | `tenant_id: int` | `tenant: str` |

## Solution

### 1. Shared Resolution Utility

Created `src/pfn_mcp/tools/resolve.py` with `resolve_tenant()` function:

```python
async def resolve_tenant(
    tenant: str | None,
) -> tuple[int | None, dict | None, str | None]:
    """
    Resolve tenant name or code to tenant ID using fuzzy match.
    Returns: (tenant_id, tenant_info_dict, error_message)
    """
```

**Resolution priority**:
1. Exact `tenant_code` match (e.g., "PRS")
2. Exact `tenant_name` match (e.g., "PT Restu Sejahtera")
3. `tenant_name` starts with input
4. Contains match (partial)

### 2. Superuser Handling

Per the frontend implementation, `superuser` group membership grants access to ALL tenants:

```
Regular User:                    Superuser:
┌─────────────────────────┐      ┌─────────────────────────┐
│ groups: ["PRS"]         │      │ groups: ["superuser"]   │
│ → tenant = "PRS"        │      │ → tenant = None         │
│ → sees PRS only         │      │ → sees ALL tenants      │
└─────────────────────────┘      └─────────────────────────┘
```

**Behavior**:
- `tenant: str | None = None` parameter
- `resolve_tenant(None)` returns `(None, None, None)` → no tenant filter applied
- Tests run as superuser (no tenant parameter passed)

### 3. Updated Tools

All 4 tools now:
1. Accept `tenant: str | None` instead of `tenant_id: int | None`
2. Use `resolve_tenant()` to convert string → tenant_id
3. Handle errors gracefully (return empty results or error dict)

## Files Modified

| File | Changes |
|------|---------|
| `src/pfn_mcp/tools/resolve.py` | **NEW** - Shared tenant resolution utility |
| `src/pfn_mcp/tools/devices.py` | `tenant_id: int` → `tenant: str` |
| `src/pfn_mcp/tools/telemetry.py` | `tenant_id: int` → `tenant: str` |
| `src/pfn_mcp/tools/discovery.py` | `tenant_id: int` → `tenant: str` (2 functions) |
| `src/pfn_mcp/tools/electricity_cost.py` | Import from shared `resolve.py` |
| `src/pfn_mcp/server.py` | Updated tool schemas and handlers |
| `tests/test_resolve_tenant.py` | **NEW** - Tests for resolve_tenant() |

## API Changes

### list_devices

```json
// Before
{"tenant_id": 1}

// After
{"tenant": "PRS"}
```

### find_devices_by_quantity

```json
// Before
{"quantity_search": "power", "tenant_id": 1}

// After
{"quantity_search": "power", "tenant": "PRS"}
```

### check_data_freshness

```json
// Before
{"tenant_id": 1}

// After
{"tenant": "PRS"}
```

### resolve_device

```json
// Before
{"search": "Panel Utama", "tenant_id": 1}

// After
{"search": "Panel Utama", "tenant": "PRS"}
```

## Testing

The test suite runs as superuser (no tenant parameter passed). New tests added in `tests/test_resolve_tenant.py`:

- `test_resolve_tenant_by_code` - Resolve by exact tenant code
- `test_resolve_tenant_by_name` - Resolve by tenant name
- `test_resolve_tenant_none_returns_none` - Superuser mode
- `test_resolve_tenant_empty_string_returns_none` - Empty string = superuser
- `test_resolve_tenant_not_found` - Error handling
- `test_resolve_tenant_case_insensitive` - Case-insensitive matching

## Related Documentation

- `docs/tenant-code-injection.md` - Frontend implementation details
- `docs/WEB_UI_PLAN.md` - Open WebUI integration plan
