# Phase 4: Web-Based Chat UI - Implementation Plan

**Created:** 2025-01-04
**Updated:** 2025-01-04
**Status:** Planning (Two Options Under Consideration)
**Related:** [concept.md](./concept.md) - Phase 4: Production Readiness

---

## Summary

Two implementation approaches are being considered:

| Aspect | Option A: Custom Build | Option B: Open WebUI |
|--------|------------------------|----------------------|
| Frontend | React/Next.js (build) | Open WebUI (ready-made) |
| LLM Proxy | Direct Anthropic API | LiteLLM (budget enforcement) |
| Tools | Embedded in backend | MCP via SSE |
| Services | 2 (FastAPI + React) | 3 (Open WebUI + LiteLLM + MCP) |
| Code to write | High | Low |
| Ops complexity | Lower | Higher |
| Time to MVP | Longer | Shorter |

**Common requirements:**
- **Tenant Model:** 1 Group = 1 Tenant
- **Budgets:** Per-tenant monthly limits
- **History:** Persist conversations
- **Auth:** Use existing `auth_users` and `auth_user_tenants` tables

---

# Option A: Custom Build

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

---

# Option B: Open WebUI + LiteLLM + MCP

Use existing open-source tools instead of custom build:
- **Frontend:** Open WebUI (ready-made chat interface)
- **LLM Proxy:** LiteLLM (Claude API + usage tracking + budgets)
- **Tools:** Your existing PFN MCP server (connect via SSE)
- **Tenant Model:** 1 Open WebUI Group = 1 Tenant

## Option B Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Open WebUI                                    │
│  - Chat interface (ready-made)                                  │
│  - User/Group management (1 Group = 1 Tenant)                   │
│  - Conversation history (built-in)                              │
│  - MCP connection to your tools                                 │
└─────────────────────┬───────────────────────────────────────────┘
                      │ HTTP (forwards X-OpenWebUI-User-Id)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    LiteLLM Proxy                                 │
│  - Routes to Anthropic API (Claude)                             │
│  - Per-tenant budget enforcement (Team = Tenant)                │
│  - Cost tracking in LiteLLM_SpendLogs                           │
│  - Rejects requests when budget exceeded                        │
└─────────────────────┬───────────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
┌──────────────────┐    ┌──────────────────────────────────────────┐
│  Anthropic API   │    │   PFN MCP Server (your existing code)    │
│  (Claude)        │    │   - Connects via SSE (/sse endpoint)     │
│                  │    │   - Receives tenant context from tools   │
│                  │    │   - Queries Valkyrie database            │
└──────────────────┘    └──────────────────────────────────────────┘
                                          │
                                          ▼
                        ┌──────────────────────────────────────────┐
                        │   PostgreSQL (Valkyrie + TimescaleDB)    │
                        └──────────────────────────────────────────┘
```

## Option B: Key Integration Points

### 1. Open WebUI → MCP Server Connection

Open WebUI has **native MCP support via SSE**. Your existing `sse_server.py` works directly:

**In Open WebUI Admin Settings → External Tools:**
```
Type: MCP (Streamable HTTP)
URL: http://your-mcp-server:8000/sse
```

### 2. LiteLLM Budget Enforcement

**litellm-config.yaml:**
```yaml
model_list:
  - model_name: claude-sonnet
    litellm_params:
      model: claude-sonnet-4-20250514
      api_key: os.environ/ANTHROPIC_API_KEY

general_settings:
  user_header_mappings:
    - header_name: X-OpenWebUI-User-Id
      litellm_user_role: internal_user
```

**Per-team (tenant) budgets via API:**
```bash
curl -X POST http://litellm:4000/team/new \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "team_alias": "tenant_prs",
    "max_budget": 100,
    "budget_duration": "30d"
  }'
```

### 3. Group ↔ Tenant Mapping

| Open WebUI | Your System | LiteLLM |
|------------|-------------|---------|
| Group "PRS" | tenant_id=1 | Team "tenant_prs" |
| Group "IOP" | tenant_id=2 | Team "tenant_iop" |
| User in Group | auth_user_tenants | Team member |

## Option B: Deployment Configuration

**docker-compose.yml:**
```yaml
version: '3.8'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "3000:8080"
    environment:
      - OPENAI_API_BASE_URL=http://litellm:4000/v1
      - OPENAI_API_KEY=dummy
      - ENABLE_FORWARD_USER_INFO_HEADERS=True
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
    volumes:
      - open-webui-data:/app/backend/data
    depends_on:
      - litellm
      - pfn-mcp

  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    ports:
      - "4000:4000"
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - DATABASE_URL=postgresql://...
    volumes:
      - ./litellm-config.yaml:/app/config.yaml
    command: ["--config", "/app/config.yaml"]

  pfn-mcp:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=${DATABASE_URL}
    command: ["python", "-m", "pfn_mcp.sse_server"]

volumes:
  open-webui-data:
```

## Option B: What You Get "For Free"

| Feature | Provided By |
|---------|-------------|
| Chat UI | Open WebUI |
| Conversation history | Open WebUI |
| User authentication | Open WebUI (OAuth/LDAP) |
| Tool execution | Open WebUI → MCP |
| Cost tracking | LiteLLM |
| Budget enforcement | LiteLLM |
| Rate limiting | LiteLLM |

## Option B: What You Need to Build

1. **MCP Server Modifications (Minimal)**
   - Add tenant resolution from user context
   - Ensure all queries are tenant-scoped

2. **Deployment Configuration**
   - Docker-compose setup
   - LiteLLM config
   - Initial tenant/team setup script

3. **Group Sync (TBD)**
   - Script to sync from auth_user_tenants
   - Or OAuth provider with group claims

## Option B: Implementation Steps

1. Deploy Open WebUI + LiteLLM, verify Claude works
2. Connect MCP server, verify tools appear
3. Create groups/teams for tenants
4. Modify MCP tools for tenant context
5. Configure budgets and test enforcement
6. Set up authentication (OAuth TBD)

## Option B: Open Questions

1. How exactly does Open WebUI pass user context to MCP servers?
2. Which OAuth provider to use?
3. How to automate group sync from auth_user_tenants?

---

# Decision Log

| Decision | Choice | Status |
|----------|--------|--------|
| Frontend | Option A (React) or Option B (Open WebUI) | **Under evaluation** |
| Streaming | Request/response | Decided |
| History | Persist in DB | Decided |
| Auth | Existing auth_users | Decided |
| Tenant Model | 1 Group = 1 Tenant | Decided |
| Budgets | Per-tenant monthly | Decided |

---

## References

- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- [Anthropic Tool Use](https://docs.anthropic.com/en/docs/tool-use)
- [FastAPI JWT Auth](https://fastapi.tiangolo.com/tutorial/security/)
- [Next.js App Router](https://nextjs.org/docs/app)
- [Open WebUI Documentation](https://docs.openwebui.com/)
- [Open WebUI MCP Support](https://docs.openwebui.com/features/mcp/)
- [LiteLLM Documentation](https://docs.litellm.ai/)
- [LiteLLM Budget Management](https://docs.litellm.ai/docs/proxy/users)
