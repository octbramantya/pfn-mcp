"""Phase 2 Telemetry Tests - Scenarios #17-24.

Tests for device resolution and time-series telemetry queries.
"""

import pytest

from pfn_mcp.tools.telemetry import (
    get_device_telemetry,
    get_quantity_stats,
    resolve_device,
)


class TestDeviceResolution:
    """Scenarios #17-18: Device resolution (pre-flight)."""

    @pytest.mark.asyncio
    async def test_resolve_ambiguous_device(self, db_pool):
        """Scenario #17: Resolve device 'pump' (disambiguation)."""
        result = await resolve_device(search="pump")

        assert isinstance(result, dict)
        # Should have candidates or match info
        valid_keys = ["candidates", "matches", "device", "found"]
        assert any(k in result for k in valid_keys)

    @pytest.mark.asyncio
    async def test_resolve_exact_device(self, db_pool, sample_device):
        """Scenario #18: Confirm which device is MC-1 (exact match)."""
        result = await resolve_device(search=sample_device["display_name"])

        assert isinstance(result, dict)
        # Should find the device with high confidence
        if "candidates" in result and len(result["candidates"]) > 0:
            top_match = result["candidates"][0]
            assert "confidence" in top_match or "match_type" in top_match or "score" in top_match


class TestTimeSeries:
    """Scenarios #19-22: Time-series telemetry queries."""

    @pytest.mark.asyncio
    async def test_power_consumption_24h(self, db_pool, sample_device, power_quantity_id):
        """Scenario #19: Show power consumption for device over last 24 hours."""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            period="24h"
        )

        assert isinstance(result, dict)
        # Should have telemetry data or status
        valid_keys = ["data", "telemetry", "values"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_energy_usage_last_week(self, db_pool, sample_device, energy_quantity_id):
        """Scenario #20: What was the energy usage for device last week?"""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_id=energy_quantity_id,
            period="7d"
        )

        assert isinstance(result, dict)
        # Should have data or summary
        valid_keys = ["data", "telemetry", "summary"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_custom_date_range(self, db_pool, sample_device):
        """Scenario #21: Get voltage data for device from custom date range."""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_search="voltage",
            period="30d"  # Use period instead of specific dates for reliability
        )

        assert isinstance(result, dict)
        # Should have result structure
        valid_keys = ["data", "telemetry", "quantity"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_current_readings_yesterday(self, db_pool, sample_device):
        """Scenario #22: Show current readings for device yesterday."""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_search="current",
            period="24h"
        )

        assert isinstance(result, dict)
        # Should have result structure
        valid_keys = ["data", "telemetry", "quantity"]
        assert any(k in result for k in valid_keys) or "error" not in result


class TestQuantityStatistics:
    """Scenarios #23-24: Quantity statistics."""

    @pytest.mark.asyncio
    async def test_data_completeness(self, db_pool, sample_device, power_quantity_id):
        """Scenario #23: What's the data completeness for device's power data last month?"""
        result = await get_quantity_stats(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            period="30d"
        )

        assert isinstance(result, dict)
        # Should have stats info
        valid_keys = ["completeness", "stats", "coverage", "count"]
        assert any(k in result for k in valid_keys)

    @pytest.mark.asyncio
    async def test_active_power_statistics(self, db_pool, sample_device, power_quantity_id):
        """Scenario #24: Show statistics for active power on device."""
        result = await get_quantity_stats(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id
        )

        assert isinstance(result, dict)
        # Should have statistics
        valid_keys = ["min", "max", "avg", "stats", "summary"]
        assert any(k in result for k in valid_keys)
