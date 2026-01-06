"""
title: PFN Energy Tools
description: Tenant-scoped energy monitoring tools powered by PFN MCP
author: PFN Team
version: 0.1.0
license: MIT

This tool provides access to Valkyrie energy monitoring data with automatic
tenant scoping based on the user's Keycloak group membership.

INSTALLATION:
1. Open WebUI Admin → Workspace → Tools → Add Tool
2. Paste this entire file
3. Configure Valves (admin settings) with Keycloak and MCP connection details
4. Save

USAGE:
- "Show my devices" → Lists devices for user's tenant
- "What's the power consumption today?" → Gets consumption data
- "Show electricity cost this month" → Gets cost breakdown
"""

import json
import asyncio
from typing import Optional, Any, Callable
from urllib.request import urlopen, Request
from urllib.parse import urlencode
from pydantic import BaseModel, Field


class Tools:
    """PFN Energy Tools - Tenant-scoped access to Valkyrie energy data."""

    class Valves(BaseModel):
        """Admin configuration (set in Open WebUI Admin Panel)."""
        # Keycloak settings for tenant resolution
        KEYCLOAK_URL: str = Field(
            default="http://keycloak:8080",
            description="Keycloak server URL (use Docker network name in container)"
        )
        KEYCLOAK_REALM: str = Field(
            default="pfn",
            description="Keycloak realm containing users and tenant groups"
        )
        KEYCLOAK_ADMIN_USER: str = Field(
            default="admin",
            description="Keycloak admin username for group lookups"
        )
        KEYCLOAK_ADMIN_PASSWORD: str = Field(
            default="admin",
            description="Keycloak admin password"
        )

        # PFN MCP settings
        MCP_SERVER_URL: str = Field(
            default="http://localhost:8000",
            description="PFN MCP server URL"
        )

    class UserValves(BaseModel):
        """Per-user configuration (optional)."""
        pass

    def __init__(self):
        self.valves = self.Valves()
        self._kc_token: Optional[str] = None
        self._kc_token_expiry: float = 0

    # =========================================================================
    # TENANT RESOLUTION (Core functionality)
    # =========================================================================

    def _get_keycloak_token(self) -> str:
        """Get Keycloak admin token (cached)."""
        import time

        # Return cached token if still valid (with 60s buffer)
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

    def _get_user_groups_from_keycloak(self, oauth_sub: str) -> list[str]:
        """Fetch user groups from Keycloak by oauth_sub (Keycloak user ID)."""
        token = self._get_keycloak_token()
        url = f"{self.valves.KEYCLOAK_URL}/admin/realms/{self.valves.KEYCLOAK_REALM}/users/{oauth_sub}/groups"
        req = Request(url, headers={"Authorization": f"Bearer {token}"})

        with urlopen(req, timeout=10) as resp:
            groups = json.loads(resp.read())
            return [g["name"] for g in groups]

    def _get_tenant_context(self, __user__: dict) -> dict:
        """
        Get tenant context for the current user.

        Uses cached value from user.info if available, otherwise fetches
        from Keycloak and caches for future requests.

        Returns:
            {
                "tenant_code": str or None,
                "groups": list[str],
                "user_id": str,
                "user_email": str,
                "source": "cached" | "keycloak" | "error",
                "error": str or None
            }
        """
        result = {
            "tenant_code": None,
            "groups": [],
            "user_id": __user__.get("id"),
            "user_email": __user__.get("email"),
            "source": None,
            "error": None
        }

        # Try cached value first
        info = __user__.get("info") or {}
        if isinstance(info, str):
            try:
                info = json.loads(info)
            except:
                info = {}

        if info.get("tenant_code"):
            result["tenant_code"] = info["tenant_code"]
            result["groups"] = info.get("keycloak_groups", [])
            result["source"] = "cached"
            return result

        # Fetch from Keycloak
        oauth_sub = __user__.get("oauth_sub")
        if not oauth_sub:
            result["source"] = "error"
            result["error"] = "No oauth_sub in user context - not an OAuth user?"
            return result

        try:
            groups = self._get_user_groups_from_keycloak(oauth_sub)

            if not groups:
                result["source"] = "keycloak"
                result["error"] = "User has no groups in Keycloak"
                return result

            tenant_code = groups[0]  # First group = tenant
            result["tenant_code"] = tenant_code
            result["groups"] = groups
            result["source"] = "keycloak"

            # Cache in user.info for future requests
            try:
                from open_webui.models.users import Users
                new_info = info.copy()
                new_info["tenant_code"] = tenant_code
                new_info["keycloak_groups"] = groups
                Users.update_user_by_id(__user__["id"], {"info": new_info})
            except Exception as cache_err:
                # Non-fatal - continue even if caching fails
                pass

            return result

        except Exception as e:
            result["source"] = "error"
            result["error"] = f"Keycloak error: {str(e)}"
            return result

    def _require_tenant(self, __user__: dict) -> tuple[str, dict]:
        """
        Get tenant_code or raise descriptive error.

        Returns: (tenant_code, full_context)
        Raises: ValueError if tenant cannot be determined
        """
        ctx = self._get_tenant_context(__user__)

        if not ctx["tenant_code"]:
            error_msg = ctx.get("error", "Unknown error")
            raise ValueError(f"Cannot determine tenant: {error_msg}")

        return ctx["tenant_code"], ctx

    # =========================================================================
    # MCP CLIENT (Calls to PFN MCP server)
    # =========================================================================

    async def _call_mcp(self, tool_name: str, params: dict) -> dict:
        """
        Call PFN MCP server tool.

        In production, this would use proper MCP client.
        For prototype, uses HTTP call to SSE server.
        """
        # TODO: Replace with actual MCP client call
        # For now, return mock response
        return {
            "tool": tool_name,
            "params": params,
            "status": "mock_response",
            "note": "Replace with actual MCP client in production"
        }

    # =========================================================================
    # PUBLIC TOOLS (Exposed to LLM)
    # =========================================================================

    async def get_my_tenant(
        self,
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Get the current user's tenant information.

        Shows which tenant (company/site) the user belongs to based on their
        Keycloak group membership.

        :return: Tenant information including tenant code and group memberships
        """
        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        ctx = self._get_tenant_context(__user__)

        return json.dumps({
            "tenant_code": ctx["tenant_code"],
            "groups": ctx["groups"],
            "user_email": ctx["user_email"],
            "source": ctx["source"],
            "error": ctx["error"]
        }, indent=2)

    async def list_devices(
        self,
        search: str = "",
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        List energy monitoring devices for the user's tenant.

        Shows all power meters and monitoring devices available to the user,
        filtered by their tenant access.

        :param search: Optional search term to filter devices by name
        :return: List of devices with their details
        """
        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        try:
            tenant_code, ctx = self._require_tenant(__user__)
        except ValueError as e:
            return json.dumps({"error": str(e)})

        # Call MCP with tenant filter
        result = await self._call_mcp("list_devices", {
            "tenant_code": tenant_code,
            "search": search
        })

        return json.dumps({
            "tenant": tenant_code,
            "search": search or "(all)",
            "result": result
        }, indent=2)

    async def get_consumption(
        self,
        period: str = "today",
        device: str = "",
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Get energy consumption for the user's tenant.

        Shows electricity consumption data for a specified time period.
        Can be filtered to a specific device or show total for all devices.

        :param period: Time period - "today", "yesterday", "7d", "30d", "this_month"
        :param device: Optional device name to filter (empty = all devices)
        :return: Consumption data in kWh with breakdown
        """
        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        try:
            tenant_code, ctx = self._require_tenant(__user__)
        except ValueError as e:
            return json.dumps({"error": str(e)})

        result = await self._call_mcp("get_device_telemetry", {
            "tenant_code": tenant_code,
            "device": device,
            "period": period,
            "quantity": "Active Energy Delivered"
        })

        return json.dumps({
            "tenant": tenant_code,
            "period": period,
            "device": device or "(all)",
            "result": result
        }, indent=2)

    async def get_electricity_cost(
        self,
        period: str = "this_month",
        breakdown: str = "none",
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Get electricity cost for the user's tenant.

        Shows electricity costs with optional breakdown by shift, rate, or device.

        :param period: Time period - "today", "7d", "30d", "this_month", "last_month"
        :param breakdown: Breakdown type - "none", "shift", "rate", "device"
        :return: Cost data in IDR with breakdown if requested
        """
        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        try:
            tenant_code, ctx = self._require_tenant(__user__)
        except ValueError as e:
            return json.dumps({"error": str(e)})

        result = await self._call_mcp("get_electricity_cost", {
            "tenant_code": tenant_code,
            "period": period,
            "breakdown": breakdown
        })

        return json.dumps({
            "tenant": tenant_code,
            "period": period,
            "breakdown": breakdown,
            "result": result
        }, indent=2)

    async def compare_devices(
        self,
        devices: str,
        period: str = "7d",
        metric: str = "consumption",
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Compare multiple devices side by side.

        Shows consumption or cost comparison between specified devices.

        :param devices: Comma-separated device names to compare
        :param period: Time period for comparison
        :param metric: What to compare - "consumption" or "cost"
        :return: Comparison data for the specified devices
        """
        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        try:
            tenant_code, ctx = self._require_tenant(__user__)
        except ValueError as e:
            return json.dumps({"error": str(e)})

        device_list = [d.strip() for d in devices.split(",") if d.strip()]

        if len(device_list) < 2:
            return json.dumps({"error": "Please specify at least 2 devices to compare"})

        result = await self._call_mcp("compare_device_quantities", {
            "tenant_code": tenant_code,
            "devices": device_list,
            "period": period,
            "metric": metric
        })

        return json.dumps({
            "tenant": tenant_code,
            "devices": device_list,
            "period": period,
            "metric": metric,
            "result": result
        }, indent=2)
