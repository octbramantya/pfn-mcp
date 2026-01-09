# Custom Chat UI Implementation Plan

## Decisions Made

| Choice | Decision |
|--------|----------|
| Auth | Keycloak OAuth (SSO) |
| LLM Routing | Keep LiteLLM (budget tracking) |
| Frontend | Next.js |
| Streaming | Yes, SSE streaming |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Browser (Next.js)                                │
│  - Keycloak OAuth login                                             │
│  - Chat interface with streaming                                    │
│  - Conversation history sidebar                                     │
│  - Usage meter (percentage-based)                                   │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ REST + SSE (JWT in header)
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                FastAPI Chat Backend                                  │
│                                                                      │
│  POST /api/auth/callback    ← Keycloak OAuth callback               │
│  GET  /api/auth/me          → User info + tenant                    │
│  POST /api/chat             → Stream Claude response                │
│  GET  /api/conversations    → List user's conversations             │
│  GET  /api/conversations/:id → Get conversation messages            │
│  DELETE /api/conversations/:id → Delete conversation                │
│  GET  /api/usage            → Team budget status (from LiteLLM)     │
│                                                                      │
└────────┬─────────────────┬──────────────────┬───────────────────────┘
         │                 │                  │
         ▼                 ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐
│  LiteLLM    │    │ PostgreSQL  │    │ Keycloak            │
│  (Claude)   │    │             │    │                     │
│             │    │ mcp schema: │    │ - OAuth tokens      │
│ - Budget    │    │ - convos    │    │ - User groups       │
│ - Streaming │    │ - messages  │    │ - Tenant mapping    │
└─────────────┘    └─────────────┘    └─────────────────────┘
```

---

## What Already Exists (Reusable)

| Component | Location | Status |
|-----------|----------|--------|
| 38 MCP tools | `src/pfn_mcp/tools/` | ✅ Ready |
| Tool schemas | `src/pfn_mcp/tools.yaml` | ✅ Ready |
| SSE server | `src/pfn_mcp/sse_server.py` | ✅ Ready |
| DB connection pool | `src/pfn_mcp/db.py` | ✅ Ready |
| Auth tables | `auth_users`, `auth_user_tenants` | ✅ Ready |
| Tenant resolution | `prototype/pfn_tool_wrapper.py` | ✅ Pattern ready |
| LiteLLM config | `prototype/litellm_budget/` | ✅ Ready |
| Keycloak | Deployed on VPS | ✅ Ready |
| Team budgets | PRS/IOP/NAV at $5/month | ✅ Ready |

---

## Implementation Steps

### Phase 1: Database Schema (1 day)

Create `mcp` schema for chat persistence:

```sql
-- File: migrations/001_mcp_chat_schema.sql

CREATE SCHEMA IF NOT EXISTS mcp;

CREATE TABLE mcp.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth_users(id),
    tenant_id INTEGER NOT NULL REFERENCES tenants(id),
    title VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE mcp.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES mcp.conversations(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL, -- 'user', 'assistant', 'tool_use', 'tool_result'
    content TEXT NOT NULL,
    tool_name VARCHAR(100), -- for tool_use/tool_result messages
    token_count INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_conversations_user ON mcp.conversations(user_id);
CREATE INDEX idx_messages_conversation ON mcp.messages(conversation_id);
```

### Phase 2: FastAPI Backend (1 week)

**Directory structure:**
```
src/pfn_mcp/
├── chat/
│   ├── __init__.py
│   ├── app.py           # FastAPI app, routes
│   ├── auth.py          # Keycloak OAuth, JWT validation
│   ├── claude.py        # LiteLLM client, tool execution
│   ├── conversations.py # CRUD operations
│   ├── models.py        # Pydantic schemas
│   └── streaming.py     # SSE response handling
└── chat_server.py       # Entry point (uvicorn)
```

**Key endpoints:**

1. **`POST /api/auth/callback`** - Keycloak OAuth callback
   - Exchange code for tokens
   - Create/update user in auth_users
   - Return JWT for frontend

2. **`POST /api/chat`** - Main chat endpoint
   - Validate JWT, extract tenant
   - Load conversation or create new
   - Call LiteLLM with tool definitions
   - Stream response via SSE
   - Persist messages

3. **`GET /api/usage`** - Budget status
   - Query LiteLLM `/team/info` for spend
   - Return percentage (no dollar values)

### Phase 3: Next.js Frontend (1 week)

**Directory structure:**
```
frontend/
├── app/
│   ├── layout.tsx
│   ├── page.tsx              # Redirect to /chat or /login
│   ├── login/page.tsx        # Keycloak redirect
│   ├── auth/callback/page.tsx # OAuth callback handler
│   └── chat/
│       ├── layout.tsx        # Sidebar + main area
│       ├── page.tsx          # New conversation
│       └── [id]/page.tsx     # Existing conversation
├── components/
│   ├── ChatMessage.tsx
│   ├── ChatInput.tsx
│   ├── ConversationList.tsx
│   ├── UsageMeter.tsx
│   └── StreamingMessage.tsx
├── lib/
│   ├── api.ts               # API client
│   ├── auth.ts              # Token management
│   └── hooks.ts             # useChat, useConversations
└── next.config.js
```

**Key features:**
- Keycloak login redirect
- Chat interface with streaming (EventSource API)
- Conversation sidebar
- Usage meter (progress bar)
- Mobile-responsive

### Phase 4: Integration & Deployment (3 days)

**Docker setup:**
```yaml
# docker-compose.chat.yml
services:
  chat-backend:
    build: .
    command: python -m pfn_mcp.chat_server
    environment:
      - KEYCLOAK_URL=...
      - LITELLM_URL=http://litellm:4000
      - DATABASE_URL=...

  chat-frontend:
    build: ./frontend
    environment:
      - NEXT_PUBLIC_API_URL=...
      - NEXT_PUBLIC_KEYCLOAK_URL=...
```

**Caddy reverse proxy:**
```
chat.forsanusa.id {
    handle /api/* {
        reverse_proxy chat-backend:8000
    }
    handle {
        reverse_proxy chat-frontend:3000
    }
}
```

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `migrations/001_mcp_chat_schema.sql` | Create | Database schema |
| `src/pfn_mcp/chat/` | Create | Backend module |
| `src/pfn_mcp/chat_server.py` | Create | Entry point |
| `frontend/` | Create | Next.js app |
| `docker-compose.chat.yml` | Create | Chat stack |
| `Caddyfile` | Modify | Add chat subdomain |

---

## Verification

1. **Database:** Run migration, verify tables created
2. **Backend:**
   - `curl /api/auth/me` with valid JWT returns user+tenant
   - `curl /api/chat` streams Claude response
   - Messages persisted in database
3. **Frontend:**
   - Login redirects to Keycloak
   - Chat shows streaming response
   - Conversations saved and loadable
4. **Budget:** Usage meter shows correct percentage from LiteLLM

---

## Out of Scope (Intentionally Simple)

- ❌ Admin panel
- ❌ Tool configuration UI
- ❌ Model selector
- ❌ File uploads
- ❌ Image generation
- ❌ User management UI
- ❌ Analytics dashboard
