# Thin Wrapper Architecture

**Created:** 2026-01-06
**Status:** Active

---

## Overview

The `pfn_tool_wrapper.py` is a thin proxy between Open WebUI and PFN MCP. Its only job: **extract tenant from user context and pass it to MCP tools**.

```
Open WebUI ──→ Thin Wrapper ──→ PFN MCP Server
               (injects tenant)   (resolves tenant)
```

## The Pattern

Each wrapper function is **2-3 lines**:

```python
async def get_electricity_cost(self, period: str = "this_month", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_electricity_cost", {"tenant": tenant, "period": period})

async def list_devices(self, search: str = "", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("list_devices", {"tenant": tenant, "search": search})

async def get_device_telemetry(self, device: str, period: str = "7d", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_device_telemetry", {"tenant": tenant, "device": device, "period": period})
```

## Core Helper

```python
def _get_tenant_code(self, __user__: dict) -> str | None:
    """
    Returns:
        - "PRS" (tenant code) for regular users
        - None for superusers (all tenants)
    """
    ctx = self._get_tenant_context(__user__)
    if ctx.get("is_superuser"):
        return None
    return ctx.get("tenant_code")
```

## Why This Works

1. **Wrapper** extracts `tenant_code` string (or `None` for superuser)
2. **MCP tool** receives `tenant: str | None`
3. **MCP tool** calls `resolve_tenant(tenant)` to get `tenant_id`
4. **Database query** filters by `tenant_id`

The complexity lives in `resolve_tenant()` on the MCP server, not in the wrapper.

## Tool Types

### Tenant-Aware (pass tenant)

```python
async def list_devices(self, search: str = "", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("list_devices", {"tenant": tenant, "search": search})
```

### Global (no tenant needed)

```python
async def list_quantities(self, search: str = "", __user__: dict = None) -> str:
    return await self._call_mcp("list_quantities", {"search": search})
```

## Superuser Handling

Superusers get `tenant = None`, which means no filtering:

| User | `_get_tenant_code()` | MCP receives | Result |
|------|---------------------|--------------|--------|
| Regular (PRS) | `"PRS"` | `tenant="PRS"` | PRS devices only |
| Superuser | `None` | `tenant=None` | All devices |

## Adding New Tools

Use `/tool-update` to sync, or manually add:

```python
# 1. Check if MCP tool has 'tenant' param
# 2. If yes:
async def new_tool(self, param1: str, __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("new_tool", {"tenant": tenant, "param1": param1})

# 3. If no (global tool):
async def new_global_tool(self, param1: str, __user__: dict = None) -> str:
    return await self._call_mcp("new_global_tool", {"param1": param1})
```

## Files

| File | Purpose |
|------|---------|
| `prototype/pfn_tool_wrapper.py` | Thin wrapper |
| `src/pfn_mcp/tools/resolve.py` | `resolve_tenant()` |
| `.claude/commands/tool-update.md` | Sync command |

## Related Docs

- [tenant-code-injection.md](./tenant-code-injection.md) - Full tenant flow
- [tool-modification-tenant-injection.md](./tool-modification-tenant-injection.md) - MCP tool changes
