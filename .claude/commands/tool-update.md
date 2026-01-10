---
description: Sync MCP tools with Open WebUI wrapper (pfn_tool_wrapper.py)
---

# Tool Update Command

Synchronize MCP tool definitions with the Open WebUI wrapper. Each wrapper function should be **2-3 lines** following the thin wrapper pattern.

**Reference:** `docs/thin-wrapper.md`

## Your Task

1. **Read MCP tool definitions** from `src/pfn_mcp/tools.yaml`
   - This YAML file is the source of truth for all tool schemas
   - Each tool has: `name`, `description`, `tenant_aware`, `params`
   - `tenant_aware: true` = wrapper injects tenant from user context

2. **Read current wrapper** from `prototype/pfn_tool_wrapper.py`
   - Find all `async def` methods in the `Tools` class (excluding private `_` methods)

3. **Compare and report**:

   ```
   ## Tool Sync Status

   | MCP Tool | Wrapper | Tenant | Status |
   |----------|---------|--------|--------|
   | list_devices | list_devices | Yes | synced |
   | get_peak_analysis | - | Yes | missing |
   | list_quantities | - | No | missing |
   ```

4. **Generate wrapper code** using the thin wrapper pattern:

   **Tenant-aware tool (`tenant_aware: true` in YAML):**
   ```python
   async def {tool_name}(self, {params}, __user__: dict = None) -> str:
       tenant = self._get_tenant_code(__user__)
       return await self._call_mcp("{tool_name}", {"tenant": tenant, {param_dict}}, __user__)
   ```

   **Global tool (`tenant_aware: false` in YAML):**
   ```python
   async def {tool_name}(self, {params}, __user__: dict = None) -> str:
       return await self._call_mcp("{tool_name}", {{param_dict}}, __user__)
   ```

   > **Note:** Always pass `__user__` to `_call_mcp` for logging purposes.

5. **Ask for confirmation** before applying changes

## Examples

**Tenant-aware:**
```python
async def get_electricity_cost(self, period: str = "this_month", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_electricity_cost", {"tenant": tenant, "period": period}, __user__)

async def list_devices(self, search: str = "", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("list_devices", {"tenant": tenant, "search": search}, __user__)

async def get_peak_analysis(self, device: str = "", period: str = "7d", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_peak_analysis", {"tenant": tenant, "device": device, "period": period}, __user__)
```

**Global:**
```python
async def list_quantities(self, search: str = "", __user__: dict = None) -> str:
    return await self._call_mcp("list_quantities", {"search": search}, __user__)

async def list_tenants(self, __user__: dict = None) -> str:
    return await self._call_mcp("list_tenants", {}, __user__)
```

## Files

| File | Purpose |
|------|---------|
| `src/pfn_mcp/tools.yaml` | Tool definitions - source of truth (read) |
| `prototype/pfn_tool_wrapper.py` | Wrapper to update (read/write) |
| `docs/thin-wrapper.md` | Pattern reference |
| `docs/tenant-code-injection.md` | Tenant flow reference |

## YAML Schema Reference

```yaml
tools:
  - name: list_devices
    tenant_aware: true
    description: Search for devices by name...
    params:
      - name: search
        type: string
        description: Search term
      - name: tenant
        type: string
        description: Tenant filter
      - name: limit
        type: integer
        default: 20
```

## After Completion

1. Show summary of changes
2. Commit if requested
