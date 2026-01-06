"""Pytest configuration and shared fixtures for integration tests."""

import asyncio

import pytest
import pytest_asyncio

from pfn_mcp import db


@pytest.fixture(scope="session")
def event_loop():
    """Create a single event loop for the entire test session."""
    policy = asyncio.get_event_loop_policy()
    loop = policy.new_event_loop()
    yield loop
    loop.close()


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def db_pool():
    """Initialize database pool for the entire test session."""
    await db.init_pool()
    yield db.get_pool()
    await db.close_pool()


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def sample_tenant(db_pool):
    """Get a sample tenant with devices for testing."""
    result = await db.fetch_one("""
        SELECT t.id, t.tenant_name, t.tenant_code
        FROM tenants t
        WHERE t.is_active = true
        AND EXISTS (SELECT 1 FROM devices d WHERE d.tenant_id = t.id AND d.is_active = true)
        LIMIT 1
    """)
    assert result is not None, "No active tenant with devices found in database"
    return result


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def sample_device(db_pool, sample_tenant):
    """Get a sample device with recent telemetry data."""
    result = await db.fetch_one("""
        SELECT d.id, d.display_name, d.device_code, d.tenant_id
        FROM devices d
        WHERE d.tenant_id = $1 AND d.is_active = true
        AND EXISTS (
            SELECT 1 FROM telemetry_15min_agg t
            WHERE t.device_id = d.id
            AND t.bucket >= NOW() - INTERVAL '30 days'
        )
        LIMIT 1
    """, sample_tenant["id"])
    assert result is not None, "No device with recent telemetry found"
    return result


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def sample_quantity(db_pool):
    """Get a sample quantity that has data in telemetry."""
    result = await db.fetch_one("""
        SELECT DISTINCT q.id, q.quantity_name, q.quantity_code, q.unit
        FROM quantities q
        JOIN telemetry_15min_agg t ON t.quantity_id = q.id
        WHERE t.bucket >= NOW() - INTERVAL '30 days'
        LIMIT 1
    """)
    assert result is not None, "No quantity with recent telemetry found"
    return result


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def sample_tag(db_pool):
    """Get a sample tag key/value pair that has devices."""
    result = await db.fetch_one("""
        SELECT tag_key, tag_value, COUNT(*) as device_count
        FROM device_tags
        WHERE is_active = true
        GROUP BY tag_key, tag_value
        HAVING COUNT(*) > 0
        ORDER BY COUNT(*) DESC
        LIMIT 1
    """)
    # Tag might not exist in all environments
    return result


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def power_quantity_id(db_pool):
    """Get the Active Power quantity ID (185)."""
    result = await db.fetch_val("""
        SELECT id FROM quantities WHERE id = 185
    """)
    return result or 185  # Default to 185 if not found


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def energy_quantity_id(db_pool):
    """Get the Active Energy Delivered quantity ID (124)."""
    result = await db.fetch_val("""
        SELECT id FROM quantities WHERE id = 124
    """)
    return result or 124  # Default to 124 if not found
