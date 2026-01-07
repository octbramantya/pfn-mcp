# MCP SSE Session Expiry Issue

## Summary

Claude Desktop does not properly handle MCP SSE session expiry. When the SSE connection dies during idle periods, Claude Desktop fails to detect the disconnection and continues attempting to use the stale session, resulting in repeated tool call failures.

## Symptoms

Server logs show:
```
INFO:  POST /sse/messages/?session_id=xxx HTTP/1.1" 202 Accepted
WARNING:root:Failed to validate request: Received request before initialization was complete
```

This pattern repeats with the same session_id, and Claude Desktop reports tool call failures.

## Root Cause

### MCP Initialization Protocol

The MCP protocol requires a handshake before tool calls:

1. Client → `GET /sse` (opens SSE stream)
2. Server → SSE event: `endpoint=/sse/messages/?session_id=xxx`
3. Client → `POST {"method": "initialize", ...}`
4. Server → SSE: `InitializeResult`
5. Client → `POST {"method": "notifications/initialized"}`
6. **NOW** tool calls are allowed

### What Happens During Idle

1. User establishes MCP connection, tools work normally
2. Chat is left idle for extended period (hours)
3. SSE connection silently dies due to:
   - TCP keepalive timeout
   - Network/firewall idle connection pruning
   - Server-side connection limits
4. Claude Desktop does not detect the disconnection
5. User attempts to use tools
6. Claude Desktop sends POST to old session_id without re-initializing
7. Server rejects: "Received request before initialization was complete"

### Claude Desktop Behavior

- MCP connections are cached at the **application level**, not per-chat
- Opening a new chat window reuses the existing (possibly dead) connection
- Only restarting Claude Desktop forces a fresh MCP connection

## Server-Side Mitigation

We added session validation in `sse_server.py` to detect and reject stale sessions with clear 404 errors instead of accepting them and failing internally:

```python
# Check if session exists and is still alive
writer = sse_transport._read_stream_writers.get(session_id)
if writer is None:
    # Return 404 "Session not found"

# Check if the stream writer is closed (stale session)
if getattr(writer, "_closed", False):
    # Clean up and return 404 "Session expired"
```

This helps when the session is completely dead, but does not fix the case where Claude Desktop connects fresh but skips the initialization handshake (thinking it's already initialized).

## Workarounds

### For Users

1. **Restart Claude Desktop** when tools stop working - this forces a fresh MCP connection and resolves the issue

2. **Avoid long idle periods** - if you need to leave a chat idle, expect to restart Claude Desktop before using tools again

### Potential Server-Side Improvements (Not Implemented)

1. **SSE Keepalive Pings** - Send periodic SSE comments to keep connections alive longer
2. **Session Timeout** - Proactively expire sessions after a configurable idle period
3. **Initialization State Tracking** - Track which sessions completed initialization and return specific errors for non-initialized tool calls

## Testing

Verify SSE endpoint is working:
```bash
curl -N http://your-server:8000/sse/
```

Expected output:
```
event: endpoint
data: /sse/messages/?session_id=xxxxxx
```

## Related

- MCP SSE Transport: `mcp.server.sse.SseServerTransport`
- Server implementation: `src/pfn_mcp/sse_server.py`
- MCP Protocol Specification: https://modelcontextprotocol.io/

## Date Documented

2025-01-07
