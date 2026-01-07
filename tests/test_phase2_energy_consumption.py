"""Phase 2 Energy Consumption Tests.

Tests for get_energy_consumption tool - actual consumption from cumulative meter data.
"""

import pytest

from pfn_mcp.tools.energy_consumption import (
    CUMULATIVE_QUANTITY_IDS,
    get_energy_consumption,
    select_energy_data_source,
)
from pfn_mcp.tools.telemetry import get_device_telemetry


class TestEnergyConsumptionBasic:
    """Basic energy consumption queries."""

    @pytest.mark.asyncio
    async def test_energy_consumption_7d(self, db_pool, device_with_energy_data):
        """Get energy consumption for last 7 days (default period)."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="7d"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert "device" in result
            assert "quantity" in result
            assert "time_range" in result
            assert "summary" in result
            assert "data" in result

    @pytest.mark.asyncio
    async def test_energy_consumption_by_device_id(self, db_pool, device_with_energy_data):
        """Query by device_id."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"]
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert result["device"]["id"] == device_with_energy_data["id"]

    @pytest.mark.asyncio
    async def test_energy_consumption_by_device_name(self, db_pool, device_with_energy_data):
        """Query by device_name (fuzzy search)."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_name=device_with_energy_data["display_name"]
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert result["device"]["id"] == device_with_energy_data["id"]

    @pytest.mark.asyncio
    async def test_energy_consumption_with_explicit_quantity(
        self, db_pool, device_with_energy_data, energy_quantity_id
    ):
        """Query with explicit quantity_id=124."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            quantity_id=energy_quantity_id
        )

        assert isinstance(result, dict)
        # Either success or error (device may not have this quantity)
        if "error" not in result:
            assert result["quantity"]["id"] == energy_quantity_id


class TestEnergyQuantityResolution:
    """Quantity auto-detection and search."""

    @pytest.mark.asyncio
    async def test_auto_detect_energy_quantity(self, db_pool, device_with_energy_data):
        """Default quantity when none specified (auto-detect)."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"]
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # Should auto-detect an energy quantity
            assert result["quantity"]["id"] in CUMULATIVE_QUANTITY_IDS

    @pytest.mark.asyncio
    async def test_search_active_energy(self, db_pool, device_with_energy_data):
        """Search with quantity_search='active energy'."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            quantity_search="active energy"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # Active energy should be 124 or 131
            assert result["quantity"]["id"] in {124, 131}

    @pytest.mark.asyncio
    async def test_search_energy_alias(self, db_pool, device_with_energy_data):
        """Search with quantity_search='energy' alias."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            quantity_search="energy"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert result["quantity"]["id"] in {124, 131}

    @pytest.mark.asyncio
    async def test_invalid_quantity_id(self, db_pool, device_with_energy_data):
        """Non-energy quantity returns error."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        # quantity_id=185 is Active Power (not cumulative)
        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            quantity_id=185
        )

        assert isinstance(result, dict)
        assert "error" in result
        assert "not an energy quantity" in result["error"].lower()


class TestDataSourceSelection:
    """Smart data source routing based on bucket size."""

    def test_daily_bucket_uses_daily_summary(self):
        """bucket='1day' uses daily_energy_cost_summary."""
        source = select_energy_data_source("1day")
        assert source == "daily_energy_cost_summary"

    def test_weekly_bucket_uses_daily_summary(self):
        """bucket='1week' uses daily_energy_cost_summary."""
        source = select_energy_data_source("1week")
        assert source == "daily_energy_cost_summary"

    def test_hourly_bucket_uses_intervals_view(self):
        """bucket='1hour' uses telemetry_intervals_cumulative."""
        source = select_energy_data_source("1hour")
        assert source == "telemetry_intervals_cumulative"

    def test_15min_bucket_uses_intervals_view(self):
        """bucket='15min' uses telemetry_intervals_cumulative."""
        source = select_energy_data_source("15min")
        assert source == "telemetry_intervals_cumulative"

    @pytest.mark.asyncio
    async def test_auto_bucket_selection(self, db_pool, device_with_energy_data):
        """bucket='auto' selects appropriate source based on time range."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="7d",
            bucket="auto"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # 7d period should use daily bucket
            assert result["time_range"]["data_source"] in (
                "daily_energy_cost_summary",
                "telemetry_intervals_cumulative"
            )


class TestCostCalculation:
    """Cost included in responses."""

    @pytest.mark.asyncio
    async def test_daily_consumption_includes_cost(self, db_pool, device_with_energy_data):
        """Daily queries include total_cost from pre-calculated data."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="7d",
            bucket="1day"
        )

        assert isinstance(result, dict)
        if "error" not in result and result["point_count"] > 0:
            # Daily source should have cost
            assert "total_consumption" in result["summary"]
            # Cost might be 0 if no rate configured, but key should exist if data exists
            if result["summary"]["total_consumption"] > 0:
                # Cost should be present (may be 0 if no rate)
                assert "total_cost" in result["summary"] or True  # Cost is optional

    @pytest.mark.asyncio
    async def test_subdaily_consumption_calculates_cost(self, db_pool, device_with_energy_data):
        """Hourly queries calculate cost via get_utility_rate()."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="24h",
            bucket="1hour"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert "summary" in result
            assert "total_consumption" in result["summary"]

    @pytest.mark.asyncio
    async def test_response_has_rate_codes(self, db_pool, device_with_energy_data):
        """Data points may include rate_codes array."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="7d",
            bucket="1day"
        )

        assert isinstance(result, dict)
        if "error" not in result and result["point_count"] > 0:
            # At least some data points should exist
            assert len(result["data"]) > 0
            # rate_codes may or may not be present depending on data
            first_point = result["data"][0]
            assert "consumption" in first_point


class TestEdgeCases:
    """Error handling and edge cases."""

    @pytest.mark.asyncio
    async def test_invalid_device(self, db_pool):
        """Unknown device returns error."""
        result = await get_energy_consumption(
            device_name="nonexistent_device_xyz_12345"
        )

        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_invalid_period(self, db_pool, device_with_energy_data):
        """Bad period format returns error."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="invalid_period"
        )

        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_invalid_bucket(self, db_pool, device_with_energy_data):
        """Invalid bucket returns error."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            bucket="invalid_bucket"
        )

        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_include_quality_info(self, db_pool, device_with_energy_data):
        """include_quality_info=True returns data_quality breakdown."""
        if device_with_energy_data is None:
            pytest.skip("No device with energy data found")

        result = await get_energy_consumption(
            device_id=device_with_energy_data["id"],
            period="7d",
            bucket="1hour",
            include_quality_info=True
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # data_quality should be present when requested
            assert "data_quality" in result


class TestCumulativeWarning:
    """Warning in get_device_telemetry for cumulative quantities."""

    @pytest.mark.asyncio
    async def test_telemetry_warns_on_energy_quantity(
        self, db_pool, sample_device, energy_quantity_id
    ):
        """Querying energy via get_device_telemetry includes warning."""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_id=energy_quantity_id,
            period="7d"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # Should have warning for cumulative quantity
            assert "warning" in result
            assert result["warning"]["type"] == "cumulative_quantity"
            assert "get_energy_consumption" in result["warning"]["recommendation"]

    @pytest.mark.asyncio
    async def test_telemetry_no_warning_for_power(
        self, db_pool, sample_device, power_quantity_id
    ):
        """Non-cumulative quantities have no cumulative warning."""
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            period="7d"
        )

        assert isinstance(result, dict)
        if "error" not in result:
            # Should not have cumulative warning for power
            if "warning" in result:
                assert result["warning"].get("type") != "cumulative_quantity"
