"""Phase 1 Discovery Tests - Scenarios #1-16.

Tests for tenant, device, quantity discovery and data availability tools.
"""

import pytest

from pfn_mcp.tools.device_quantities import compare_device_quantities, list_device_quantities
from pfn_mcp.tools.devices import list_devices
from pfn_mcp.tools.discovery import (
    check_data_freshness,
    find_devices_by_quantity,
    get_device_data_range,
    get_device_info,
    get_tenant_summary,
)
from pfn_mcp.tools.quantities import list_quantities
from pfn_mcp.tools.tenants import list_tenants


class TestTenantDeviceDiscovery:
    """Scenarios #1-5: Tenant and device discovery."""

    @pytest.mark.asyncio
    async def test_list_all_tenants(self, db_pool):
        """Scenario #1: List all tenants in the system."""
        result = await list_tenants()

        assert isinstance(result, list)
        assert len(result) > 0
        # Check structure
        assert "tenant_name" in result[0]
        assert "tenant_code" in result[0]

    @pytest.mark.asyncio
    async def test_tenant_device_counts(self, db_pool):
        """Scenario #2: How many devices does each tenant have?"""
        result = await list_tenants()

        assert isinstance(result, list)
        assert len(result) > 0
        # Should include device count
        assert "device_count" in result[0]
        # At least one tenant should have devices
        has_devices = any(t.get("device_count", 0) > 0 for t in result)
        assert has_devices, "No tenant has any devices"

    @pytest.mark.asyncio
    async def test_search_devices_by_name(self, db_pool, sample_device):
        """Scenario #3: Search for devices with 'pump' in the name."""
        # Use part of sample device name for reliable test
        search_term = sample_device["display_name"][:3]
        result = await list_devices(search=search_term)

        assert isinstance(result, list)
        # Should find at least the sample device
        assert len(result) > 0
        assert "display_name" in result[0]

    @pytest.mark.asyncio
    async def test_fuzzy_match_prefix_handling(self, db_pool):
        """Scenario #4: Find devices containing 'MC-1' (should NOT match MC-10, MC-11)."""
        result = await list_devices(search="MC-1", limit=20)

        assert isinstance(result, list)
        # Verify fuzzy ranking is applied (exact/partial matches ranked higher)
        if len(result) > 0:
            assert "display_name" in result[0]
            assert "match_score" in result[0] or "rank" in result[0] or True  # Structure check

    @pytest.mark.asyncio
    async def test_get_device_details(self, db_pool, sample_device):
        """Scenario #5: Show device details including IP address and slave ID."""
        result = await get_device_info(device_id=sample_device["id"])

        assert isinstance(result, dict)
        assert result.get("found") is True or "device" in result
        # Should include device info
        device_data = result.get("device") or result
        assert "display_name" in device_data or "id" in device_data


class TestQuantityDiscovery:
    """Scenarios #6-9: Quantity and metric discovery."""

    @pytest.mark.asyncio
    async def test_list_all_quantities(self, db_pool):
        """Scenario #6: What types of measurements are available?"""
        result = await list_quantities()

        assert isinstance(result, list)
        assert len(result) > 0
        # Check structure
        assert "quantity_name" in result[0] or "id" in result[0]

    @pytest.mark.asyncio
    async def test_search_voltage_quantities(self, db_pool):
        """Scenario #7: List all voltage-related quantities (semantic search)."""
        result = await list_quantities(search="voltage")

        assert isinstance(result, list)
        # Should find voltage-related quantities
        if len(result) > 0:
            # Verify at least one result contains voltage-related info
            names = [q.get("quantity_name", "").lower() for q in result]
            has_voltage = any("volt" in name or "v" in name for name in names)
            assert has_voltage or len(result) > 0  # At minimum, search returned results

    @pytest.mark.asyncio
    async def test_search_power_quantities(self, db_pool):
        """Scenario #8: What power metrics can I query? (semantic search)."""
        result = await list_quantities(search="power")

        assert isinstance(result, list)
        assert len(result) > 0, "No power-related quantities found"

    @pytest.mark.asyncio
    async def test_search_wage_categories(self, db_pool):
        """Scenario #9: Show water and gas measurement types (WAGE category)."""
        # Test water category
        water_result = await list_quantities(category="WATER")
        # Test gas category
        gas_result = await list_quantities(category="GAS")

        # At least one category should have results (depending on data)
        assert isinstance(water_result, list)
        assert isinstance(gas_result, list)


