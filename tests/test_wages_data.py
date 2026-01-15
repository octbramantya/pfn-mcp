"""Tests for unified get_wages_data tool.

Scenarios covered:
- Basic device queries (single device by ID or name)
- Tag-based group queries
- Named aggregation queries
- Inline formula queries
- Aggregation methods (sum, avg, max, min)
- Breakdown options (none, device, daily, shift, rate)
- Output formats (summary, timeseries)
- Edge cases and error handling
"""

import pytest

from pfn_mcp.tools import wages_data


class TestBasicDeviceQueries:
    """Single device queries."""

    @pytest.mark.asyncio
    async def test_device_by_id(self, db_pool, sample_device):
        """Query single device by ID."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d"
        )
        assert isinstance(result, dict)
        assert "error" not in result

    @pytest.mark.asyncio
    async def test_device_by_name(self, db_pool, sample_device):
        """Query single device by name (fuzzy match)."""
        result = await wages_data.get_wages_data(
            device_name=sample_device["display_name"],
            period="7d"
        )
        assert isinstance(result, dict)
        # May return error if no cost data, but should not crash
        assert isinstance(result.get("error"), str) or "scope" in result

    @pytest.mark.asyncio
    async def test_device_with_tenant(self, db_pool, sample_device, sample_tenant):
        """Query device with tenant context."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            tenant=sample_tenant["tenant_code"],
            period="7d"
        )
        assert isinstance(result, dict)


