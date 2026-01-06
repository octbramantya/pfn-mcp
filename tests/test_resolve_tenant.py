"""Tests for resolve_tenant utility."""

import pytest
import pytest_asyncio

from pfn_mcp.tools.resolve import resolve_tenant


@pytest.mark.asyncio
async def test_resolve_tenant_by_code(db_pool, sample_tenant):
    """Resolve tenant by exact code (e.g., 'PRS')."""
    tenant_id, info, error = await resolve_tenant(sample_tenant["tenant_code"])
    assert error is None
    assert tenant_id == sample_tenant["id"]
    assert info["tenant_code"] == sample_tenant["tenant_code"]


@pytest.mark.asyncio
async def test_resolve_tenant_by_name(db_pool, sample_tenant):
    """Resolve tenant by exact name."""
    tenant_id, info, error = await resolve_tenant(sample_tenant["tenant_name"])
    assert error is None
    assert tenant_id == sample_tenant["id"]
    assert info["tenant_name"] == sample_tenant["tenant_name"]


@pytest.mark.asyncio
async def test_resolve_tenant_none_returns_none(db_pool):
    """None input returns (None, None, None) for superuser mode."""
    tenant_id, info, error = await resolve_tenant(None)
    assert tenant_id is None
    assert info is None
    assert error is None


@pytest.mark.asyncio
async def test_resolve_tenant_empty_string_returns_none(db_pool):
    """Empty string returns (None, None, None) like superuser mode."""
    tenant_id, info, error = await resolve_tenant("")
    assert tenant_id is None
    assert info is None
    assert error is None


@pytest.mark.asyncio
async def test_resolve_tenant_not_found(db_pool):
    """Non-existent tenant returns error."""
    tenant_id, info, error = await resolve_tenant("NONEXISTENT_XYZ_12345")
    assert tenant_id is None
    assert info is None
    assert error is not None
    assert "not found" in error.lower()


@pytest.mark.asyncio
async def test_resolve_tenant_case_insensitive(db_pool, sample_tenant):
    """Tenant resolution is case-insensitive."""
    # Test with lowercase version of tenant code
    tenant_code_lower = sample_tenant["tenant_code"].lower()
    tenant_id, info, error = await resolve_tenant(tenant_code_lower)
    assert error is None
    assert tenant_id == sample_tenant["id"]
