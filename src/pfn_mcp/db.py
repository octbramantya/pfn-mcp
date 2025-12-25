"""Database connection layer using asyncpg."""

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

from pfn_mcp.config import settings

logger = logging.getLogger(__name__)

# Global connection pool
_pool: asyncpg.Pool | None = None


async def init_pool() -> asyncpg.Pool:
    """Initialize the database connection pool."""
    global _pool
    if _pool is not None:
        return _pool

    min_size, max_size = settings.db_pool_min_size, settings.db_pool_max_size
    logger.info(f"Creating connection pool (min={min_size}, max={max_size})")
    _pool = await asyncpg.create_pool(
        settings.database_url,
        min_size=settings.db_pool_min_size,
        max_size=settings.db_pool_max_size,
        command_timeout=settings.db_query_timeout,
    )
    logger.info("Connection pool created successfully")
    return _pool


async def close_pool() -> None:
    """Close the database connection pool."""
    global _pool
    if _pool is not None:
        logger.info("Closing connection pool")
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    """Get the current connection pool. Raises if not initialized."""
    if _pool is None:
        raise RuntimeError("Database pool not initialized. Call init_pool() first.")
    return _pool


@asynccontextmanager
async def get_connection():
    """Acquire a connection from the pool."""
    pool = get_pool()
    async with pool.acquire() as conn:
        yield conn


async def fetch_all(query: str, *args: Any, timeout: float | None = None) -> list[dict]:
    """Execute a query and return all rows as dictionaries."""
    timeout = timeout or settings.db_query_timeout
    async with get_connection() as conn:
        rows = await asyncio.wait_for(
            conn.fetch(query, *args),
            timeout=timeout,
        )
        return [dict(row) for row in rows]


async def fetch_one(query: str, *args: Any, timeout: float | None = None) -> dict | None:
    """Execute a query and return a single row as dictionary."""
    timeout = timeout or settings.db_query_timeout
    async with get_connection() as conn:
        row = await asyncio.wait_for(
            conn.fetchrow(query, *args),
            timeout=timeout,
        )
        return dict(row) if row else None


async def fetch_val(query: str, *args: Any, timeout: float | None = None) -> Any:
    """Execute a query and return a single value."""
    timeout = timeout or settings.db_query_timeout
    async with get_connection() as conn:
        return await asyncio.wait_for(
            conn.fetchval(query, *args),
            timeout=timeout,
        )


async def execute(query: str, *args: Any, timeout: float | None = None) -> str:
    """Execute a query and return the status."""
    timeout = timeout or settings.db_query_timeout
    async with get_connection() as conn:
        return await asyncio.wait_for(
            conn.execute(query, *args),
            timeout=timeout,
        )


async def check_connection() -> bool:
    """Test database connectivity."""
    try:
        result = await fetch_val("SELECT 1")
        return result == 1
    except Exception as e:
        logger.error(f"Database connection check failed: {e}")
        return False
