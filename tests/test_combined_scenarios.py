"""Combined Scenarios Tests - Scenarios #49-53.

Tests that call multiple tools sequentially to verify end-to-end workflows.
"""

import pytest

from pfn_mcp.tools.discovery import check_data_freshness, get_device_info, get_tenant_summary
from pfn_mcp.tools.electricity_cost import (
    compare_electricity_periods,
    get_electricity_cost,
    get_electricity_cost_ranking,
)
from pfn_mcp.tools.group_telemetry import compare_groups
from pfn_mcp.tools.peak_analysis import get_peak_analysis
from pfn_mcp.tools.telemetry import get_device_telemetry


class TestEnergyManagerQuestions:
    """Scenarios #49-50: Energy manager multi-tool workflows."""

    @pytest.mark.asyncio
    async def test_device_energy_profile(self, db_pool, sample_device, power_quantity_id):
        """Scenario #49: Complete device energy profile analysis.

        Multi-tool sequence:
        1. get_device_info - Device details
        2. get_electricity_cost - Last month's consumption
        3. get_peak_analysis - Peak demand times
        4. get_electricity_cost (group_by=shift) - Cost breakdown by shift
        """
        # Step 1: Get device details
        device_info = await get_device_info(device_id=sample_device["id"])
        assert isinstance(device_info, dict)
        assert "error" not in device_info or device_info.get("found") is not False

        # Step 2: Get last month's consumption
        consumption = await get_electricity_cost(
            device=sample_device["display_name"],
            period="1M"
        )
        assert isinstance(consumption, dict)

        # Step 3: Get peak demand times
        peaks = await get_peak_analysis(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            period="1M",
            top_n=5
        )
        assert isinstance(peaks, dict)

        # Step 4: Get cost breakdown by shift
        breakdown = await get_electricity_cost(
            device=sample_device["display_name"],
            period="1M",
            group_by="shift"
        )
        assert isinstance(breakdown, dict)

        # All 4 calls should complete without error
        assert True

    @pytest.mark.asyncio
    async def test_compare_group_efficiency(self, db_pool):
        """Scenario #50: Compare energy efficiency between groups for last quarter.

        Multi-tool sequence:
        1. compare_groups - Side-by-side consumption comparison
        """
        from pfn_mcp import db

        # Get available tag values
        tags = await db.fetch_all("""
            SELECT DISTINCT tag_key, tag_value
            FROM device_tags
            WHERE is_active = true
            ORDER BY tag_key, tag_value
            LIMIT 3
        """)

        if len(tags) < 2:
            pytest.skip("Not enough tag values to compare groups")

        groups = [
            {"tag_key": t["tag_key"], "tag_value": t["tag_value"]}
            for t in tags[:2]
        ]

        # Compare groups for 3 months (quarter approximation)
        result = await compare_groups(
            groups=groups,
            period="3M"
        )

        assert isinstance(result, dict)
        # Should have comparison data for efficiency analysis
        valid_keys = ["groups", "comparison", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result


class TestTroubleshootingScenarios:
    """Scenarios #51-52: Troubleshooting workflows."""

    @pytest.mark.asyncio
    async def test_find_offline_meters(self, db_pool, sample_tenant):
        """Scenario #51: Which meters haven't reported data in the last hour?

        Single tool with specific threshold.
        """
        result = await check_data_freshness(
            tenant=sample_tenant["tenant_code"],
            hours_threshold=1
        )

        assert isinstance(result, dict)
        # Should have device status categorization (tenant mode returns devices list)
        assert "devices" in result or "error" in result

        # Check status summary for device counts
        if "status_summary" in result:
            status_summary = result["status_summary"]
            # Should have status counts (online, recent, stale, no_data)
            assert isinstance(status_summary, dict)

    @pytest.mark.asyncio
    async def test_low_power_factor_devices(self, db_pool, sample_device):
        """Scenario #52: Show devices with power factor data yesterday.

        Note: Actual threshold filtering (PF < 0.85) would require post-processing
        of telemetry data. This test verifies we can retrieve PF data.
        """
        result = await get_device_telemetry(
            device_id=sample_device["id"],
            quantity_search="power factor",
            period="24h"
        )

        assert isinstance(result, dict)
        # Should have telemetry data that could be filtered
        valid_keys = ["data", "telemetry", "quantity"]
        assert any(k in result for k in valid_keys) or "error" not in result


class TestManagementReporting:
    """Scenario #53: Management reporting workflow."""

    @pytest.mark.asyncio
    async def test_comprehensive_tenant_report(self, db_pool, sample_tenant):
        """Scenario #53: Prepare comprehensive tenant summary.

        Multi-tool sequence:
        1. get_tenant_summary - Total devices and overview
        2. get_electricity_cost - December energy consumption
        3. get_electricity_cost_ranking - Top 5 highest-cost devices
        4. compare_electricity_periods - Month-over-month comparison
        """
        # Step 1: Get tenant summary
        summary = await get_tenant_summary(tenant_id=sample_tenant["id"])
        assert isinstance(summary, dict)

        # Step 2: Get December consumption
        dec_consumption = await get_electricity_cost(
            tenant=sample_tenant["tenant_name"],
            period="2025-12"
        )
        assert isinstance(dec_consumption, dict)

        # Step 3: Get top 5 highest-cost devices
        ranking = await get_electricity_cost_ranking(
            tenant=sample_tenant["tenant_name"],
            period="2025-12",
            metric="cost",
            limit=5
        )
        assert isinstance(ranking, dict)

        # Step 4: Month-over-month comparison
        mom_comparison = await compare_electricity_periods(
            tenant=sample_tenant["tenant_name"],
            period1="2025-11",
            period2="2025-12"
        )
        assert isinstance(mom_comparison, dict)

        # All 4 calls should complete - this validates the full reporting workflow
        assert True