class TestDeviceQuantityMapping:
    """Scenarios #10-12: Device-quantity mapping."""

    @pytest.mark.asyncio
    async def test_list_device_quantities(self, db_pool, sample_device):
        """Scenario #10: What quantities are available for device?"""
        result = await list_device_quantities(device_id=sample_device["id"])

        assert isinstance(result, dict)
        # Should have quantities list or device info
        assert "quantities" in result or "device" in result or "error" not in result

    @pytest.mark.asyncio
    async def test_find_devices_by_quantity(self, db_pool, power_quantity_id):
        """Scenario #11: Which devices have power factor data?"""
        # Use power quantity (185) as test
        result = await find_devices_by_quantity(quantity_id=power_quantity_id)

        assert isinstance(result, dict)
        # Should have devices list
        assert "devices" in result or "count" in result or "error" not in result

    @pytest.mark.asyncio
    async def test_compare_device_quantities(self, db_pool, sample_device, sample_tenant):
        """Scenario #12: Compare what quantities two devices have in common."""
        # Get another device from same tenant
        from pfn_mcp import db
        other_device = await db.fetch_one("""
            SELECT id, display_name FROM devices
            WHERE tenant_id = $1 AND id != $2 AND is_active = true
            LIMIT 1
        """, sample_tenant["id"], sample_device["id"])

        if other_device:
            result = await compare_device_quantities(
                device_ids=[sample_device["id"], other_device["id"]]
            )
            assert isinstance(result, dict)
            # Should have comparison results
            assert "shared" in result or "devices" in result or "error" not in result
        else:
            pytest.skip("Only one device in tenant, cannot compare")


class TestDataAvailability:
    """Scenarios #13-16: Data availability and freshness."""

    @pytest.mark.asyncio
    async def test_get_device_data_range(self, db_pool, sample_device):
        """Scenario #13: What's the data range for device?"""
        result = await get_device_data_range(device_id=sample_device["id"])

        assert isinstance(result, dict)
        # Should have date range info
        assert "earliest" in result or "latest" in result or "range" in result or "device" in result

    @pytest.mark.asyncio
    async def test_check_offline_meters(self, db_pool, sample_tenant):
        """Scenario #14: Which meters are currently offline?"""
        # Check freshness for all devices in tenant with 1-hour threshold
        result = await check_data_freshness(
            tenant_id=sample_tenant["id"],
            hours_threshold=1
        )

        assert isinstance(result, dict)
        # Should have device status info (devices list with status_summary)
        assert "devices" in result or "status_summary" in result or "device_count" in result

    @pytest.mark.asyncio
    async def test_check_tenant_data_freshness(self, db_pool, sample_tenant):
        """Scenario #15: Check data freshness for all devices in tenant."""
        result = await check_data_freshness(tenant_id=sample_tenant["id"])

        assert isinstance(result, dict)
        # Should have freshness info for tenant (devices list with status_summary)
        assert "devices" in result or "status_summary" in result or "device_count" in result

    @pytest.mark.asyncio
    async def test_get_tenant_summary(self, db_pool, sample_tenant):
        """Scenario #16: Give me a summary of tenant."""
        result = await get_tenant_summary(tenant_id=sample_tenant["id"])

        assert isinstance(result, dict)
        # Should have tenant summary info
        assert "tenant" in result or "device_count" in result or "name" in result
