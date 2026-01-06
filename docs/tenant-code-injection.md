# Tenant Code Injection: MCP Tool Integration Guide

**Created:** 2026-01-06
**Status:** Active
**Audience:** MCP Tool Developers

---

## Overview

When users interact with the PFN MCP tools via Open WebUI, their tenant context is automatically available through dependency injection. This document explains how tenant isolation works and how to properly implement it in MCP tools.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Open WebUI                                 │
│  ┌──────────────┐    ┌─────────────────────────────────────────┐    │
│  │ User Request │───→│  Python Tool (pfn_tool_wrapper.py)      │    │
│  │ "Show my     │    │                                         │    │
│  │  devices"    │    │  __user__ = {                           │    │
│  └──────────────┘    │    "id": "abc-123",                     │    │
│                      │    "email": "user@company.com",         │    │
│                      │    "info": {                            │    │
│                      │      "tenant_code": "PRS",  ← INJECTED  │    │
│                      │      "keycloak_groups": ["PRS"]         │    │
│                      │    }                                    │    │
│                      │  }                                      │    │
│                      └──────────────────┬──────────────────────┘    │
└─────────────────────────────────────────┼───────────────────────────┘
                                          │
                                          │ tenant_code passed to MCP
                                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         PFN MCP Server                               │
│  list_devices(tenant_id=1)  ← resolved from tenant_code             │
│  WHERE d.tenant_id = 1      ← query filtered                        │
└─────────────────────────────────────────────────────────────────────┘
```

## How Tenant Code Gets Injected

### 1. User Authentication (Keycloak)

User logs in via Keycloak OAuth. Their Keycloak groups determine tenant membership:

```
Keycloak Groups:
  - PRS     → tenant_code = "PRS" (first group = primary tenant)
  - Operators → additional role
```

### 2. First Tool Call (Cache Miss)

On the first tool invocation, the wrapper fetches groups from Keycloak:

```python
# In pfn_tool_wrapper.py
def _get_tenant_context(self, __user__: dict) -> dict:
    # 1. Check cache first
    info = __user__.get("info") or {}
    if info.get("tenant_code"):
        return {"tenant_code": info["tenant_code"], "source": "cached"}

    # 2. Cache miss - fetch from Keycloak Admin API
    oauth_sub = __user__["oauth"]["oidc"]["sub"]  # Keycloak user ID
    groups = self._get_user_groups_from_keycloak(oauth_sub)
    tenant_code = groups[0]  # First group = tenant

    # 3. Cache for future requests
    Users.update_user_by_id(__user__["id"], {
        "info": {"tenant_code": tenant_code, "keycloak_groups": groups}
    })

    return {"tenant_code": tenant_code, "source": "keycloak"}
```

### 3. Subsequent Tool Calls (Cache Hit)

Open WebUI injects the cached `tenant_code` in `__user__["info"]`:

```python
# __user__ dict on every tool call
{
    "id": "user-uuid",
    "email": "user@prs.com",
    "info": {
        "tenant_code": "PRS",           # ← Available immediately
        "keycloak_groups": ["PRS", "Operators"]
    },
    "oauth": {"oidc": {"sub": "keycloak-user-id"}}
}
```

## Superuser Handling

Internal admins (superusers) require access to all tenants without being assigned to each one individually.

### Design Principle

**`superuser` group membership alone grants access to ALL tenants.** No additional tenant group memberships required.

```
Regular User:                    Superuser:
┌─────────────────────────┐      ┌─────────────────────────┐
│ groups: ["PRS"]         │      │ groups: ["superuser"]   │
│                         │      │                         │
│ → tenant_code = "PRS"   │      │ → tenant_code = None    │
│ → sees PRS only         │      │ → sees ALL tenants      │
└─────────────────────────┘      └─────────────────────────┘
```

### Keycloak Configuration

Create a `superuser` group in Keycloak for internal admins:

```
Keycloak Groups:
  - superuser     ← Internal admins (all-tenant access)
  - PRS           ← Tenant: PT Rekayasa Sukses
  - IOP           ← Tenant: PT Indo Optic Prima
  - NAV           ← Tenant: Navigant Energy
```

### Wrapper Implementation

Update `_get_tenant_context()` to detect superusers:

```python
def _get_tenant_context(self, __user__: dict) -> dict:
    groups = self._get_user_groups(__user__)

    # Check for superuser - grants access to all tenants
    if "superuser" in groups:
        return {
            "tenant_code": None,      # None = no filtering = all tenants
            "is_superuser": True,
            "groups": groups,
            "source": "superuser"
        }

    # Regular user - must have a tenant group
    if not groups:
        return {
            "tenant_code": None,
            "is_superuser": False,
            "error": "User has no tenant assigned"
        }

    return {
        "tenant_code": groups[0],     # First group = primary tenant
        "is_superuser": False,
        "groups": groups,
        "source": "cached" if from_cache else "keycloak"
    }
