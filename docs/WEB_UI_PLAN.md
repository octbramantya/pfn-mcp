# Phase 4: Web-Based Chat UI - Implementation Plan

**Created:** 2025-01-04
**Status:** Planning
**Related:** [concept.md](./concept.md) - Phase 4: Production Readiness

---

## Summary

Build a custom web-based chat UI for the PFN MCP server with:
- **Frontend:** React/Next.js
- **Streaming:** Request/response (no streaming for MVP)
- **History:** Persist conversations to database
- **Auth:** Use existing `auth_users` and `auth_user_tenants` tables

---

## How It Works (Key Questions Answered)

### Q1: How does MCP work in a web-based UI vs local Claude Code?

**Local (Claude Code):** `Claude Code → stdio → MCP Server → Database`

**Web-based (what we'll build):**
```
React UI → FastAPI Backend → Anthropic Messages API → Tool execution → Database
                             (with tool definitions)
```

Your backend **orchestrates** Claude API calls and tool execution. You don't use MCP protocol directly - instead, you:
1. Define tools as JSON schemas in API requests
2. Execute tool logic when Claude requests it
3. Return results to Claude

### Q2: Connecting to Claude

**Yes, via Anthropic API key.** Backend holds the key securely.

```python
client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
response = client.messages.create(
    model="claude-sonnet-4-20250514",
    system="You are Valkyrie, an energy assistant for {tenant}...",
    tools=[...],  # Your tool schemas
    messages=[...]
)
```

### Q3: Usage limits per tenant

Implement custom tracking with new tables:
- `mcp.usage_tracking` - per-tenant/user monthly token counts
- `mcp.usage_limits` - configurable limits per tenant
- Middleware checks limits before each API call

### Q4: Limiting to MCP tools only

1. **System prompt** constrains Claude to energy topics only
2. **Tool schemas** define only your MCP tools
3. **Backend validation** filters/rejects off-topic responses

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│              React/Next.js Frontend                             │
│  - Login page (email/password)                                  │
│  - Chat interface (conversation list + messages)                │
│  - Usage indicator                                              │
└─────────────────────┬───────────────────────────────────────────┘
                      │ REST API (JWT in header)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              FastAPI Backend (extend existing)                  │
│                                                                 │
│  /api/auth/login    → Validate credentials, issue JWT          │
│  /api/auth/logout   → Revoke session                           │
│  /api/auth/me       → Get current user + tenant                │
│  /api/chat          → Send message, get response               │
│  /api/conversations → List/get/delete conversations            │
│  /api/usage         → Get current usage stats                  │
│                                                                 │
│  Middleware:                                                    │
│  - JWT validation (extract user_id, tenant_id)                  │
│  - Usage limit check                                            │
│  - Request logging                                              │
└─────────────────────┬───────────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
┌──────────────────┐    ┌──────────────────────────────────────────┐
│  Anthropic API   │    │   PostgreSQL Database                    │
│                  │    │   - auth_users, auth_user_tenants        │
│                  │    │   - mcp.conversations, mcp.messages      │
│                  │    │   - mcp.usage_tracking, mcp.usage_limits │
└──────────────────┘    └──────────────────────────────────────────┘
```

---

## Database Schema (New Tables)

```sql
-- New schema for MCP chat application
CREATE SCHEMA IF NOT EXISTS mcp;

-- Conversations table
CREATE TABLE mcp.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id INTEGER NOT NULL REFERENCES auth_users(id),
    tenant_id INTEGER NOT NULL REFERENCES tenants(id),
    title VARCHAR(255),  -- Auto-generated from first message
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Messages table
CREATE TABLE mcp.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES mcp.conversations(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL,  -- 'user', 'assistant', 'tool_use', 'tool_result'
    content JSONB NOT NULL,     -- Message content (text or tool call)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Usage tracking
CREATE TABLE mcp.usage_tracking (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenants(id),
    user_id INTEGER NOT NULL REFERENCES auth_users(id),
    month DATE NOT NULL,  -- First of month
    input_tokens BIGINT DEFAULT 0,
    output_tokens BIGINT DEFAULT 0,
    requests INTEGER DEFAULT 0,
    UNIQUE(tenant_id, user_id, month)
);

-- Usage limits (per tenant)
CREATE TABLE mcp.usage_limits (
    tenant_id INTEGER PRIMARY KEY REFERENCES tenants(id),
    monthly_input_tokens BIGINT DEFAULT 1000000,
    monthly_output_tokens BIGINT DEFAULT 500000,
    monthly_requests INTEGER DEFAULT 10000,
    is_active BOOLEAN DEFAULT TRUE
);

-- Indexes
CREATE INDEX idx_conversations_user ON mcp.conversations(user_id);
CREATE INDEX idx_conversations_tenant ON mcp.conversations(tenant_id);
CREATE INDEX idx_messages_conversation ON mcp.messages(conversation_id);
CREATE INDEX idx_usage_tenant_month ON mcp.usage_tracking(tenant_id, month);
```

---

## Backend Implementation

### File Structure (additions to existing)

```
src/pfn_mcp/
├── server.py          # Existing MCP server
├── sse_server.py      # Existing SSE transport
├── chat_server.py     # NEW: FastAPI chat backend
├── db.py              # Existing (shared)
├── config.py          # Existing (add new settings)
├── tools/             # Existing tools
├── chat/              # NEW: Chat module
│   ├── __init__.py
│   ├── auth.py        # JWT auth, login/logout
│   ├── claude.py      # Claude API client + tool executor
│   ├── conversations.py  # Conversation CRUD
│   ├── usage.py       # Usage tracking/limits
│   └── models.py      # Pydantic models
└── middleware/        # NEW: Middleware
    ├── __init__.py
    └── tenant.py      # Tenant context injection
```

### Key Components

**1. Auth (`chat/auth.py`):**
```python
async def login(email: str, password: str) -> TokenResponse:
    # Validate against auth_users (bcrypt hash check)
    # Get tenant from auth_user_tenants
    # Create session in auth_user_sessions
    # Return JWT with user_id, tenant_id

async def get_current_user(token: str) -> UserContext:
    # Validate JWT
    # Return user_id, tenant_id, permissions
```

**2. Claude Client (`chat/claude.py`):**
```python
async def chat(
    user_message: str,
    conversation_history: list,
    tenant_id: int,
    user_id: int
) -> AssistantResponse:
    # Build messages from conversation history
    # Call Anthropic API with tools
    # Handle tool calls (execute with tenant context)
    # Return final response + usage stats
```

**3. Tool Executor:**
```python
async def execute_tool(tool_name: str, tool_input: dict, tenant_id: int):
    # Map tool_name to existing tool functions
    # Inject tenant_id into queries
    # Return formatted result
```

---

## Frontend Structure (Next.js)

```
frontend/
├── app/
│   ├── layout.tsx
│   ├── page.tsx          # Redirect to /chat or /login
│   ├── login/page.tsx    # Login form
│   ├── chat/
│   │   ├── page.tsx      # Chat interface
│   │   └── [id]/page.tsx # Specific conversation
│   └── api/              # API routes (if using Next.js API)
├── components/
│   ├── ChatInput.tsx
│   ├── ChatMessage.tsx
│   ├── ConversationList.tsx
│   └── UsageIndicator.tsx
├── lib/
│   ├── api.ts            # API client
│   └── auth.ts           # Auth context/hooks
└── ...
```

---

## Implementation Steps

### Step 1: Database Setup
1. Create `mcp` schema
2. Add `conversations`, `messages`, `usage_tracking`, `usage_limits` tables
3. Set up initial usage limits for existing tenants

### Step 2: Backend Auth
1. Add JWT library to dependencies (`python-jose`, `passlib[bcrypt]`)
2. Create `chat/auth.py` with login/logout/session functions
3. Create auth middleware for tenant context injection
4. Add `/api/auth/*` endpoints to FastAPI

### Step 3: Claude Integration
1. Add `anthropic` library to dependencies
2. Create `chat/claude.py` with Claude API client
3. Define tool schemas from existing tool definitions
4. Create tool executor that calls existing tool functions with tenant context

### Step 4: Chat Endpoints
1. Create `chat/conversations.py` for CRUD
2. Add `/api/chat` endpoint for message handling
3. Add `/api/conversations/*` endpoints
4. Implement conversation title auto-generation

### Step 5: Usage Tracking
1. Create `chat/usage.py` for tracking/limits
2. Add usage check middleware
3. Add `/api/usage` endpoint

### Step 6: Frontend
1. Initialize Next.js project
2. Create login page
3. Create chat interface with conversation sidebar
4. Connect to backend API
5. Add usage indicator

### Step 7: Deployment
1. Docker configuration for both services
2. Nginx reverse proxy setup
3. Environment configuration for production

---

## Security Considerations

- JWT tokens with short expiry (1 hour) + refresh tokens
- HTTPS only in production
- Rate limiting on auth endpoints
- Sanitize user input before Claude
- Audit logging for all API calls (use `auth_audit_logs`)
- CORS configuration for frontend domain only

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `src/pfn_mcp/chat_server.py` | Create | Main FastAPI chat app |
| `src/pfn_mcp/chat/auth.py` | Create | Auth logic |
| `src/pfn_mcp/chat/claude.py` | Create | Claude API client |
| `src/pfn_mcp/chat/conversations.py` | Create | Conversation CRUD |
| `src/pfn_mcp/chat/usage.py` | Create | Usage tracking |
| `src/pfn_mcp/chat/models.py` | Create | Pydantic models |
| `src/pfn_mcp/middleware/tenant.py` | Create | Tenant context middleware |
| `src/pfn_mcp/config.py` | Modify | Add new config options |
| `migrations/create_mcp_schema.sql` | Create | Database migration |
| `frontend/` | Create | Next.js application |

---

## Alternative Approaches Considered

### Fork LibreChat
- **Pros:** Active community, multi-provider support, plugin system
- **Cons:** Node.js backend requires adapter for Python tools
- **Decision:** Rejected - too much adapter complexity

### Fork Open WebUI
- **Pros:** Python backend matches stack
- **Cons:** Originally for Ollama, needs significant Claude adaptation
- **Decision:** Rejected - prefer purpose-built solution

### Custom Build (Selected)
- **Pros:** Exactly what we need, single stack, full control
- **Cons:** More initial work
- **Decision:** Selected - best fit for requirements

---

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Frontend | React/Next.js | Modern, good ecosystem, easier to find chat UI templates |
| Streaming | Request/response | Simpler implementation, good enough for MVP |
| History | Persist in DB | Users can revisit conversations |
| Auth | Existing auth_users | Leverage existing user base, single sign-on potential |
| Build vs Fork | Custom build | Better fit for specific requirements |

---

## References

- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- [Anthropic Tool Use](https://docs.anthropic.com/en/docs/tool-use)
- [FastAPI JWT Auth](https://fastapi.tiangolo.com/tutorial/security/)
- [Next.js App Router](https://nextjs.org/docs/app)
