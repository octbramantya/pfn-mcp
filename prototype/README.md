# Prototype: Open WebUI + Keycloak User Context

**Task:** `pfn_mcp-6ar` - Verify `__user__` context in Open WebUI Python tools

## Summary

This prototype verifies how to extract tenant context from users authenticated via Keycloak OAuth in Open WebUI Python tools.

### Key Finding

**Keycloak groups are NOT automatically synced** to Open WebUI despite `ENABLE_OAUTH_GROUP_MANAGEMENT=true`.

### Solution: Lazy-Loading from Keycloak

The `pfn_tool_wrapper.py` implements a **first-request lazy-loading** pattern:

1. On first tool call, fetch user's groups from Keycloak Admin API
2. Cache tenant info in `user.info` JSON field
3. Subsequent calls use cached value

## Files

| File | Description |
|------|-------------|
| `pfn_tool_wrapper.py` | **Production-ready** PFN tool wrapper with tenant scoping |
| `sync_keycloak_groups.py` | Alternative: Background sync script (cron) |
| `tenant_aware_tool.py` | Simplified example of lazy-loading pattern |
| `user_context_inspector.py` | Debug tool to inspect `__user__` dict |
| `docker-compose.yml` | Local dev setup: Open WebUI + Keycloak |

## Quick Start

```bash
# 1. Start services
docker compose up -d

# 2. Add host entry (macOS - required for OAuth)
echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts

# 3. Configure Keycloak (automated)
# Get token
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=admin&grant_type=password&client_id=admin-cli" | jq -r '.access_token')

# Create realm, groups, client, user (see full script in docs)

# 4. Access Open WebUI
open http://localhost:3000
```

## Using the PFN Tool Wrapper

### Installation

1. Open WebUI Admin → Workspace → Tools → Add Tool
2. Paste contents of `pfn_tool_wrapper.py`
3. Configure Valves:
   - `KEYCLOAK_URL`: `http://keycloak:8080` (Docker network)
   - `KEYCLOAK_REALM`: `pfn`
   - `KEYCLOAK_ADMIN_USER`: admin credentials
   - `MCP_SERVER_URL`: PFN MCP server endpoint
4. Save

### Available Tools

| Tool | Description |
|------|-------------|
| `get_my_tenant` | Show user's tenant and group memberships |
| `list_devices` | List devices for user's tenant |
| `get_consumption` | Get energy consumption data |
| `get_electricity_cost` | Get electricity cost with breakdown |
| `compare_devices` | Compare multiple devices side-by-side |

### How Tenant Resolution Works

```
User calls tool
      ↓
Check __user__.info.tenant_code
      ↓ (cached?)
  ┌───┴───┐
  ↓       ↓
 YES      NO
  ↓       ↓
Return   Fetch from Keycloak API
cached   using oauth_sub
  ↓       ↓
  ↓      Cache in user.info
  ↓       ↓
  └───┬───┘
      ↓
Execute tool with tenant_code filter
```

## Verification Results

### What Works

1. **`__user__` dict IS injected** with fields:
   - `id`, `email`, `name`, `role`
   - `oauth_sub` (Keycloak user ID) ← Key for lookups
   - `info` (JSON field for caching tenant)

2. **user.info can be updated** via `Users.update_user_by_id()`

3. **Keycloak Admin API** accessible for group lookups

### What Does NOT Work

- `ENABLE_OAUTH_GROUP_MANAGEMENT` doesn't sync groups
- `Groups.get_groups_by_member_id()` returns empty
- OAuth session/token not persisted

## Alternative: Background Sync

If lazy-loading latency is unacceptable, use `sync_keycloak_groups.py`:

```bash
# Run via cron every 5 minutes
*/5 * * * * docker exec openwebui python /app/sync_keycloak_groups.py
```

## Cleanup

```bash
docker compose down -v  # Remove containers and volumes
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Open WebUI                               │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│  │   Browser   │───→│  Python Tool     │───→│  PFN MCP       │  │
│  │   (User)    │    │  (pfn_wrapper)   │    │  Server        │  │
│  └─────────────┘    └────────┬─────────┘    └───────┬────────┘  │
│                              │                       │           │
│                    ┌─────────▼─────────┐            │           │
│                    │  _get_tenant()    │            │           │
│                    │  1. Check cache   │            │           │
│                    │  2. Fetch KC API  │            │           │
│                    │  3. Cache result  │            │           │
│                    └─────────┬─────────┘            │           │
│                              │                       │           │
└──────────────────────────────┼───────────────────────┼───────────┘
                               │                       │
                    ┌──────────▼──────────┐  ┌────────▼────────┐
                    │     Keycloak        │  │    Valkyrie     │
                    │  (Groups/Tenants)   │  │   (PostgreSQL)  │
                    └─────────────────────┘  └─────────────────┘
```

