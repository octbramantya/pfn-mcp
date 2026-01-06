# Prototype: Open WebUI + Keycloak User Context

**Task:** `pfn_mcp-6ar` - Verify `__user__` context in Open WebUI Python tools

## Verification Results (2026-01-06)

### What Works

1. **`__user__` dict IS injected** into Python tool functions
2. **Available fields:**
   - `id` - Open WebUI user UUID
   - `email` - User email from Keycloak
   - `name` - User display name
   - `role` - Open WebUI role (admin/user)
   - `profile_image_url`, `created_at`, `updated_at`, `last_active_at`
   - `oauth_sub` - Keycloak subject ID

### What Does NOT Work

**Keycloak groups are NOT synced to Open WebUI's groups table.**

Despite configuring:
- `ENABLE_OAUTH_GROUP_MANAGEMENT=true`
- `OAUTH_GROUP_CLAIM=groups`
- `ENABLE_OAUTH_GROUP_CREATION=true`

The Keycloak groups claim (`PRS`) is included in the OAuth token but NOT persisted to Open WebUI's internal groups. The `oauth` field in the user table only stores:
```json
{"oidc": {"sub": "78f53935-9878-4ca0-a649-ad443a9cc0a4"}}
```

Therefore, `Groups.get_groups_by_member_id(__user__["id"])` returns **empty**.

### Implications for PFN MCP

The original plan to extract tenant from Open WebUI groups won't work with the current approach.

**Alternative solutions:**

1. **Store tenant in user.info JSON** - Custom field during OAuth callback
2. **Access OAuth token directly** - If Open WebUI exposes the token claims
3. **Manual group sync** - Create matching groups in Open WebUI Admin
4. **Use oauth_sub for mapping** - Map Keycloak sub → tenant in our backend

## Quick Start

```bash
# 1. Start services
docker compose up -d

# 2. Add host entry (macOS - required for OAuth)
echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts

# 3. Configure Keycloak via API (run this script)
./setup-keycloak.sh  # Or manually configure as below

# 4. Access Open WebUI
open http://localhost:3000
```

## Keycloak Configuration

Access Keycloak Admin: http://host.docker.internal:8080/admin (admin/admin)

### Automated Setup

All configuration can be done via Keycloak Admin REST API:

```bash
# Get admin token
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=admin&grant_type=password&client_id=admin-cli" | jq -r '.access_token')

# Create realm
curl -X POST "http://localhost:8080/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  -d '{"realm": "pfn", "enabled": true}'

# Create groups, client, user... (see setup-keycloak.sh)
```

### Manual Steps

1. Create realm: `pfn`
2. Create groups: `PRS`, `IOP`
3. Create client: `openwebui` with secret `pfn-openwebui-secret`
4. Create scopes: `groups`, `openid` with Group Membership mapper
5. Create user: `testuser` / `testpassword` in group `PRS`

## Test Tool Code

```python
"""
title: User Context Inspector
description: Test tool to inspect user context and groups
author: PFN Team
version: 0.1.0
"""

class Tools:
    def __init__(self):
        pass

    async def inspect_user_context(self, __user__: dict = None) -> str:
        """
        Inspect the __user__ dict and retrieve group memberships.
        :return: JSON with user context and groups
        """
        import json

        result = {"user_fields": {}, "groups": [], "tenant_code": None, "error": None}

        if __user__ is None:
            result["error"] = "__user__ is None"
            return json.dumps(result, indent=2)

        for key, value in __user__.items():
            if key != "valves":
                result["user_fields"][key] = str(value)

        user_id = __user__.get("id")
        if user_id:
            try:
                from open_webui.models.groups import Groups
                member_groups = Groups.get_groups_by_member_id(user_id)
                result["groups"] = [{"id": str(g.id), "name": g.name} for g in member_groups]
                if result["groups"]:
                    result["tenant_code"] = result["groups"][0]["name"]
            except Exception as e:
                result["error"] = str(e)

        return json.dumps(result, indent=2)
```

## Actual Output

```json
{
  "user_fields": {
    "id": "30a82d6a-d5b9-4bba-9bf8-003f3c709c5f",
    "email": "test@example.com",
    "name": "Test User",
    "role": "admin",
    "profile_image_url": "/user.png",
    "last_active_at": "1767665580",
    "updated_at": "1767664607",
    "created_at": "1767664607",
    "oauth_sub": "78f53935-9878-4ca0-a649-ad443a9cc0a4",
    "settings": "{'ui': {'version': '0.6.43'}}"
  },
  "groups": [],
  "tenant_code": null,
  "error": null
}
```

Note: `groups` is empty because Keycloak groups are NOT synced.

## Cleanup

```bash
docker compose down -v  # Remove containers and volumes
```

## Next Steps

See `pfn_mcp-dvl`: Prototype Python plugin wrapper that implements alternative tenant extraction.
