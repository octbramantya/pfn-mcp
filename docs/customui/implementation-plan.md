# PFN Custom Chat UI - Implementation Plan

**Documentation Location:** `docs/customui/`
**Supersedes:** `docs/custom-ui.md` (old plan)
**Created:** 2026-01-10

---

## Summary

Replace Open WebUI with a custom chat UI that:
- Eliminates tool wrapper maintenance (direct Python tool calls)
- Provides per-tenant branding (logos, colors)
- Enforces tenant isolation at the backend (not LLM)
- Supports superuser tenant switching via dropdown

## Key Decisions

| Decision | Choice |
|----------|--------|
| Tool execution | Direct Python calls (no mcpo layer) |
| Chat isolation | User-isolated (shared folders in v2) |
| Deployment | Separate Next.js + FastAPI containers |
| Model selection | Single model per deployment |
| Access denied UX | Silent filtering (no tenant reveal) |
| Superuser UX | Dropdown tenant selector in header |
| Branding config | Database table (`mcp.tenant_branding`) |
| Mobile strategy | Web first, then Capacitor wrapper |
| Timeline | 6 weeks MVP, replace Open WebUI completely |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│           Next.js Frontend (Container 1)         │
│  - Keycloak OAuth login                          │
│  - Chat interface with SSE streaming             │
│  - Conversation sidebar                          │
│  - Tenant selector (superuser only)              │
│  - Per-tenant branding (logo, colors)            │
└─────────────────────┬───────────────────────────┘
                      │ REST + SSE (JWT header)
                      ▼
┌─────────────────────────────────────────────────┐
│          FastAPI Backend (Container 2)           │
│  - JWT auth with tenant context                  │
│  - Tool registry (imports tool modules)          │
│  - Tool executor (injects tenant)                │
│  - Conversation persistence                      │
│  - LiteLLM client for Claude API                 │
└────────┬─────────────┬──────────────────────────┘
         │             │
         ▼             ▼
┌─────────────┐  ┌─────────────────────────────────┐
│  LiteLLM    │  │  PostgreSQL                     │
│  (Claude)   │  │  - mcp.conversations            │
│  - Budget   │  │  - mcp.messages                 │
│  - Streaming│  │  - mcp.tenant_branding          │
└─────────────┘  └─────────────────────────────────┘
```

---

## Database Schema

```sql
CREATE SCHEMA IF NOT EXISTS mcp;

-- Conversations (user-isolated)
CREATE TABLE mcp.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id INTEGER NOT NULL REFERENCES public.auth_users(id),
    tenant_id INTEGER NOT NULL REFERENCES public.tenants(id),
    title VARCHAR(255),
    model VARCHAR(100) DEFAULT 'claude-sonnet-4-20250514',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Messages
