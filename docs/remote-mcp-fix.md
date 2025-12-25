# Remote MCP Server Connection Fix

## Issue Summary

Claude Desktop cannot natively connect to remote SSE/HTTP MCP servers. It requires a bridge like `mcp-remote` to convert SSE transport to stdio.

## The Problem

When using `mcp-remote` with Node.js < 20.18.1, the following error occurs:

```
SSE error: undefined: Key Symbol(headers list) in undefined.headers is a symbol, which cannot be converted to a ByteString.
```

This is a known compatibility bug in `mcp-remote` with older Node versions.

## Environment Details

- **Required**: Node.js >= 20.18.1
- **Problematic**: Node.js 20.11.0 (and similar versions below 20.18.1)

## Solution

### Option 1: Update Node.js (for true remote MCP)

```bash
# Using nvm
nvm install 20.18.1
nvm alias default 20.18.1

# Reinstall mcp-remote
npm install -g mcp-remote
```

Then use this Claude Desktop config:

```json
{
  "mcpServers": {
    "pfn-mcp": {
      "command": "/path/to/.npm-global/bin/mcp-remote",
      "args": ["http://88.222.213.96:8000/sse", "--allow-http"]
    }
  }
}
```

### Option 2: Local stdio with remote database (recommended for development)

Run MCP server locally but connect to remote database:

```json
{
  "mcpServers": {
    "pfn-mcp": {
      "command": "/path/to/pfn_mcp/.venv/bin/python",
      "args": ["-m", "pfn_mcp.server"],
      "env": {
        "DATABASE_URL": "postgresql://postgres:PASSWORD@88.222.213.96:5432/valkyrie"
      }
    }
  }
}
```

**Benefits of Option 2:**
- No dependency on mcp-remote or Node version
- More reliable - direct connection, fewer moving parts
- Same functionality - still connects to remote database
- Faster - no network hop for MCP protocol

## When to Use Remote SSE

The VPS SSE server (`http://88.222.213.96:8000/sse`) is useful for:
- Multiple users connecting to the same MCP server
- Web-based clients (not Claude Desktop)
- Sharing MCP across different machines
- Production deployments

## VPS Server Status

The SSE server is deployed and running on the VPS:
- Health check: `curl http://88.222.213.96:8000/health`
- SSE endpoint: `http://88.222.213.96:8000/sse`
- Update command: `pfn-update` (run as root on VPS)

## Related Files

- `src/pfn_mcp/server.py` - stdio transport (local)
- `src/pfn_mcp/sse_server.py` - SSE/HTTP transport (remote)
- `deploy/` - VPS deployment scripts
