---
description: Sync MCP tools with Open WebUI wrapper (pfn_tool_wrapper.py)
---

# Tool Update Command

Synchronize MCP tool definitions with the Open WebUI wrapper to ensure all tools are exposed with proper tenant injection.

## Your Task

1. **Read MCP tool definitions** from `src/pfn_mcp/server.py`
   - Look for tool registrations in `list_tools()` and `call_tool()` handlers
   - Extract: tool name, parameters, description, whether it has `tenant` param

2. **Read current wrapper** from `prototype/pfn_tool_wrapper.py`
   - Find all `async def` methods in the `Tools` class (excluding private `_` methods)
   - Extract: function name, parameters

3. **Compare and categorize**:
   - **Missing**: MCP tool exists but no wrapper
   - **Extra**: Wrapper exists but no MCP tool (may be intentional helper)
   - **Synced**: Both exist

4. **Generate report** in this format:

   ```
   ## Tool Sync Status

   | MCP Tool | Wrapper | Tenant Param | Status |
   |----------|---------|--------------|--------|
   | list_devices | list_devices | Yes | ✅ Synced |
   | get_peak_analysis | - | Yes | ❌ Missing |
   | list_quantities | - | No | ❌ Missing |
   ```

5. **For missing tools**, generate wrapper code following this pattern:

   **If tool HAS `tenant` parameter (tenant-aware):**
   ```python
   async def {tool_name}(
       self,
       {other_params},
       tenant: str = "",
       __user__: dict = None,
       __event_emitter__: Callable[[dict], Any] = None,
   ) -> str:
       """
       {description}

       :param {other_params}: ...
       :param tenant: Optional tenant filter (superusers only)
       :return: {return_description}
       """
       if __user__ is None:
           return json.dumps({"error": "No user context available"})

       try:
           tenant_code, ctx = self._require_tenant(__user__)
       except ValueError as e:
           return json.dumps({"error": str(e)})

       effective_tenant, error = self._resolve_effective_tenant(ctx, tenant)
       if error:
           return json.dumps({"error": error})

       result = await self._call_mcp("{tool_name}", {{
           "tenant": effective_tenant,
           {param_dict}
       }})

       return json.dumps({{
           "tenant": effective_tenant or "ALL",
           "is_superuser": ctx.get("is_superuser", False),
           {response_fields},
           "result": result
       }}, indent=2)
   ```

   **If tool does NOT have `tenant` parameter (global):**
   ```python
   async def {tool_name}(
       self,
       {other_params},
       __user__: dict = None,
       __event_emitter__: Callable[[dict], Any] = None,
   ) -> str:
       """
       {description}

       :param {other_params}: ...
       :return: {return_description}
       """
       result = await self._call_mcp("{tool_name}", {{
           {param_dict}
       }})

       return json.dumps(result, indent=2)
   ```

6. **Ask for confirmation** before applying changes:
   - Show the generated code
   - Ask which tools to add
   - Apply edits to `prototype/pfn_tool_wrapper.py`

## Classification Rules

### Tenant-Aware Tools (inject tenant)
Tools that filter data by tenant. From `docs/tenant-code-injection.md`:
- `list_devices`
- `get_electricity_cost`, `get_electricity_cost_breakdown`, `get_electricity_cost_ranking`
- `compare_electricity_periods`
- `resolve_device`, `get_device_telemetry`, `get_quantity_stats`
- `find_devices_by_quantity`, `check_data_freshness`, `get_tenant_summary`
- `list_tags`, `list_tag_values`, `get_group_telemetry`, `compare_groups`
- `get_peak_analysis`

### Global Tools (no tenant injection)
Tools that return global/reference data:
- `list_tenants`
- `list_quantities`
- `list_device_quantities`, `compare_device_quantities`
- `get_device_data_range`, `get_device_info`

## Files to Read
- `src/pfn_mcp/server.py` - MCP tool definitions
- `prototype/pfn_tool_wrapper.py` - Current wrapper implementation
- `docs/tenant-code-injection.md` - Tenant injection documentation (reference)

## Files to Modify
- `prototype/pfn_tool_wrapper.py` - Add missing wrapper functions

## After Completion
1. Show summary of changes made
2. Remind to test the new wrappers
3. Commit changes if requested