```

### MCP Tool Behavior

Tools must handle `tenant_id=None` to return all tenants:

```python
async def list_devices(
    search: str | None = None,
    tenant_id: int | None = None,  # None = all tenants (superuser)
    limit: int = 20,
) -> list[dict]:
    conditions = ["d.is_active = true"]
    params = []

    # Only filter if tenant_id is provided
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${len(params) + 1}")
        params.append(tenant_id)
    # else: no tenant filter → returns all tenants

    # ... rest of query
```

### Response Format for Superusers

When superuser queries without tenant filter, include tenant context in results:

```json
{
  "devices": [
    {"id": 1, "name": "Meter 1", "tenant_name": "PT Rekayasa Sukses", "tenant_code": "PRS"},
    {"id": 2, "name": "Meter 2", "tenant_name": "PT Rekayasa Sukses", "tenant_code": "PRS"},
    {"id": 3, "name": "Meter A", "tenant_name": "PT Indo Optic Prima", "tenant_code": "IOP"}
  ],
  "summary": {
    "total": 3,
    "by_tenant": {
      "PRS": 2,
      "IOP": 1
    }
  }
}
```

### Superuser with Tenant Override

Superusers can optionally filter to a specific tenant:

```python
async def list_devices(
    self,
    search: str = "",
    tenant: str = "",  # Optional: superuser can specify tenant
    __user__: dict = None,
) -> str:
    ctx = self._get_tenant_context(__user__)

    if tenant:
        # Explicit tenant requested
        if not ctx["is_superuser"]:
            # Regular user can only access their own tenant
            if tenant != ctx["tenant_code"]:
                return {"error": f"Access denied to tenant: {tenant}"}
        effective_tenant = tenant
    else:
        # Use default: None for superuser, their tenant for regular user
        effective_tenant = ctx["tenant_code"]

    result = await self._call_mcp("list_devices", {
        "tenant_code": effective_tenant,
        "search": search
    })
```

### Security: Superuser Audit Trail

Always log superuser access for security audits:

```python
if ctx["is_superuser"]:
    logger.info(
        "Superuser access",
        extra={
            "user_email": __user__["email"],
            "tool": "list_devices",
            "tenant_filter": effective_tenant or "ALL",
            "params": {"search": search}
        }
    )
```

## Implementing Tenant-Aware MCP Tools

### Pattern: Wrapper Tool (Recommended)

The wrapper in Open WebUI resolves tenant before calling MCP:

```python
# Open WebUI Python Tool (pfn_tool_wrapper.py)
class Tools:
    async def list_devices(
        self,
        search: str = "",
        __user__: dict = None,  # Auto-injected by Open WebUI
    ) -> str:
        # 1. Extract tenant (uses cache or fetches from Keycloak)
        tenant_code, ctx = self._require_tenant(__user__)

        # 2. Call MCP with tenant context
        result = await self._call_mcp("list_devices", {
            "tenant_code": tenant_code,
            "search": search
        })
        return json.dumps(result)
```

### Pattern: MCP Tool Implementation

MCP tools should accept `tenant_id` or `tenant_code` for filtering:

```python
# src/pfn_mcp/tools/devices.py
async def list_devices(
    search: str | None = None,
    tenant_id: int | None = None,  # ← Accept tenant filter
    limit: int = 20,
) -> list[dict]:
    conditions = ["d.is_active = true"]
    params = []

    # Apply tenant filter when provided
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${len(params) + 1}")
        params.append(tenant_id)

    # ... rest of query
```

### Resolving tenant_code to tenant_id

Use fuzzy matching to resolve tenant names/codes to IDs:

```python
# src/pfn_mcp/tools/electricity_cost.py
async def _resolve_tenant(tenant: str | None) -> tuple[int | None, dict | None, str | None]:
    """Resolve tenant name/code to tenant_id."""
    if not tenant:
        return None, None, None

    tenant_row = await db.fetch_one(
        """
        SELECT id, tenant_name, tenant_code
        FROM tenants
        WHERE is_active = true
          AND (tenant_name ILIKE $1 OR tenant_code ILIKE $1)
        ORDER BY
            CASE
                WHEN LOWER(tenant_name) = LOWER($2) THEN 0
                WHEN LOWER(tenant_code) = LOWER($2) THEN 0
                WHEN LOWER(tenant_name) LIKE LOWER($2) || '%' THEN 1
                ELSE 2
            END
        LIMIT 1
        """,
        f"%{tenant}%",
        tenant,
    )

    if not tenant_row:
        return None, None, f"Tenant not found: {tenant}"

    return tenant_row["id"], dict(tenant_row), None