CREATE TABLE mcp.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES mcp.conversations(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL, -- 'user', 'assistant', 'tool_use', 'tool_result'
    content TEXT NOT NULL,
    tool_name VARCHAR(100),
    tool_call_id VARCHAR(100),
    input_tokens INTEGER,
    output_tokens INTEGER,
    sequence INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tenant branding
CREATE TABLE mcp.tenant_branding (
    tenant_id INTEGER PRIMARY KEY REFERENCES public.tenants(id),
    logo_url TEXT,
    primary_color VARCHAR(7),
    secondary_color VARCHAR(7),
    display_name VARCHAR(255),
    welcome_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## Key Implementation Patterns

### 1. Tool Registry (no mcpo)
```python
# src/pfn_mcp/chat/tool_registry.py
TOOL_IMPLEMENTATIONS = {
    "list_devices": (devices.list_devices, devices.format_devices_response),
    "get_electricity_cost": (cost.get_electricity_cost, cost.format_response),
    # ... all 38 tools mapped
}
```

### 2. Tenant Injection (at backend)
```python
# src/pfn_mcp/chat/tool_executor.py
async def execute_tool(tool_name, tool_input, tenant_code):
    if tool_meta.get("tenant_aware") and tenant_code:
        tool_input["tenant"] = tenant_code  # Always inject
    result = await tool_func(**tool_input)
    return format_func(result)
```

### 3. Superuser Context Header
```python
# Superuser sends: X-Tenant-Context: PRS
if is_superuser and x_tenant_context:
    tenant_code = x_tenant_context  # Use selected tenant
elif is_superuser:
    tenant_code = None  # See all tenants
else:
    tenant_code = user.tenant_code  # Regular user - locked
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/auth/login` | Redirect to Keycloak |
| `GET` | `/api/auth/callback` | OAuth callback, return JWT |
| `GET` | `/api/auth/me` | User info + tenant + branding |
| `PUT` | `/api/auth/tenant` | Switch tenant (superuser) |
| `POST` | `/api/chat` | Send message, stream response (SSE) |
| `GET` | `/api/conversations` | List user's conversations |
| `GET` | `/api/conversations/{id}` | Get conversation messages |
| `DELETE` | `/api/conversations/{id}` | Delete conversation |
| `GET` | `/api/usage` | Budget percentage |

---

## Phased Implementation

### Phase 1: Foundation (Week 1-2)
- [ ] Database migration (mcp schema)
- [ ] FastAPI backend skeleton
- [ ] Keycloak OAuth integration
- [ ] Tool registry + executor
- [ ] Basic `/api/chat` with streaming
- [ ] Next.js skeleton with login

### Phase 2: Persistence (Week 3)
- [ ] Conversation CRUD
- [ ] Message persistence
- [ ] Conversation sidebar
- [ ] Usage meter (LiteLLM)

### Phase 3: Multi-tenant (Week 4)
- [ ] Tenant branding from database
- [ ] Superuser dropdown
- [ ] Dynamic logo/colors
- [ ] Silent filtering verified

### Phase 4: Polish (Week 5)
- [ ] Error handling
- [ ] Mobile responsive
- [ ] Docker compose setup
- [ ] Deployment to VPS

### Phase 5: Mobile (Week 6)
- [ ] Capacitor integration
- [ ] iOS/Android builds
- [ ] App store prep

---

## Files to Create

| File | Purpose |
|------|---------|
| `migrations/001_mcp_chat_schema.sql` | Database schema |
| `src/pfn_mcp/chat/__init__.py` | Chat module |
| `src/pfn_mcp/chat/app.py` | FastAPI routes |
| `src/pfn_mcp/chat/auth.py` | JWT + Keycloak |
| `src/pfn_mcp/chat/tool_registry.py` | Tool mapping |
| `src/pfn_mcp/chat/tool_executor.py` | Execute with tenant |
| `src/pfn_mcp/chat/claude.py` | LiteLLM streaming |
| `src/pfn_mcp/chat/conversations.py` | CRUD operations |
| `src/pfn_mcp/chat_server.py` | Entry point |
| `frontend/` | Next.js app |
| `docker-compose.chat.yml` | Deployment |

## Files to Modify

| File | Change |
|------|--------|
| `Caddyfile` | Add chat subdomain routing |

---

## Verification

1. **Auth**: Login via Keycloak, receive JWT, see tenant in `/api/auth/me`
2. **Chat**: Send message, see streaming response with tool calls
3. **Tenant isolation**: Regular user cannot see other tenant's devices
4. **Superuser**: Dropdown switches tenant context, queries reflect change
5. **Branding**: Different logos/colors per tenant
6. **Mobile**: Responsive design, Capacitor build succeeds

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| LiteLLM integration issues | Start with direct Anthropic API, add LiteLLM layer later |
| SSE buffering (nginx) | Disable buffering with `X-Accel-Buffering: no` |
| Tool errors break chat | Wrap all tools in try/catch, return graceful errors |
| Tenant data leakage | Backend ALWAYS injects tenant, never trust client |
