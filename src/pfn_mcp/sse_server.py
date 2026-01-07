"""SSE/HTTP transport for MCP server - enables remote deployment."""
  # NOTE: In production, this server must NOT be exposed to public internet.
  # It should only be accessible from the internal Docker network (Open WebUI).

import logging
from contextlib import asynccontextmanager
from urllib.parse import parse_qs
from uuid import UUID

import uvicorn
from mcp.server.sse import SseServerTransport
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from pfn_mcp import db
from pfn_mcp.config import settings
from pfn_mcp.server import mcp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# SSE transport with message endpoint
sse_transport = SseServerTransport("/messages/")


async def handle_sse(scope, receive, send):
    """Handle SSE connection for MCP communication (raw ASGI)."""
    # Only handle GET requests for SSE stream
    if scope["method"] == "GET":
        logger.info("New SSE connection")
        async with sse_transport.connect_sse(scope, receive, send) as streams:
            await mcp.run(
                streams[0],
                streams[1],
                mcp.create_initialization_options(),
            )
    else:
        # Return 405 Method Not Allowed for non-GET
        await send({
            "type": "http.response.start",
            "status": 405,
            "headers": [[b"content-type", b"text/plain"]],
        })
        await send({
            "type": "http.response.body",
            "body": b"Method Not Allowed. Use GET for SSE, POST to /messages/",
        })


async def handle_messages(scope, receive, send):
    """Handle POST messages from MCP client (raw ASGI).

    Validates session before delegating to SSE transport to prevent
    stale sessions from returning 202 Accepted then failing internally.
    """
    if scope["method"] == "POST":
        # Extract and validate session_id before accepting the message
        query_string = scope.get("query_string", b"").decode()
        params = parse_qs(query_string)
        session_id_param = params.get("session_id", [None])[0]

        if not session_id_param:
            await send({
                "type": "http.response.start",
                "status": 400,
                "headers": [[b"content-type", b"text/plain"]],
            })
            await send({
                "type": "http.response.body",
                "body": b"session_id is required",
            })
            return

        try:
            session_id = UUID(hex=session_id_param)
        except ValueError:
            await send({
                "type": "http.response.start",
                "status": 400,
                "headers": [[b"content-type", b"text/plain"]],
            })
            await send({
                "type": "http.response.body",
                "body": b"Invalid session ID format",
            })
            return

        # Check if session exists and is still alive
        writer = sse_transport._read_stream_writers.get(session_id)
        if writer is None:
            logger.warning(f"Session not found: {session_id}")
            await send({
                "type": "http.response.start",
                "status": 404,
                "headers": [[b"content-type", b"text/plain"]],
            })
            await send({
                "type": "http.response.body",
                "body": b"Session not found. Please reconnect.",
            })
            return

        # Check if the stream writer is closed (stale session)
        # anyio MemoryObjectSendStream has _closed attribute
        if getattr(writer, "_closed", False):
            logger.warning(f"Session stream closed (stale): {session_id}")
            # Clean up the stale session
            del sse_transport._read_stream_writers[session_id]
            await send({
                "type": "http.response.start",
                "status": 404,
                "headers": [[b"content-type", b"text/plain"]],
            })
            await send({
                "type": "http.response.body",
                "body": b"Session expired. Please reconnect.",
            })
            return

        # Session is valid, delegate to transport
        await sse_transport.handle_post_message(scope, receive, send)
    else:
        await send({
            "type": "http.response.start",
            "status": 405,
            "headers": [[b"content-type", b"text/plain"]],
        })
        await send({
            "type": "http.response.body",
            "body": b"Method Not Allowed. Use POST for messages.",
        })


async def health_check(request: Request):
    """Health check endpoint for monitoring."""
    db_ok = await db.check_connection()
    status = "healthy" if db_ok else "degraded"
    return JSONResponse({
        "status": status,
        "server": settings.server_name,
        "version": settings.server_version,
        "database": "connected" if db_ok else "disconnected",
    }, status_code=200 if db_ok else 503)


async def root(request: Request):
    """Root endpoint with server info."""
    return JSONResponse({
        "name": settings.server_name,
        "version": settings.server_version,
        "endpoints": {
            "sse": "/sse",
            "messages": "/sse/messages/",
            "health": "/health",
        },
    })


@asynccontextmanager
async def lifespan(app: Starlette):
    """Application lifespan - initialize and cleanup resources."""
    logger.info(f"Starting {settings.server_name} v{settings.server_version} (SSE transport)")

    # Initialize database pool
    try:
        await db.init_pool()
        if await db.check_connection():
            logger.info("Database connection verified")
        else:
            logger.warning("Database connection check failed")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")

    yield

    # Cleanup
    await db.close_pool()
    logger.info("Server shutdown complete")


# Create Starlette application
app = Starlette(
    routes=[
        Route("/", endpoint=root, methods=["GET"]),
        Route("/health", endpoint=health_check, methods=["GET"]),
        Mount("/sse/messages", app=handle_messages),
        Mount("/sse", app=handle_sse),
    ],
    lifespan=lifespan,
)


def main():
    """Entry point for SSE server."""
    uvicorn.run(
        "pfn_mcp.sse_server:app",
        host=settings.server_host,
        port=settings.server_port,
        log_level="info",
    )


if __name__ == "__main__":
    main()
