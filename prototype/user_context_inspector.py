"""
title: User Context Inspector
description: Test tool to inspect __user__ dict and retrieve groups for tenant mapping
author: PFN Team
version: 0.1.0
license: MIT

USAGE:
1. Copy this entire file content
2. Open WebUI Admin -> Workspace -> Tools -> Add Tool
3. Paste and save
4. In a chat, ask: "Use the inspect_user_context tool"
"""

from typing import Any, Callable
from pydantic import BaseModel


class Tools:
    class Valves(BaseModel):
        """Global configuration (admin-only)."""
        pass

    class UserValves(BaseModel):
        """Per-user configuration."""
        pass

    def __init__(self):
        self.valves = self.Valves()

    async def inspect_user_context(
        self,
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Inspect the __user__ dict and retrieve group memberships.

        Use this tool to see what user context is available in Open WebUI Python tools.
        This is useful for verifying Keycloak OAuth group sync.

        :return: JSON representation of user context including groups and tenant mapping
        """
        import json

        result = {
            "user_fields": {},
            "groups": [],
            "tenant_code": None,
            "error": None,
            "notes": []
        }

        # Check if __user__ is available
        if __user__ is None:
            result["error"] = "__user__ is None - context injection failed"
            return json.dumps(result, indent=2)

        # Capture all __user__ fields (excluding valves object for readability)
        for key, value in __user__.items():
            if key == "valves":
                result["user_fields"]["valves"] = "<UserValves object>"
            else:
                result["user_fields"][key] = str(value)

        # Attempt to retrieve groups
        # IMPORTANT: Groups are NOT directly in __user__!
        # They must be retrieved via Groups.get_groups_by_member_id()
        user_id = __user__.get("id")
        if user_id:
            try:
                from open_webui.models.groups import Groups
                member_groups = Groups.get_groups_by_member_id(user_id)
                result["groups"] = [
                    {"id": str(g.id), "name": g.name}
                    for g in member_groups
                ]

                # Map first group to tenant (PFN convention: group name = tenant_code)
                if result["groups"]:
                    result["tenant_code"] = result["groups"][0]["name"]
                    result["notes"].append(
                        f"Tenant '{result['tenant_code']}' extracted from first group"
                    )
                else:
                    result["notes"].append("User has no groups - cannot determine tenant")

            except ImportError as e:
                result["error"] = f"Cannot import Groups model: {e}"
                result["notes"].append(
                    "This may happen if Open WebUI internals changed"
                )
            except Exception as e:
                result["error"] = f"Error retrieving groups: {e}"
        else:
            result["error"] = "No user ID found in __user__ dict"

        return json.dumps(result, indent=2, default=str)

    async def get_tenant_for_query(
        self,
        __user__: dict = None,
    ) -> str:
        """
        Get the tenant code for the current user.

        This simulates how PFN MCP tools would extract tenant context
        before executing tenant-scoped database queries.

        :return: Tenant information for scoping queries
        """
        import json

        if __user__ is None:
            return json.dumps({"error": "No user context available"})

        user_id = __user__.get("id")
        if not user_id:
            return json.dumps({"error": "No user ID in context"})

        try:
            from open_webui.models.groups import Groups
            member_groups = Groups.get_groups_by_member_id(user_id)

            if not member_groups:
                return json.dumps({
                    "error": "User has no groups assigned",
                    "user_id": user_id,
                    "user_email": __user__.get("email"),
                    "action_required": "Assign user to a tenant group in Keycloak"
                })

            # Use first group as tenant (matches Keycloak group = tenant convention)
            tenant_group = member_groups[0]

            return json.dumps({
                "tenant_code": tenant_group.name,
                "user_id": user_id,
                "user_email": __user__.get("email"),
                "all_groups": [g.name for g in member_groups],
                "ready_for_query": True
            }, indent=2)

        except Exception as e:
            return json.dumps({"error": str(e)})
