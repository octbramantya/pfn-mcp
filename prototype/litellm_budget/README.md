# Prototype: LiteLLM Per-Team Budget Enforcement

**Task:** `pfn_mcp-j8e`

## Overview

This prototype tests LiteLLM's per-team budget enforcement feature for tenant cost control.

### What We're Testing

1. **Create teams matching tenants** - PRS, IOP, NAV with budget limits
2. **Set budget limits** - Small budgets ($0.10-$0.50) for testing
3. **Verify header mapping** - X-OpenWebUI-User-Id forwarded to LiteLLM
4. **Confirm rejection** - Requests rejected when budget exceeded

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Open WebUI                              │
│   ENABLE_FORWARD_USER_INFO_HEADERS=True                     │
│   → Sends X-OpenWebUI-User-Id header                        │
└───────────────────────┬─────────────────────────────────────┘
                        │ HTTP + Headers
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                      LiteLLM Proxy                           │
│   - Team = Tenant (PRS, IOP, NAV)                           │
│   - Budget enforcement per team                             │
│   - Spend tracking in PostgreSQL                            │
│   - API key → Team mapping                                  │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                      OpenAI API                              │
│   (or Claude API when available)                            │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Copy environment file and add your API keys
cp .env.example .env
# Edit .env with your OPENAI_API_KEY and/or ANTHROPIC_API_KEY

# 2. Start services
docker compose up -d

# 3. Wait for healthy status
docker compose ps

# 4. Setup teams with budget limits ($5/month)
python test_budget.py setup

# 5. Test budget enforcement
python test_budget.py test --team PRS

# 6. Check status
python test_budget.py status --team PRS

# 7. Update existing teams to new budget config
python test_budget.py update
```

## Files

| File | Description |
|------|-------------|
| `docker-compose.yml` | LiteLLM + PostgreSQL + Open WebUI stack |
| `litellm-config.yaml` | LiteLLM proxy configuration |
| `test_budget.py` | Test script for budget enforcement |
| `.env.example` | Environment variables template |

## Test Commands

```bash
# Setup teams and generate API keys
python test_budget.py setup

# Update team budgets to current config (after editing TENANTS dict)
python test_budget.py update

# Test budget (sends requests until rejected)
python test_budget.py test --team PRS

# Check team spend status
python test_budget.py status --team PRS

# Reset spend for re-testing
python test_budget.py reset --team PRS
```

## Open WebUI Usage Tool

An Open WebUI tool is available for users to check their usage: `../openwebui_usage_tool.py`

### Installation

1. Open WebUI Admin -> Workspace -> Functions -> Add Function
2. Set type to "Tool"
3. Paste the contents of `openwebui_usage_tool.py`
4. Configure Valves:
   - `LITELLM_URL`: Your LiteLLM proxy URL
   - `LITELLM_MASTER_KEY`: Master key for querying team info
   - `TEAM_ID`: Team UUID from `team_keys.json`
5. Enable the tool for your model in Workspace -> Models

### Usage

Users can ask:
- "check my usage"
- "how much budget do I have left"

The tool displays a progress bar similar to Claude Code's `/usage` command.

## LiteLLM API Reference

### Create Team
```bash
curl -X POST http://localhost:4000/team/new \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "PRS",
    "max_budget": 10.0,
    "budget_duration": "30d"
  }'
```

### Generate Team Key
```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "team-uuid-here",
    "key_alias": "prs-key"
  }'
```

### Check Team Status
```bash
curl http://localhost:4000/team/info?team_id=team-uuid-here \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

## Budget Enforcement Behavior

When budget is exceeded, LiteLLM returns:

```json
{
  "error": {
    "message": "ExceededTokenBudget: Current spend for token: X. Max Budget for Token: Y",
    "type": "budget_exceeded",
    "code": 400
  }
}
```

## Open WebUI Integration

Open WebUI forwards these headers when `ENABLE_FORWARD_USER_INFO_HEADERS=True`:
- `X-OpenWebUI-User-Id`
- `X-OpenWebUI-User-Email`
- `X-OpenWebUI-User-Name`
- `X-OpenWebUI-User-Role`
- `X-OpenWebUI-Chat-Id`

### User-to-Team Mapping Options

1. **API Key per Team** (current prototype)
   - Each tenant gets a unique API key tied to their team
   - Open WebUI configured with team-specific key

2. **JWT with team_id claim** (recommended for production)
   - Keycloak includes tenant group in JWT
   - LiteLLM uses `team_id_jwt_field` to extract team
   - Auto-provision teams with `team_id_upsert: true`

3. **Header-based mapping** (future)
   - Map X-OpenWebUI-User-Id to team via custom logic
   - Requires LiteLLM custom auth handler

## Findings (Tested 2026-01-06)

### What Works

- [x] **Team creation with budget limits** - `/team/new` with `max_budget` and `budget_duration`
- [x] **API key generation tied to teams** - `/key/generate` with `team_id`
- [x] **Budget enforcement** - Requests rejected with HTTP 400 when budget exceeded
- [x] **Spend tracking** - Persists in PostgreSQL, survives container restarts
- [x] **Open WebUI integration** - Connects to LiteLLM, forwards user headers
- [x] **Cost tracking accuracy** - LiteLLM accurately tracks spend per model

### Verified Behavior

```
# Team with budget exceeded → Request rejected
Request #1... REJECTED: Budget exceeded
Budget enforcement working correctly!

# Team with budget remaining → Requests succeed
Request #1... OK (tokens: 17, est cost: $0.000010)
Request #2... OK (tokens: 17, est cost: $0.000010)
```

### Limitations

- **No automatic header → team mapping** - LiteLLM doesn't natively map `X-OpenWebUI-User-Id` to teams
- **Per-team API keys required** - Each tenant needs a unique API key tied to their team
- **Alternative: JWT setup** - Use `team_id_jwt_field` with Keycloak for automatic mapping
- **Custom auth handler** - Needed for header-based user-to-team resolution

## Next Steps

1. Test with Keycloak JWT integration
2. Implement custom auth handler for header mapping
3. Production: Use longer budget_duration (30d)
4. Production: Set appropriate budget limits per tenant

## Cleanup

```bash
# Stop and remove containers
docker compose down

# Remove volumes (reset all data)
docker compose down -v
```
