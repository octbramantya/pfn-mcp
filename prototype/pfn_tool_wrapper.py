"""
title: PFN Energy Tools
description: Tenant-scoped energy monitoring tools powered by PFN MCP
author: PFN Team
version: 0.3.0
license: MIT

Thin wrapper that injects tenant context into MCP tool calls.
See docs/thin-wrapper.md for architecture details.

INSTALLATION:
1. Open WebUI Admin → Workspace → Tools → Add Tool
2. Paste this entire file
3. Configure Valves with Keycloak and MCP connection details
4. Save
"""

import json
from typing import Optional, Any, Callable
from urllib.request import urlopen, Request
from urllib.parse import urlencode
from pydantic import BaseModel, Field


class Tools:
    """PFN Energy Tools - Thin wrapper with tenant injection."""

    class Valves(BaseModel):
        """Admin configuration."""
        KEYCLOAK_URL: str = Field(default="http://keycloak:8080")
        KEYCLOAK_REALM: str = Field(default="pfn")
        KEYCLOAK_ADMIN_USER: str = Field(default="admin")
        KEYCLOAK_ADMIN_PASSWORD: str = Field(default="admin")
        MCP_SERVER_URL: str = Field(default="http://localhost:8000")

    def __init__(self):
        self.valves = self.Valves()
        self._kc_token: Optional[str] = None
        self._kc_token_expiry: float = 0

    # =========================================================================
    # TENANT RESOLUTION
    # =========================================================================

    def _get_keycloak_token(self) -> str:
        """Get Keycloak admin token (cached)."""
        import time
        if self._kc_token and time.time() < self._kc_token_expiry - 60:
            return self._kc_token

        url = f"{self.valves.KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
        data = urlencode({
            "username": self.valves.KEYCLOAK_ADMIN_USER,
            "password": self.valves.KEYCLOAK_ADMIN_PASSWORD,
            "grant_type": "password",
            "client_id": "admin-cli"
        }).encode()

        req = Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            self._kc_token = result["access_token"]
            self._kc_token_expiry = time.time() + result.get("expires_in", 300)
            return self._kc_token

    def _get_user_groups(self, oauth_sub: str) -> list[str]:
        """Fetch user groups from Keycloak."""
        token = self._get_keycloak_token()
        url = f"{self.valves.KEYCLOAK_URL}/admin/realms/{self.valves.KEYCLOAK_REALM}/users/{oauth_sub}/groups"
        req = Request(url, headers={"Authorization": f"Bearer {token}"})
        with urlopen(req, timeout=10) as resp:
            return [g["name"] for g in json.loads(resp.read())]

    def _get_tenant_code(self, __user__: dict) -> str | None:
        """
        Get tenant_code for MCP calls.

        Returns:
            - tenant_code string for regular users
            - None for superusers (all tenants)
        """
        if __user__ is None:
            return None

        # Check cache first
        info = __user__.get("info") or {}
        if isinstance(info, str):
            try:
                info = json.loads(info)
            except:
                info = {}

        if info.get("is_superuser"):
            return None
        if info.get("tenant_code"):
            return info["tenant_code"]

        # Fetch from Keycloak
        oauth = __user__.get("oauth") or {}
        if isinstance(oauth, str):
            try:
                oauth = json.loads(oauth)
            except:
                oauth = {}
        oauth_sub = oauth.get("oidc", {}).get("sub")
        if not oauth_sub:
            return None

        try:
            groups = self._get_user_groups(oauth_sub)
            if "superuser" in groups:
                self._cache_user_info(__user__, None, True, groups)
                return None
            tenant_code = groups[0] if groups else None
            if tenant_code:
                self._cache_user_info(__user__, tenant_code, False, groups)
            return tenant_code
        except:
            return None

    def _cache_user_info(self, __user__: dict, tenant_code: str | None, is_superuser: bool, groups: list):
        """Cache tenant info in user.info."""
        try:
            from open_webui.models.users import Users
            info = __user__.get("info") or {}
            if isinstance(info, str):
                info = json.loads(info) if info else {}
            info["tenant_code"] = tenant_code
            info["is_superuser"] = is_superuser
            info["keycloak_groups"] = groups
            Users.update_user_by_id(__user__["id"], {"info": info})
        except:
            pass

    # =========================================================================
    # MCP CLIENT
    # =========================================================================

    async def _call_mcp(self, tool_name: str, params: dict) -> str:
        """Call MCP tool and return JSON response."""
        # TODO: Replace with actual MCP client
        return json.dumps({
            "tool": tool_name,
            "params": params,
            "status": "mock_response"
        })

    # =========================================================================
    # TENANT-AWARE TOOLS (inject tenant)
    # =========================================================================

    async def list_devices(self, search: str = "", __user__: dict = None) -> str:
        """List energy monitoring devices."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("list_devices", {"tenant": tenant, "search": search})

    async def resolve_device(self, search: str, __user__: dict = None) -> str:
        """Resolve device name to ID with match confidence."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("resolve_device", {"tenant": tenant, "search": search})

    async def get_device_telemetry(self, device: str, quantity: str = "power", period: str = "7d", __user__: dict = None) -> str:
        """Get time-series telemetry data for a device."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_device_telemetry", {"tenant": tenant, "device_name": device, "quantity_search": quantity, "period": period})

    async def get_quantity_stats(self, device_id: int, quantity: str = "", period: str = "30d", __user__: dict = None) -> str:
        """Get data availability stats for a device quantity."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_quantity_stats", {"tenant": tenant, "device_id": device_id, "quantity_search": quantity, "period": period})

    async def find_devices_by_quantity(self, quantity: str, __user__: dict = None) -> str:
        """Find devices that have data for a specific quantity."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("find_devices_by_quantity", {"tenant": tenant, "quantity_search": quantity})

    async def check_data_freshness(self, hours_threshold: int = 24, __user__: dict = None) -> str:
        """Check data freshness for tenant devices."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("check_data_freshness", {"tenant": tenant, "hours_threshold": hours_threshold})

    async def get_tenant_summary(self, __user__: dict = None) -> str:
        """Get comprehensive tenant overview."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_tenant_summary", {"tenant_name": tenant})

    async def get_electricity_cost(self, period: str = "7d", breakdown: str = "none", __user__: dict = None) -> str:
        """Get electricity cost for tenant."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_electricity_cost", {"tenant": tenant, "period": period, "breakdown": breakdown})

    async def get_electricity_cost_breakdown(self, device: str, period: str = "7d", group_by: str = "shift_rate", __user__: dict = None) -> str:
        """Get detailed electricity cost breakdown for a device."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_electricity_cost_breakdown", {"tenant": tenant, "device": device, "period": period, "group_by": group_by})

    async def get_electricity_cost_ranking(self, period: str = "30d", metric: str = "cost", limit: int = 10, __user__: dict = None) -> str:
        """Rank devices by electricity cost within tenant."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_electricity_cost_ranking", {"tenant": tenant, "period": period, "metric": metric, "limit": limit})

    async def compare_electricity_periods(self, period1: str, period2: str, device: str = "", __user__: dict = None) -> str:
        """Compare electricity costs between two periods."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("compare_electricity_periods", {"tenant": tenant, "device": device, "period1": period1, "period2": period2})

    async def list_tags(self, tag_key: str = "", __user__: dict = None) -> str:
        """List available device tags for grouping."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("list_tags", {"tenant": tenant, "tag_key": tag_key})

    async def list_tag_values(self, tag_key: str, __user__: dict = None) -> str:
        """List values for a tag key with device counts."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("list_tag_values", {"tenant": tenant, "tag_key": tag_key})

    async def get_group_telemetry(self, tag_key: str, tag_value: str, period: str = "7d", breakdown: str = "none", __user__: dict = None) -> str:
        """Get aggregated telemetry for a device group."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_group_telemetry", {"tenant": tenant, "tag_key": tag_key, "tag_value": tag_value, "period": period, "breakdown": breakdown})

    async def compare_groups(self, groups: str, period: str = "7d", __user__: dict = None) -> str:
        """Compare consumption across groups. Format: 'key1:value1,key2:value2'"""
        tenant = self._get_tenant_code(__user__)
        group_list = [{"tag_key": g.split(":")[0], "tag_value": g.split(":")[1]} for g in groups.split(",") if ":" in g]
        return await self._call_mcp("compare_groups", {"tenant": tenant, "groups": group_list, "period": period})

    async def get_peak_analysis(self, quantity: str = "power", period: str = "7d", top_n: int = 10, __user__: dict = None) -> str:
        """Find peak values with timestamps for tenant devices."""
        tenant = self._get_tenant_code(__user__)
        return await self._call_mcp("get_peak_analysis", {"tenant": tenant, "quantity_search": quantity, "period": period, "top_n": top_n})

    # =========================================================================
    # GLOBAL TOOLS (no tenant injection)
    # =========================================================================

    async def list_tenants(self, __user__: dict = None) -> str:
        """List all tenants."""
        return await self._call_mcp("list_tenants", {})

    async def list_quantities(self, search: str = "", category: str = "", __user__: dict = None) -> str:
        """List available measurement quantities."""
        return await self._call_mcp("list_quantities", {"search": search, "category": category})

    async def list_device_quantities(self, device: str, search: str = "", __user__: dict = None) -> str:
        """List quantities available for a device."""
        return await self._call_mcp("list_device_quantities", {"device_name": device, "search": search})

    async def compare_device_quantities(self, devices: str, search: str = "", __user__: dict = None) -> str:
        """Compare quantities across devices. Comma-separated names."""
        device_list = [d.strip() for d in devices.split(",") if d.strip()]
        return await self._call_mcp("compare_device_quantities", {"device_names": device_list, "search": search})

    async def get_device_data_range(self, device: str, __user__: dict = None) -> str:
        """Get time range of available data for a device."""
        return await self._call_mcp("get_device_data_range", {"device_name": device})

    async def get_device_info(self, device: str, __user__: dict = None) -> str:
        """Get detailed device information including metadata."""
        return await self._call_mcp("get_device_info", {"device_name": device})

    # =========================================================================
    # HELPER TOOL
    # =========================================================================

    async def get_my_tenant(self, __user__: dict = None) -> str:
        """Get current user's tenant information."""
        if __user__ is None:
            return json.dumps({"error": "No user context"})

        tenant = self._get_tenant_code(__user__)
        info = __user__.get("info") or {}
        if isinstance(info, str):
            try:
                info = json.loads(info)
            except:
                info = {}

        return json.dumps({
            "tenant_code": tenant,
            "is_superuser": info.get("is_superuser", False),
            "access": "all tenants" if info.get("is_superuser") else tenant,
            "groups": info.get("keycloak_groups", [])
        }, indent=2)
