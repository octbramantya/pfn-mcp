---
description: Sync MCP tools with Open WebUI wrapper (pfn_tool_wrapper.py)
---

# Tool Update Command

Synchronize MCP tool definitions with the Open WebUI wrapper. Each wrapper function should be **2-3 lines** following the thin wrapper pattern.

**Reference:** `docs/thin-wrapper.md`

## Your Task

1. **Read MCP tool definitions** from `src/pfn_mcp/server.py`
   - Look for tool registrations in `list_tools()` and `call_tool()` handlers
   - Extract: tool name, parameters, whether it has `tenant` param

2. **Read current wrapper** from `prototype/pfn_tool_wrapper.py`
   - Find all `async def` methods in the `Tools` class (excluding private `_` methods)

3. **Compare and report**:

   ```
   ## Tool Sync Status

   | MCP Tool | Wrapper | Tenant | Status |
   |----------|---------|--------|--------|
   | list_devices | list_devices | Yes | ✅ Synced |
   | get_peak_analysis | - | Yes | ❌ Missing |
   | list_quantities | - | No | ❌ Missing |
   ```

4. **Generate wrapper code** using the thin wrapper pattern:

   **Tenant-aware tool (has `tenant` param):**
   ```python
   async def {tool_name}(self, {params}, __user__: dict = None) -> str:
       tenant = self._get_tenant_code(__user__)
       return await self._call_mcp("{tool_name}", {"tenant": tenant, {param_dict}})
   ```

   **Global tool (no `tenant` param):**
   ```python
   async def {tool_name}(self, {params}, __user__: dict = None) -> str:
       return await self._call_mcp("{tool_name}", {{param_dict}})
   ```

5. **Ask for confirmation** before applying changes

## Examples

**Tenant-aware:**
```python
async def get_electricity_cost(self, period: str = "this_month", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_electricity_cost", {"tenant": tenant, "period": period})

async def list_devices(self, search: str = "", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("list_devices", {"tenant": tenant, "search": search})

async def get_peak_analysis(self, device: str = "", period: str = "7d", __user__: dict = None) -> str:
    tenant = self._get_tenant_code(__user__)
    return await self._call_mcp("get_peak_analysis", {"tenant": tenant, "device": device, "period": period})
```

**Global:**
```python
async def list_quantities(self, search: str = "", __user__: dict = None) -> str:
    return await self._call_mcp("list_quantities", {"search": search})

async def list_tenants(self, __user__: dict = None) -> str:
    return await self._call_mcp("list_tenants", {})
```

## Tool Classification

### Tenant-Aware (inject tenant)
- `list_devices`
- `get_electricity_cost`, `get_electricity_cost_breakdown`, `get_electricity_cost_ranking`
- `compare_electricity_periods`
- `resolve_device`, `get_device_telemetry`, `get_quantity_stats`
- `find_devices_by_quantity`, `check_data_freshness`, `get_tenant_summary`
- `list_tags`, `list_tag_values`, `get_group_telemetry`, `compare_groups`
- `get_peak_analysis`

### Global (no tenant)
- `list_tenants`
- `list_quantities`
- `list_device_quantities`, `compare_device_quantities`
- `get_device_data_range`, `get_device_info`

## Files

| File | Purpose |
|------|---------|
| `src/pfn_mcp/server.py` | MCP tool definitions (read) |
| `prototype/pfn_tool_wrapper.py` | Wrapper to update (read/write) |
| `docs/thin-wrapper.md` | Pattern reference |
| `docs/tenant-code-injection.md` | Tenant flow reference |

## After Completion

1. Show summary of changes
2. Commit if requested
