"""SSE/HTTP transport for MCP server - enables remote deployment."""

import logging
from contextlib import asynccontextmanager

import uvicorn
from mcp.server.sse import SseServerTransport
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from pfn_mcp import db
from pfn_mcp.config import settings
from pfn_mcp.server import mcp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# SSE transport with message endpoint
sse_transport = SseServerTransport("/messages/")


async def handle_sse(request: Request):
    """Handle SSE connection for MCP communication."""
    logger.info(f"New SSE connection from {request.client.host if request.client else 'unknown'}")
    async with sse_transport.connect_sse(
        request.scope, request.receive, request._send
    ) as streams:
        await mcp.run(
            streams[0],
            streams[1],
            mcp.create_initialization_options(),
        )


async def handle_messages(request: Request):
    """Handle POST messages from MCP client."""
    await sse_transport.handle_post_message(request.scope, request.receive, request._send)


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
            "messages": "/messages/",
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
        Route("/sse", endpoint=handle_sse, methods=["GET"]),
        Route("/messages/", endpoint=handle_messages, methods=["POST"]),
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
