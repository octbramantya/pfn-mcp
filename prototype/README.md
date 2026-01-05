# Prototype: Open WebUI + Keycloak User Context

**Task:** `pfn_mcp-6ar` - Verify `__user__` context in Open WebUI Python tools

## Quick Start

```bash
# 1. Copy environment file
cp .env.example .env

# 2. Start services
docker compose up -d

# 3. Wait for services (~30 seconds)
docker compose logs -f  # Watch until ready

# 4. Configure Keycloak (see below)

# 5. Access Open WebUI
open http://localhost:3000
```

## Keycloak Configuration

Access Keycloak Admin: http://localhost:8080/admin (admin/admin)

### Step 1: Create Realm
- Top-left dropdown → Create realm
- Realm name: `pfn`

### Step 2: Create Groups (= Tenants)
- Left menu: Groups → Create group
- Create: `PRS`, `IOP`

### Step 3: Create Client
- Left menu: Clients → Create client
- Client ID: `openwebui`
- Client authentication: **ON**
- Next → Save
- Go to Credentials tab → Copy **Client secret** to `.env`

**Settings tab:**
- Valid redirect URIs: `http://localhost:3000/*`
- Web origins: `http://localhost:3000`

### Step 4: Create Group Membership Mapper (CRITICAL!)
- Left menu: Client scopes → Create client scope
  - Name: `groups`
  - Type: Default
  - Save

- Click into `groups` scope → Mappers → Add mapper → By configuration
  - Select: **Group Membership**
  - Name: `groups`
  - Token Claim Name: `groups`
  - **Full group path: OFF** (important!)
  - Add to ID token: ON
  - Add to access token: ON
  - Save

- Left menu: Clients → `openwebui` → Client scopes
  - Add client scope → `groups` → Add (Default)

### Step 5: Create Test User
- Left menu: Users → Add user
  - Username: `testuser`
  - Email: `test@example.com`
  - Email verified: ON
  - Save

- Credentials tab → Set password
  - Password: `testpassword`
  - Temporary: OFF

- Groups tab → Join group → `PRS`

## Update .env

After creating the client, update `.env`:

```bash
OAUTH_CLIENT_SECRET=<paste-client-secret-here>
WEBUI_SECRET_KEY=any-random-string-here
```

Then restart Open WebUI:
```bash
docker compose restart open-webui
```

## Test the Tool

1. Open http://localhost:3000
2. Click "Sign in with Keycloak"
3. Login: `testuser` / `testpassword`
4. Go to Admin → Workspace → Tools → Add Tool
5. Paste contents of `user_context_inspector.py`
6. Save
7. New chat → "Use the inspect_user_context tool"

## Expected Output

```json
{
  "user_fields": {
    "id": "abc123...",
    "email": "test@example.com",
    "name": "testuser",
    "role": "user"
  },
  "groups": [
    {"id": "...", "name": "PRS"}
  ],
  "tenant_code": "PRS",
  "error": null,
  "notes": ["Tenant 'PRS' extracted from first group"]
}
```

## Key Finding

**Groups are NOT directly in `__user__`!**

Must retrieve via:
```python
from open_webui.models.groups import Groups
groups = Groups.get_groups_by_member_id(__user__["id"])
tenant_code = groups[0].name if groups else None
```

## Cleanup

```bash
docker compose down -v  # Remove containers and volumes
```
