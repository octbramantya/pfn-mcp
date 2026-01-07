# User Registration Approval Flow

**Created:** 2026-01-07
**Status:** Planned

## Summary

Implement pre-approval workflow where:
1. Users register via Keycloak but **cannot login** until admin assigns them to a group
2. Admin assigns group via **Keycloak Admin Console** only
3. Sync script runs every **5 minutes** to sync group memberships to `auth_user_tenants`

---

## Part 1: Block Login Without Group

**Approach:** Use Keycloak's built-in conditional authentication flow

### Steps

1. **Create client role** in `openwebui` client:
   - Role name: `approved-user`

2. **Assign role to all tenant groups:**
   - Groups → IOP → Role mapping → Assign `openwebui:approved-user`
   - Repeat for: PME_SITE_1, PME_SITE_2, PRS

3. **Create custom authentication flow:**
   - Duplicate "Browser" flow → name: `Browser with Approval`
   - Add condition at end: "Condition - user role"
     - Config: `openwebui:approved-user`, Negate=true
   - Add "Deny Access" authenticator after condition

4. **Bind flow to client:**
   - Clients → openwebui → Advanced → Authentication flow overrides
   - Browser Flow: `Browser with Approval`

**Result:** Users without group membership get "Access Denied" on login attempt.

---

## Part 2: Sync Script (Keycloak → Valkyrie)

**New file:** `prototype/sync_keycloak_to_valkyrie.py`

### Functionality

1. Fetch all users from Keycloak realm
2. For users in tenant groups:
   - Create/update `auth_users` record (email, name, email_verified)
   - Create/update `auth_user_tenants` record (tenant_id from group attribute)
3. Deactivate memberships for removed groups

### Key Logic

```python
# For each Keycloak user in a tenant group:
async with pool.acquire() as conn:
    # Upsert auth_users
    auth_user_id = await conn.fetchval("""
        INSERT INTO auth_users (email, password_hash, name, email_verified)
        VALUES ($1, 'KEYCLOAK_AUTH', $2, $3)
        ON CONFLICT (email) DO UPDATE SET
            name = EXCLUDED.name,
            email_verified = EXCLUDED.email_verified
        RETURNING id
    """, email, name, email_verified)

    # Insert auth_user_tenants
    await conn.execute("""
        INSERT INTO auth_user_tenants
            (user_id, tenant_id, product_id, role, is_active)
        VALUES ($1, $2, 2, 'viewer', true)
        ON CONFLICT (user_id, tenant_id, product_id)
        DO UPDATE SET is_active = true
    """, auth_user_id, tenant_id)
```

### Environment Variables

```bash
KEYCLOAK_URL=https://auth.forsanusa.id
KEYCLOAK_REALM=pfn
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=***
VALKYRIE_DATABASE_URL=postgresql://postgres:***@88.222.213.96:5432/valkyrie
```

---

## Part 3: Cron Deployment

**Recommended: Crontab** (simplest approach)

### Setup

1. **Create log directory:**
   ```bash
   sudo mkdir -p /var/log
   sudo touch /var/log/keycloak-sync.log
   sudo chown $USER /var/log/keycloak-sync.log
   ```

2. **Create environment file** on VPS:
   ```bash
   # /opt/pfn_mcp/sync.env
   KEYCLOAK_URL=https://auth.forsanusa.id
   KEYCLOAK_REALM=pfn
   KEYCLOAK_ADMIN_USER=admin
   KEYCLOAK_ADMIN_PASSWORD=your-password-here
   VALKYRIE_DATABASE_URL=postgresql://postgres:password@88.222.213.96:5432/valkyrie
   ```

3. **Add crontab entry:**
   ```bash
   crontab -e
   ```

   Add this line (runs every 5 minutes):
   ```cron
   */5 * * * * set -a && source /opt/pfn_mcp/sync.env && /opt/pfn_mcp/.venv/bin/python /opt/pfn_mcp/prototype/sync_keycloak_to_valkyrie.py >> /var/log/keycloak-sync.log 2>&1
   ```

4. **Verify:**
   ```bash
   crontab -l                          # List cron jobs
   tail -f /var/log/keycloak-sync.log  # Watch logs
   ```

### Manual Run

```bash
# Dry run (preview changes)
cd /opt/pfn_mcp
source sync.env
.venv/bin/python prototype/sync_keycloak_to_valkyrie.py --dry-run

# Actual sync
.venv/bin/python prototype/sync_keycloak_to_valkyrie.py
```

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `prototype/sync_keycloak_to_valkyrie.py` | ✅ Created | Main sync script |
| `prototype/.env.example` | ✅ Updated | Added sync script env vars |
| `prototype/README.md` | Modify | Document approval workflow |
| Keycloak Admin Console | Configure | Auth flow + client role |

---

## Workflow Diagram

```
User Registers → Keycloak (no group)
                     ↓
              Login BLOCKED
                     ↓
Admin assigns group (e.g., PRS)
                     ↓
              Login ALLOWED
                     ↓
Sync script (5 min) → auth_users + auth_user_tenants
                     ↓
User uses MCP tools → tenant-scoped queries
```

---

## Testing Checklist

- [ ] New user without group → login blocked
- [ ] Assign user to PRS group → login works
- [ ] Run sync script → auth_user_tenants record created
- [ ] Remove user from group → login blocked again
- [ ] Sync script → auth_user_tenants.is_active = false
