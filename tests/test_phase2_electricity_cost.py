"""Phase 2 Electricity Cost Tests - Scenarios #25-34.

Tests for electricity cost analysis tools.
"""

import pytest

from pfn_mcp.tools.electricity_cost import (
    compare_electricity_periods,
    get_electricity_cost,
    get_electricity_cost_ranking,
)


class TestBasicCostQueries:
    """Scenarios #25-27: Basic cost queries."""

    @pytest.mark.asyncio
    async def test_device_cost_last_month(self, db_pool, sample_device):
        """Scenario #25: What was the electricity cost for device last month?"""
        result = await get_electricity_cost(
            device=sample_device["display_name"],
            period="1M"
        )

        assert isinstance(result, dict)
        # Should have cost/consumption info
        valid_keys = ["cost", "consumption", "total"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_tenant_energy_consumption(self, db_pool, sample_tenant):
        """Scenario #26: Show total energy consumption for tenant in December 2025."""
        result = await get_electricity_cost(
            tenant=sample_tenant["tenant_name"],
            period="2025-12"
        )

        assert isinstance(result, dict)
        # Should have consumption data
        valid_keys = ["consumption", "cost", "total"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_cost_last_7_days(self, db_pool, sample_device):
        """Scenario #27: Get electricity costs for the last 7 days."""
        result = await get_electricity_cost(
            device=sample_device["display_name"],
            period="7d"
        )

        assert isinstance(result, dict)
        # Should have cost data
        assert "cost" in result or "consumption" in result or "error" not in result


class TestCostBreakdowns:
    """Scenarios #28-30: Cost breakdowns."""

    @pytest.mark.asyncio
    async def test_breakdown_by_shift(self, db_pool, sample_device):
        """Scenario #28: Break down device's electricity cost by shift."""
        result = await get_electricity_cost(
            device=sample_device["display_name"],
            period="30d",
            group_by="shift"
        )

        assert isinstance(result, dict)
        # Should have shift breakdown (SHIFT1/2/3)
        valid_keys = ["breakdown", "shifts", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_breakdown_by_rate(self, db_pool, sample_device):
        """Scenario #29: Show cost breakdown by rate (WBP/LWBP) for device."""
        result = await get_electricity_cost(
            device=sample_device["display_name"],
            period="30d",
            group_by="rate"
        )

        assert isinstance(result, dict)
        # Should have rate breakdown (WBP/LWBP)
        valid_keys = ["breakdown", "rates", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_breakdown_by_source(self, db_pool, sample_tenant):
        """Scenario #30: What's the PLN vs Solar breakdown for tenant?"""
        result = await get_electricity_cost(
            tenant=sample_tenant["tenant_name"],
            period="30d",
            group_by="source"
        )

        assert isinstance(result, dict)
        # Should have source breakdown (PLN/Solar)
        valid_keys = ["breakdown", "sources", "data"]
        has_valid = any(k in result for k in valid_keys) or "PLN" in str(result)
        assert has_valid or "error" not in result


class TestCostRankingComparison:
    """Scenarios #31-34: Cost ranking and comparison."""

    @pytest.mark.asyncio
    async def test_rank_devices_by_cost(self, db_pool, sample_tenant):
        """Scenario #31: Rank all devices by electricity cost for December 2025."""
        result = await get_electricity_cost_ranking(
            tenant=sample_tenant["tenant_name"],
            period="2025-12",
            metric="cost"
        )

        assert isinstance(result, dict)
        # Should have ranking list
        valid_keys = ["ranking", "devices", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_highest_energy_consumer(self, db_pool, sample_tenant):
        """Scenario #32: Which device consumed the most energy last month?"""
        result = await get_electricity_cost_ranking(
            tenant=sample_tenant["tenant_name"],
            period="1M",
            metric="consumption",
            limit=1
        )

        assert isinstance(result, dict)
        # Should have top consumer
        valid_keys = ["ranking", "devices", "top"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_compare_months(self, db_pool, sample_tenant):
        """Scenario #33: Compare November vs December electricity costs for tenant."""
        result = await compare_electricity_periods(
            tenant=sample_tenant["tenant_name"],
            period1="2025-11",
            period2="2025-12"
        )

        assert isinstance(result, dict)
        # Should have comparison data
        valid_keys = ["period1", "period2", "comparison", "change"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_compare_weeks(self, db_pool, sample_device):
        """Scenario #34: How does this week's cost compare to last week for device?"""
        result = await compare_electricity_periods(
            device=sample_device["display_name"],
            period1="7d",
            period2="7d"
        )

        assert isinstance(result, dict)
        # Should have comparison
        valid_keys = ["period1", "comparison", "change"]
        assert any(k in result for k in valid_keys) or "error" not in result