## Keycloak Group → Tenant Mapping

**Task:** `pfn_mcp-nta` - Setup Keycloak groups for tenants

Groups are created in Keycloak matching `tenant_code` from the Valkyrie database:

| Keycloak Group | tenant_id | Tenant Name |
|----------------|-----------|-------------|
| `IOP` | 4 | Indo Oil Perkasa |
| `PRS` | 3 | Primarajuli Sukses |

**Group Attributes:**
- `tenant_id`: Database ID for direct lookups
- `tenant_code`: Same as group name
- `description`: Human-readable tenant name

**Token Claims:**
- Claim name: `groups`
- Included in: ID token, Access token, Userinfo
- Full path: `false` (just group name, not `/GroupName`)

**How It Works:**
1. User logs in via Keycloak OAuth
2. Token includes `groups: ["PRS"]` claim
3. `pfn_tool_wrapper.py` reads first group as tenant
4. Tools filter data by tenant_code

**Assigning Users to Groups:**
1. Keycloak Admin Console → Users → Select user
2. Groups tab → Join Group → Select tenant group
3. User's next login will include group in token

## Grafana SSO with Keycloak

**Task:** `pfn_mcp-dn3` - Setup: Keycloak client for Grafana

### Setup Script

```bash
# Run from prototype/ directory
python setup_grafana_keycloak.py --password YOUR_KEYCLOAK_ADMIN_PASSWORD
```

This creates:
- OIDC client `grafana` in Keycloak `pfn` realm
- Group membership mapper (for tenant groups)
- Role mapper (for Grafana role assignment)

### Grafana Environment Variables

Add these to your Grafana deployment:

```bash
GF_SERVER_ROOT_URL=https://viz.forsanusa.id

GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME="Keycloak"
GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<from setup script output>
GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile groups
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.forsanusa.id/realms/pfn/protocol/openid-connect/auth
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://auth.forsanusa.id/realms/pfn/protocol/openid-connect/token
GF_AUTH_GENERIC_OAUTH_API_URL=https://auth.forsanusa.id/realms/pfn/protocol/openid-connect/userinfo

# Role mapping (map Keycloak groups to Grafana roles)
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'Admin') && 'Admin' || 'Viewer'"

# Disable default login to force OAuth
GF_AUTH_DISABLE_LOGIN_FORM=true
```

### Role Mapping

| Keycloak Group | Grafana Role |
|----------------|--------------|
| `Admin` | Admin |
| (any other) | Viewer |

To grant admin access, add user to `Admin` group in Keycloak.

### Organization Mapping

**Task:** `pfn_mcp-25t` - Setup: Grafana org mapping with Keycloak groups

Map Keycloak tenant groups to Grafana organizations so users are auto-assigned to the correct org on login.

**Prerequisites:**
Grafana organizations must exist (use org IDs in mapping):
- Org 5: Primarajuli Sukses (PRS)
- Org 6: Indo Oil Perkasa (IOP)

**Configuration (grafana.ini):**
```ini
[auth.generic_oauth]
# Extract groups array from OAuth token
org_attribute_path = groups

# Map Keycloak groups to Grafana organizations
# Format: <KeycloakGroup>:<GrafanaOrgId>:<Role>
org_mapping = PRS:5:Viewer IOP:6:Viewer
```

**How It Works:**
1. User logs in via Keycloak OAuth
2. Token includes `groups: ["PRS"]` claim
3. Grafana matches group to org via `org_mapping`
4. User is assigned to matching Grafana org with specified role

**Notes:**
- Grafana orgs must be pre-created (no auto-creation)
- Regular users: single group assignment
- Superusers: can be in multiple groups → access to multiple orgs
- Full config: `docs/grafana_ini_oauth.txt`

## Next Steps

1. **Connect to real PFN MCP**: Replace mock `_call_mcp()` with actual MCP client
2. **Production Keycloak**: Use service account instead of admin credentials
3. **Error handling**: Add retry logic for Keycloak API failures
4. **Monitoring**: Log tenant resolution metrics
