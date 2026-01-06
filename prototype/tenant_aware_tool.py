"""
title: Tenant-Aware Tool Example
description: Tool that auto-fetches tenant from Keycloak on first use
author: PFN Team
version: 0.1.0
"""

import json
from urllib.request import urlopen, Request
from urllib.parse import urlencode


class Tools:
    class Valves:
        """Admin configuration"""
        KEYCLOAK_URL: str = "http://keycloak:8080"
        KEYCLOAK_REALM: str = "pfn"
        KEYCLOAK_ADMIN_USER: str = "admin"
        KEYCLOAK_ADMIN_PASSWORD: str = "admin"

    def __init__(self):
        self.valves = self.Valves()

    def _get_keycloak_token(self) -> str:
        """Get Keycloak admin token."""
        url = f"{self.valves.KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
        data = urlencode({
            "username": self.valves.KEYCLOAK_ADMIN_USER,
            "password": self.valves.KEYCLOAK_ADMIN_PASSWORD,
            "grant_type": "password",
            "client_id": "admin-cli"
        }).encode()
        req = Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())["access_token"]

    def _get_user_groups(self, token: str, kc_user_id: str) -> list:
        """Get user groups from Keycloak."""
        url = f"{self.valves.KEYCLOAK_URL}/admin/realms/{self.valves.KEYCLOAK_REALM}/users/{kc_user_id}/groups"
        req = Request(url, headers={"Authorization": f"Bearer {token}"})
        with urlopen(req, timeout=5) as resp:
            return [g["name"] for g in json.loads(resp.read())]

    def _ensure_tenant(self, __user__: dict) -> dict:
        """
        Ensure user has tenant_code in info.
        If missing, fetch from Keycloak and cache.
        Returns: {"tenant_code": str, "groups": list, "source": str}
        """
        # Check if already cached in user.info
        info = __user__.get("info") or {}
        if isinstance(info, str):
            info = json.loads(info)

        if info.get("tenant_code"):
            return {
                "tenant_code": info["tenant_code"],
                "groups": info.get("keycloak_groups", []),
                "source": "cached"
            }

        # Fetch from Keycloak
        oauth_sub = __user__.get("oauth_sub")
        if not oauth_sub:
            return {"tenant_code": None, "groups": [], "source": "error", "error": "No oauth_sub"}

        try:
            token = self._get_keycloak_token()
            groups = self._get_user_groups(token, oauth_sub)

            if not groups:
                return {"tenant_code": None, "groups": [], "source": "keycloak", "error": "No groups"}

            tenant_code = groups[0]

            # Cache in user.info
            from open_webui.models.users import Users
            user_id = __user__.get("id")
            new_info = info.copy()
            new_info["tenant_code"] = tenant_code
            new_info["keycloak_groups"] = groups
            Users.update_user_by_id(user_id, {"info": new_info})

            return {
                "tenant_code": tenant_code,
                "groups": groups,
                "source": "keycloak_fresh"
            }

        except Exception as e:
            return {"tenant_code": None, "groups": [], "source": "error", "error": str(e)}

    async def get_my_tenant(self, __user__: dict = None) -> str:
        """
        Get the tenant code for the current user.
        Auto-fetches from Keycloak if not cached.
        :return: Tenant information
        """
        if __user__ is None:
            return json.dumps({"error": "No user context"})

        result = self._ensure_tenant(__user__)
        return json.dumps(result, indent=2)

    async def tenant_scoped_query(self, query: str, __user__: dict = None) -> str:
        """
        Example of a tenant-scoped query tool.
        :param query: What to query (e.g., "devices", "consumption")
        :return: Query results scoped to user's tenant
        """
        if __user__ is None:
            return json.dumps({"error": "No user context"})

        tenant_info = self._ensure_tenant(__user__)

        if not tenant_info.get("tenant_code"):
            return json.dumps({
                "error": "Cannot determine tenant",
                "details": tenant_info
            })

        # Example: would call PFN MCP with tenant filter
        return json.dumps({
            "query": query,
            "tenant_code": tenant_info["tenant_code"],
            "message": f"Would execute '{query}' for tenant {tenant_info['tenant_code']}",
            "tenant_source": tenant_info["source"]
        }, indent=2)