class TestTagBasedGroups:
    """Tag-based grouping queries."""

    @pytest.mark.asyncio
    async def test_single_tag_group(self, db_pool, sample_tag):
        """Query by single tag key/value."""
        if sample_tag is None:
            pytest.skip("No tags available in database")
        result = await wages_data.get_wages_data(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_multi_tag_query(self, db_pool, sample_tag):
        """Multi-tag AND query."""
        if sample_tag is None:
            pytest.skip("No tags available in database")
        result = await wages_data.get_wages_data(
            tags=[{"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]}],
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_tag_group_with_tenant(self, db_pool, sample_tag, sample_tenant):
        """Tag group filtered by tenant."""
        if sample_tag is None:
            pytest.skip("No tags available in database")
        result = await wages_data.get_wages_data(
            tenant=sample_tenant["tenant_code"],
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d"
        )
        assert isinstance(result, dict)


class TestNamedAggregations:
    """Named aggregation queries from meter_aggregations table."""

    @pytest.mark.asyncio
    async def test_facility_aggregation(self, db_pool, sample_tenant, sample_aggregation):
        """Query named aggregation."""
        if sample_aggregation is None:
            pytest.skip("No aggregations available in database")
        result = await wages_data.get_wages_data(
            tenant=sample_tenant["tenant_code"],
            aggregation=sample_aggregation["name"],
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_aggregation_not_found(self, db_pool, sample_tenant, sample_aggregation):
        """Unknown aggregation returns helpful error."""
        # Skip if meter_aggregations table doesn't exist
        if sample_aggregation is None:
            pytest.skip("meter_aggregations table not available")
        result = await wages_data.get_wages_data(
            tenant=sample_tenant["tenant_code"],
            aggregation="nonexistent_aggregation_xyz",
            period="7d"
        )
        assert isinstance(result, dict)
        # Should return error with available aggregations
        assert "error" in result or "available" in str(result).lower()

    @pytest.mark.asyncio
    async def test_aggregation_with_breakdown(self, db_pool, sample_tenant, sample_aggregation):
        """Aggregation with daily breakdown."""
        if sample_aggregation is None:
            pytest.skip("No aggregations available in database")
        result = await wages_data.get_wages_data(
            tenant=sample_tenant["tenant_code"],
            aggregation=sample_aggregation["name"],
            period="7d",
            breakdown="daily"
        )
        assert isinstance(result, dict)


class TestInlineFormulas:
    """Inline formula queries."""

    @pytest.mark.asyncio
    async def test_single_device_formula(self, db_pool, sample_device):
        """Single device ID as formula."""
        result = await wages_data.get_wages_data(
            formula=str(sample_device["id"]),
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_addition_formula(self, db_pool):
        """Sum of multiple devices."""
        from pfn_mcp import db as db_module
        devices = await db_module.fetch_all("""
            SELECT id FROM devices WHERE is_active = true LIMIT 2
        """)
        if len(devices) < 2:
            pytest.skip("Need at least 2 devices for formula test")
        formula = f"{devices[0]['id']}+{devices[1]['id']}"
        result = await wages_data.get_wages_data(
            formula=formula,
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_subtraction_formula(self, db_pool):
        """Difference between devices."""
        from pfn_mcp import db as db_module
        devices = await db_module.fetch_all("""
            SELECT id FROM devices WHERE is_active = true LIMIT 2
        """)
        if len(devices) < 2:
            pytest.skip("Need at least 2 devices for formula test")
        formula = f"{devices[0]['id']}-{devices[1]['id']}"
        result = await wages_data.get_wages_data(
            formula=formula,
            period="7d"
        )
        assert isinstance(result, dict)
        # Negative results are valid for difference formulas

    @pytest.mark.asyncio
    async def test_grouped_formula(self, db_pool):
        """Parenthesized formula."""
        from pfn_mcp import db as db_module
        devices = await db_module.fetch_all("""
            SELECT id FROM devices WHERE is_active = true LIMIT 3
        """)
        if len(devices) < 3:
            pytest.skip("Need at least 3 devices for grouped formula test")
        formula = f"({devices[0]['id']}+{devices[1]['id']})-({devices[2]['id']})"
        result = await wages_data.get_wages_data(
            formula=formula,
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_invalid_formula_device(self, db_pool):
        """Invalid device ID in formula."""
        result = await wages_data.get_wages_data(
            formula="999999",  # Nonexistent device
            period="7d"
        )
        assert isinstance(result, dict)
        # Should return error about device not found
        assert "error" in result


class TestAggregationMethods:
    """Aggregation method tests (replaces get_peak_analysis)."""

    @pytest.mark.asyncio
    async def test_max_aggregation(self, db_pool, sample_device, power_quantity_id):
        """MAX aggregation (replaces get_peak_analysis)."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            agg_method="max",
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_avg_aggregation(self, db_pool, sample_device, power_quantity_id):
        """AVG aggregation for instantaneous quantities."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            agg_method="avg",
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_min_aggregation(self, db_pool, sample_device, power_quantity_id):
        """MIN aggregation."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            agg_method="min",
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_sum_aggregation(self, db_pool, sample_device):
        """SUM aggregation (default for energy)."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            agg_method="sum",
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_group_peak(self, db_pool, sample_tag, power_quantity_id):
        """MAX aggregation on group."""
        if sample_tag is None:
            pytest.skip("No tags available")
        result = await wages_data.get_wages_data(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_id=power_quantity_id,
            agg_method="max",
            period="7d"
        )
        assert isinstance(result, dict)


class TestBreakdowns:
    """Breakdown option tests."""

    @pytest.mark.asyncio
    async def test_daily_breakdown(self, db_pool, sample_device):
        """Daily breakdown."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            breakdown="daily"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_shift_breakdown(self, db_pool, sample_device):
        """SHIFT1/2/3 breakdown."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            breakdown="shift"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_rate_breakdown(self, db_pool, sample_device):
        """WBP/LWBP rate breakdown."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            breakdown="rate"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_device_breakdown(self, db_pool, sample_tag):
        """Per-device breakdown in group."""
        if sample_tag is None:
            pytest.skip("No tags available")
        result = await wages_data.get_wages_data(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d",
            breakdown="device"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_shift_rate_breakdown(self, db_pool, sample_device):
        """Combined shift and rate breakdown."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            breakdown="shift_rate"
        )
        assert isinstance(result, dict)


class TestOutputFormats:
    """Output format option tests."""

    @pytest.mark.asyncio
    async def test_summary_output(self, db_pool, sample_device):
        """Default summary output."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            output="summary"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_timeseries_output(self, db_pool, sample_device):
        """Timeseries output format."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d",
            output="timeseries"
        )
        assert isinstance(result, dict)


class TestQuantitySelection:
    """Quantity-specific queries."""

    @pytest.mark.asyncio
    async def test_default_energy_cost(self, db_pool, sample_device):
        """Default: electricity/energy from daily_energy_cost_summary."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_quantity_search(self, db_pool, sample_device):
        """Query specific quantity by search."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            quantity_search="power",
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_quantity_by_id(self, db_pool, sample_device, power_quantity_id):
        """Query by specific quantity ID."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            quantity_id=power_quantity_id,
            period="7d"
        )
        assert isinstance(result, dict)


class TestPeriodFormats:
    """Time period format tests."""

    @pytest.mark.asyncio
    async def test_relative_days(self, db_pool, sample_device):
        """Relative period: 7d."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_relative_month(self, db_pool, sample_device):
        """Relative period: 1M."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="1M"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_specific_month(self, db_pool, sample_device):
        """Specific month: 2025-12."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="2025-12"
        )
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_explicit_dates(self, db_pool, sample_device):
        """Explicit start/end dates."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            start_date="2025-12-01",
            end_date="2025-12-15"
        )
        assert isinstance(result, dict)


class TestEdgeCases:
    """Edge cases and error handling."""

    @pytest.mark.asyncio
    async def test_mixed_scope_error(self, db_pool, sample_device, sample_tag):
        """Error when multiple scopes provided."""
        if sample_tag is None:
            pytest.skip("No tags available")
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            tag_key=sample_tag["tag_key"],  # Can't use both
            period="7d"
        )
        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_no_scope_error(self, db_pool):
        """Error when no scope provided."""
        result = await wages_data.get_wages_data(
            period="7d"
        )
        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_out_of_retention_range(self, db_pool, sample_device):
        """Handle dates outside retention."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            start_date="2020-01-01",
            end_date="2020-01-07"
        )
        # Should return empty or error gracefully
        assert isinstance(result, dict)

    @pytest.mark.asyncio
    async def test_nonexistent_device(self, db_pool):
        """Query for nonexistent device."""
        result = await wages_data.get_wages_data(
            device_id=999999999,
            period="7d"
        )
        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_invalid_period_format(self, db_pool, sample_device):
        """Invalid period format."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="invalid"
        )
        assert isinstance(result, dict)
        # Should handle gracefully

    @pytest.mark.asyncio
    async def test_aggregation_requires_tenant(self, db_pool):
        """Aggregation requires tenant parameter."""
        result = await wages_data.get_wages_data(
            aggregation="facility",  # No tenant provided
            period="7d"
        )
        assert isinstance(result, dict)
        assert "error" in result


class TestResponseFormatting:
    """Test response formatter."""

    @pytest.mark.asyncio
    async def test_format_wages_data_response(self, db_pool, sample_device):
        """Test format_wages_data_response function."""
        result = await wages_data.get_wages_data(
            device_id=sample_device["id"],
            period="7d"
        )
        response = wages_data.format_wages_data_response(result)
        assert isinstance(response, str)
        assert len(response) > 0

    @pytest.mark.asyncio
    async def test_format_error_response(self):
        """Test formatting error response."""
        error_result = {"error": "Test error message"}
        response = wages_data.format_wages_data_response(error_result)
        assert isinstance(response, str)
        assert "error" in response.lower() or "Error" in response