```

## Tool Classification: Tenant Usage

### Tools That MUST Use Tenant Filtering

These tools return user-specific data and must be scoped:

| Tool | Parameter | Reason |
|------|-----------|--------|
| `list_devices` | `tenant_id` | Only show user's devices |
| `get_electricity_cost` | `tenant` | User's cost data only |
| `get_electricity_cost_ranking` | `tenant` | Rank within user's tenant |
| `resolve_device` | `tenant_id` | Find device in user's scope |
| `check_data_freshness` | `tenant_id` | User's device health |
| `get_tenant_summary` | `tenant_id` | User's tenant overview |
| `get_group_telemetry` | (implicit) | Tags/assets are tenant-scoped |

### Tools That MAY Use Tenant Filtering

Optional filtering for narrowing results:

| Tool | Parameter | Behavior |
|------|-----------|----------|
| `find_devices_by_quantity` | `tenant_id` | All tenants if omitted |

### Tools That SHOULD NOT Use Tenant Filtering

Global reference data, same for all users:

| Tool | Reason |
|------|--------|
| `list_tenants` | Admin function, lists all tenants |
| `list_quantities` | Quantities are global definitions |
| `get_device_info` | Device ID already implies tenant |
| `get_device_data_range` | Device ID already implies tenant |

## Implementation Checklist

When creating a new MCP tool:

```
[ ] 1. Determine if tool needs tenant filtering (see classification above)
[ ] 2. Add tenant_id or tenant parameter to function signature
[ ] 3. Add tenant filter to SQL WHERE clause
[ ] 4. Document the parameter in docstring
[ ] 5. Update wrapper tool to pass tenant_code
[ ] 6. Test with multiple tenants to verify isolation
```

### Example: Adding Tenant Support to a New Tool

```python
# src/pfn_mcp/tools/new_tool.py

async def get_device_alerts(
    device_name: str | None = None,
    tenant_id: int | None = None,  # Step 2: Add parameter
    limit: int = 50,
) -> dict:
    """
    Get active alerts for devices.

    Args:
        device_name: Filter by device name (optional)
        tenant_id: Filter by tenant ID (required for user context)  # Step 4
        limit: Maximum results

    Returns:
        Dictionary with alerts list
    """
    conditions = ["a.is_active = true"]
    params = []
    param_idx = 1

    # Step 3: Add tenant filter
    if tenant_id is not None:
        conditions.append(f"d.tenant_id = ${param_idx}")
        params.append(tenant_id)
        param_idx += 1

    # ... rest of implementation
```

## Security Considerations

### Always Filter Server-Side

Never trust the client to filter results. Apply tenant filtering in the MCP tool:

```python
# GOOD: Server-side filtering
async def list_devices(tenant_id: int):
    return await db.fetch_all(
        "SELECT * FROM devices WHERE tenant_id = $1",
        tenant_id
    )

# BAD: Returning all data and expecting client to filter
async def list_devices():
    return await db.fetch_all("SELECT * FROM devices")
```

### Validate Tenant Access

For sensitive operations, consider validating the user has access:

```python
async def delete_device(device_id: int, tenant_id: int):
    # Verify device belongs to tenant before deletion
    device = await db.fetch_one(
        "SELECT tenant_id FROM devices WHERE id = $1",
        device_id
    )
    if device["tenant_id"] != tenant_id:
        raise PermissionError("Device does not belong to your tenant")

    # Proceed with deletion
```

### Audit Logging

Log tenant context for security audits:

```python
logger.info(
    "Tool executed",
    extra={
        "tool": "list_devices",
        "tenant_id": tenant_id,
        "user_email": user_email,
        "params": {"search": search}
    }
)
```

## Testing Multi-Tenant Isolation

### Unit Test Pattern

```python
import pytest

@pytest.mark.asyncio
async def test_list_devices_tenant_isolation():
    # Create devices for two tenants
    device_prs = await create_device(tenant_id=1, name="PRS Meter 1")
    device_iop = await create_device(tenant_id=2, name="IOP Meter 1")

    # Query as tenant 1
    results = await list_devices(tenant_id=1)

    # Should only see tenant 1 devices
    assert len(results) == 1
    assert results[0]["name"] == "PRS Meter 1"

    # Should NOT see tenant 2 devices
    assert not any(d["name"] == "IOP Meter 1" for d in results)
```

## Mapping Reference

### Keycloak Group → tenant_code → tenant_id

| Keycloak Group | tenant_code | tenant_id | tenant_name | Notes |
|----------------|-------------|-----------|-------------|-------|
| `superuser` | `None` | `None` | (all tenants) | Internal admins |
| PRS | PRS | 1 | PT Rekayasa Sukses | |
| IOP | IOP | 2 | PT Indo Optic Prima | |
| NAV | NAV | 3 | Navigant Energy | |

The mapping is maintained via:
1. Keycloak groups (source of truth for user membership)
2. `tenants` table in Valkyrie database (tenant_code column)
3. `superuser` group is special - grants all-tenant access without database mapping

## Related Documentation

- [WEB_UI_PLAN.md](./WEB_UI_PLAN.md) - Overall architecture for Option B
- [prototype/README.md](../prototype/README.md) - Prototype implementation details
- [prototype/pfn_tool_wrapper.py](../prototype/pfn_tool_wrapper.py) - Reference wrapper implementation

## Changelog

| Date | Change |
|------|--------|
| 2026-01-06 | Add superuser handling section |
| 2026-01-06 | Initial documentation |
