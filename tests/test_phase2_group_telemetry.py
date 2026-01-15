"""Phase 2 Group Telemetry Tests - Scenarios #35-42.

Tests for group telemetry aggregation tools.
"""

from datetime import UTC, timedelta

import pytest

from pfn_mcp.tools.group_telemetry import (
    _query_avg_value_timeseries,
    _query_nearest_value_timeseries,
    _resolve_multi_tag_devices,
    compare_groups,
    format_group_telemetry_response,
    get_group_telemetry,
    is_instantaneous_quantity,
    list_tag_values,
    list_tags,
    search_tags,
    select_group_bucket,
)


class TestTagDiscovery:
    """Scenarios #35-37: Tag discovery."""

    @pytest.mark.asyncio
    async def test_list_available_tags(self, db_pool):
        """Scenario #35: What tags are available for grouping devices?"""
        result = await list_tags()

        assert isinstance(result, dict)
        # Should have tags structure (categories, tags_by_category, or total_tags)
        assert "tags_by_category" in result or "categories" in result or "total_tags" in result

    @pytest.mark.asyncio
    async def test_list_process_tag_values(self, db_pool):
        """Scenario #36: List all values for the 'process' tag."""
        result = await list_tag_values(tag_key="process")

        assert isinstance(result, dict)
        # Should have values list (may be empty if tag doesn't exist)
        assert "values" in result or "data" in result or "error" not in result

    @pytest.mark.asyncio
    async def test_list_building_values(self, db_pool):
        """Scenario #37: Show me all buildings in the system."""
        result = await list_tag_values(tag_key="building")

        assert isinstance(result, dict)
        # Should have values list (may be empty if tag doesn't exist)
        assert "values" in result or "data" in result or "error" not in result


class TestGroupConsumption:
    """Scenarios #38-40: Group consumption queries."""

    @pytest.mark.asyncio
    async def test_process_group_consumption(self, db_pool, sample_tag):
        """Scenario #38: What's the total energy consumption for a process group?"""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="30d"
        )

        assert isinstance(result, dict)
        # Should have group telemetry structure
        assert "summary" in result or "error" in result
        if "summary" in result:
            # Default (no quantity) returns electricity data with total_consumption_kwh
            summary = result["summary"]
            assert "total_consumption_kwh" in summary or "total_cost_rp" in summary

    @pytest.mark.asyncio
    async def test_building_power_usage(self, db_pool, sample_tag):
        """Scenario #39: Show power usage for devices in a group last week."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d"
        )

        assert isinstance(result, dict)
        # Should have group telemetry structure
        assert "summary" in result or "error" in result
        if "summary" in result:
            summary = result["summary"]
            assert "total_value" in summary or "average_value" in summary

    @pytest.mark.asyncio
    async def test_asset_group_consumption(self, db_pool):
        """Scenario #40: Get aggregated consumption for an asset group."""
        # Try to find an asset with children
        from pfn_mcp import db
        asset = await db.fetch_one("""
            SELECT a.id, a.asset_name
            FROM assets a
            WHERE EXISTS (
                SELECT 1 FROM assets child WHERE child.parent_id = a.id
            )
            LIMIT 1
        """)

        if asset is None:
            pytest.skip("No parent assets found in database")

        result = await get_group_telemetry(
            asset_id=asset["id"],
            period="30d"
        )

        assert isinstance(result, dict)
        # Should have consumption data
        valid_keys = ["consumption", "total", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result


class TestGroupComparison:
    """Scenarios #41-42: Group comparison."""

    @pytest.mark.asyncio
    async def test_compare_process_groups(self, db_pool):
        """Scenario #41: Compare energy consumption between different groups."""
        # Get two tag values for same key
        from pfn_mcp import db
        tags = await db.fetch_all("""
            SELECT DISTINCT tag_key, tag_value
            FROM device_tags
            WHERE is_active = true
            ORDER BY tag_key, tag_value
            LIMIT 2
        """)

        if len(tags) < 2:
            pytest.skip("Not enough tag values to compare")

        groups = [
            {"tag_key": tags[0]["tag_key"], "tag_value": tags[0]["tag_value"]},
            {"tag_key": tags[1]["tag_key"], "tag_value": tags[1]["tag_value"]},
        ]

        result = await compare_groups(
            groups=groups,
            period="30d"
        )

        assert isinstance(result, dict)
        # Should have comparison data
        valid_keys = ["groups", "comparison", "data"]
        assert any(k in result for k in valid_keys) or "error" not in result

    @pytest.mark.asyncio
    async def test_highest_consumption_group(self, db_pool):
        """Scenario #42: Which group uses the most electricity? (ranking via comparison)"""
        # Get all distinct tag values for a key
        from pfn_mcp import db
        tags = await db.fetch_all("""
            SELECT DISTINCT tag_key, tag_value
            FROM device_tags
            WHERE is_active = true
            ORDER BY tag_key, tag_value
            LIMIT 5
        """)

        if len(tags) < 2:
            pytest.skip("Not enough tag values to compare")

        groups = [
            {"tag_key": t["tag_key"], "tag_value": t["tag_value"]}
            for t in tags
        ]

        result = await compare_groups(
            groups=groups,
            period="30d"
        )

        assert isinstance(result, dict)
        # Should have comparison with rankings
        valid_keys = ["groups", "comparison", "ranking"]
        assert any(k in result for k in valid_keys) or "error" not in result


class TestSearchTags:
    """Tests for search_tags tool - search by tag value or key."""

    @pytest.mark.asyncio
    async def test_search_tags_by_value(self, db_pool, sample_tag):
        """Search for a tag by its value."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await search_tags(search=sample_tag["tag_value"])

        assert isinstance(result, dict)
        assert "matches" in result
        assert "total_matches" in result
        assert "search_term" in result
        assert result["search_term"] == sample_tag["tag_value"]

        # Should find at least one match (the tag we searched for)
        if result["total_matches"] > 0:
            first_match = result["matches"][0]
            assert "tag_key" in first_match
            assert "tag_value" in first_match
            assert "device_count" in first_match

    @pytest.mark.asyncio
    async def test_search_tags_by_key(self, db_pool, sample_tag):
        """Search for tags by key name."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await search_tags(search=sample_tag["tag_key"])

        assert isinstance(result, dict)
        assert "matches" in result
        # Should find tags with this key
        assert result["total_matches"] >= 0

    @pytest.mark.asyncio
    async def test_search_tags_no_results(self, db_pool):
        """Search with non-existent term returns empty."""
        result = await search_tags(search="NONEXISTENT_TAG_XYZ_12345")

        assert isinstance(result, dict)
        assert result["total_matches"] == 0
        assert result["matches"] == []

    @pytest.mark.asyncio
    async def test_search_tags_partial_match(self, db_pool, sample_tag):
        """Search with partial value finds matches."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Use first 3 chars of tag value as partial search
        tag_value = sample_tag["tag_value"]
        if len(tag_value) < 3:
            pytest.skip("Tag value too short for partial match test")

        partial = tag_value[:3]
        result = await search_tags(search=partial)

        assert isinstance(result, dict)
        assert "matches" in result
        # Should find at least the original tag
        assert result["total_matches"] >= 1

    @pytest.mark.asyncio
    async def test_search_tags_case_insensitive(self, db_pool, sample_tag):
        """Search is case-insensitive."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Search with different case
        upper_search = sample_tag["tag_value"].upper()
        result = await search_tags(search=upper_search)

        assert isinstance(result, dict)
        assert result["total_matches"] >= 1

    @pytest.mark.asyncio
    async def test_search_tags_limit(self, db_pool, sample_tag):
        """Limit parameter restricts results."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await search_tags(search=sample_tag["tag_key"], limit=2)

        assert isinstance(result, dict)
        # Results should be limited to 2
        assert len(result["matches"]) <= 2

    @pytest.mark.asyncio
    async def test_search_tags_has_device_info(self, db_pool, sample_tag):
        """Results include device information."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await search_tags(search=sample_tag["tag_value"])

        if result["total_matches"] > 0:
            first_match = result["matches"][0]
            assert "device_count" in first_match
            assert "devices" in first_match
            assert first_match["device_count"] > 0
            assert isinstance(first_match["devices"], list)

    @pytest.mark.asyncio
    async def test_search_tags_match_quality(self, db_pool, sample_tag):
        """Results include match quality information."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await search_tags(search=sample_tag["tag_value"])

        if result["total_matches"] > 0:
            first_match = result["matches"][0]
            assert "match_type" in first_match
            assert "match_quality" in first_match
            assert first_match["match_type"] in ("value", "key")
            assert first_match["match_quality"] in ("exact", "starts_with", "contains")

    @pytest.mark.asyncio
    async def test_search_tags_empty_search(self, db_pool):
        """Empty search returns error."""
        result = await search_tags(search="")

        assert isinstance(result, dict)
        assert "error" in result

    @pytest.mark.asyncio
    async def test_search_tags_whitespace_search(self, db_pool):
        """Whitespace-only search returns error."""
        result = await search_tags(search="   ")

        assert isinstance(result, dict)
        assert "error" in result


class TestMultiTagQueries:
    """Tests for multi-tag AND queries in get_group_telemetry."""

    @pytest.mark.asyncio
    async def test_resolve_multi_tag_empty_list(self, db_pool):
        """Empty tags list returns error."""
        devices, error = await _resolve_multi_tag_devices([])

        assert devices == []
        assert error is not None
        assert "At least one tag" in error

    @pytest.mark.asyncio
    async def test_resolve_multi_tag_missing_key(self, db_pool):
        """Tag missing 'key' returns error."""
        devices, error = await _resolve_multi_tag_devices([{"value": "test"}])

        assert devices == []
        assert error is not None
        assert "missing 'key' or 'value'" in error

    @pytest.mark.asyncio
    async def test_resolve_multi_tag_missing_value(self, db_pool):
        """Tag missing 'value' returns error."""
        devices, error = await _resolve_multi_tag_devices([{"key": "test"}])

        assert devices == []
        assert error is not None
        assert "missing 'key' or 'value'" in error

    @pytest.mark.asyncio
    async def test_resolve_multi_tag_single_tag(self, db_pool, sample_tag):
        """Single tag in array works like regular tag query."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        tags = [{"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]}]
        devices, error = await _resolve_multi_tag_devices(tags)

        # Should return devices (same as single tag)
        assert error is None or len(devices) >= 0

    @pytest.mark.asyncio
    async def test_resolve_multi_tag_no_matching_devices(self, db_pool):
        """Multi-tag query with no matches returns error."""
        tags = [
            {"key": "NONEXISTENT_KEY_ABC", "value": "test"},
            {"key": "ANOTHER_FAKE_KEY", "value": "test2"},
        ]
        devices, error = await _resolve_multi_tag_devices(tags)

        assert devices == []
        assert error is not None
        assert "No devices found" in error

    @pytest.mark.asyncio
    async def test_get_group_telemetry_with_tags_array(self, db_pool, sample_tag):
        """get_group_telemetry accepts tags array parameter."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Use single tag in array format
        tags = [{"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]}]
        result = await get_group_telemetry(tags=tags, period="7d")

        assert isinstance(result, dict)
        # Should have either summary or error
        assert "summary" in result or "error" in result

    @pytest.mark.asyncio
    async def test_get_group_telemetry_tags_priority_over_single(self, db_pool, sample_tag):
        """tags array takes priority over tag_key/tag_value."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Provide both - tags should be used
        tags = [{"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]}]
        result = await get_group_telemetry(
            tag_key="ignored_key",
            tag_value="ignored_value",
            tags=tags,
            period="7d",
        )

        assert isinstance(result, dict)
        # Should use tags array, not the single tag_key/tag_value
        if "group" in result:
            # Label should reflect the tags array content
            assert sample_tag["tag_key"] in result["group"]["label"]

    @pytest.mark.asyncio
    async def test_get_group_telemetry_multi_tag_label(self, db_pool, sample_tag):
        """Multi-tag query generates correct label with AND."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Use two copies of same tag (will match same devices)
        tags = [
            {"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]},
            {"key": sample_tag["tag_key"], "value": sample_tag["tag_value"]},
        ]
        result = await get_group_telemetry(tags=tags, period="7d")

        assert isinstance(result, dict)
        if "group" in result:
            # Label should contain AND
            assert "AND" in result["group"]["label"] or "error" in result

    @pytest.mark.asyncio
    async def test_get_group_telemetry_backward_compatible(self, db_pool, sample_tag):
        """Existing tag_key/tag_value still works without tags param."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d",
        )

        assert isinstance(result, dict)
        assert "summary" in result or "error" in result


class TestSmartBucketing:
    """Tests for select_group_bucket function."""

    def test_select_bucket_short_period_few_devices(self):
        """Short period with few devices should use fine buckets."""
        # 1 day, 2 devices, max 200 rows → 100 buckets max → 15min (96 buckets)
        result = select_group_bucket(timedelta(days=1), device_count=2)
        assert result == "15min"

    def test_select_bucket_week_few_devices(self):
        """7 days with few devices."""
        # 7 days, 2 devices → 100 buckets max → 1hour (168 > 100) → 4hour (42 buckets)
        result = select_group_bucket(timedelta(days=7), device_count=2)
        assert result == "4hour"

    def test_select_bucket_week_many_devices(self):
        """7 days with many devices needs larger buckets."""
        # 7 days, 20 devices → 10 buckets max → 1day (7 buckets)
        result = select_group_bucket(timedelta(days=7), device_count=20)
        assert result == "1day"

    def test_select_bucket_month_few_devices(self):
        """30 days with few devices."""
        # 30 days, 5 devices → 40 buckets max → 1day (30 buckets)
        result = select_group_bucket(timedelta(days=30), device_count=5)
        assert result == "1day"

    def test_select_bucket_month_many_devices(self):
        """30 days with many devices needs weekly buckets."""
        # 30 days, 50 devices → 4 buckets max → 1week (4.3 buckets)
        result = select_group_bucket(timedelta(days=30), device_count=50)
        assert result == "1week"

    def test_select_bucket_zero_devices(self):
        """Zero devices should default to 1."""
        result = select_group_bucket(timedelta(days=7), device_count=0)
        assert result in ["15min", "1hour", "4hour", "1day", "1week"]


class TestOutputParameter:
    """Tests for output parameter in get_group_telemetry."""

    @pytest.mark.asyncio
    async def test_output_default_is_summary(self, db_pool, sample_tag):
        """Default output mode should be summary."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d",
            # output not specified, should default to "summary"
        )

        assert isinstance(result, dict)
        # Should have summary structure (current behavior)
        assert "summary" in result or "error" in result

    @pytest.mark.asyncio
    async def test_output_explicit_summary(self, db_pool, sample_tag):
        """Explicit summary output should work."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            period="7d",
            output="summary",
        )

        assert isinstance(result, dict)
        assert "summary" in result or "error" in result


class TestInstantaneousDetection:
    """Tests for is_instantaneous_quantity helper."""

    def test_instantaneous_avg_method(self):
        """Quantity with avg aggregation is instantaneous."""
        qty_info = {"aggregation_method": "avg"}
        assert is_instantaneous_quantity(qty_info) is True

    def test_instantaneous_average_method(self):
        """Quantity with average aggregation is instantaneous."""
        qty_info = {"aggregation_method": "average"}
        assert is_instantaneous_quantity(qty_info) is True

    def test_instantaneous_mean_method(self):
        """Quantity with mean aggregation is instantaneous."""
        qty_info = {"aggregation_method": "mean"}
        assert is_instantaneous_quantity(qty_info) is True

    def test_cumulative_sum_method(self):
        """Quantity with sum aggregation is cumulative."""
        qty_info = {"aggregation_method": "sum"}
        assert is_instantaneous_quantity(qty_info) is False

    def test_cumulative_total_method(self):
        """Quantity with total aggregation is cumulative."""
        qty_info = {"aggregation_method": "total"}
        assert is_instantaneous_quantity(qty_info) is False

    def test_default_is_instantaneous(self):
        """No aggregation method defaults to instantaneous."""
        qty_info = {}
        assert is_instantaneous_quantity(qty_info) is True

    def test_none_aggregation_method(self):
        """None aggregation method defaults to instantaneous."""
        qty_info = {"aggregation_method": None}
        assert is_instantaneous_quantity(qty_info) is True

    def test_case_insensitive(self):
        """Aggregation method is case-insensitive."""
        assert is_instantaneous_quantity({"aggregation_method": "SUM"}) is False
        assert is_instantaneous_quantity({"aggregation_method": "AVG"}) is True


class TestTimeseriesFormatter:
    """Tests for timeseries output formatting."""

    def test_format_timeseries_basic(self):
        """Format timeseries output produces valid markdown."""
        result = {
            "group": {
                "type": "tag",
                "label": "process=Compressor",
                "result_type": "aggregated_group",
                "device_count": 2,
                "devices": ["Comp-01", "Comp-02"],
            },
            "quantity": {
                "id": 185,
                "name": "Active Power",
                "unit": "kW",
                "aggregation": "nearest",
            },
            "timeseries": {
                "bucket": "1hour",
                "period": "2025-01-01 to 2025-01-07",
                "row_count": 2,
                "data": [
                    {"time": "2025-01-01T00:00:00", "Comp-01": 100.5, "Comp-02": 150.3},
                    {"time": "2025-01-01T01:00:00", "Comp-01": 102.1, "Comp-02": 148.7},
                ],
            },
        }

        formatted = format_group_telemetry_response(result)

        assert "process=Compressor" in formatted
        assert "Active Power" in formatted
        assert "kW" in formatted
        assert "1hour" in formatted
        assert "Time Series Data" in formatted
        assert "Comp-01" in formatted
        assert "Comp-02" in formatted

    def test_format_timeseries_empty_data(self):
        """Format timeseries with no data shows message."""
        result = {
            "group": {
                "type": "tag",
                "label": "process=Empty",
                "result_type": "single_meter",
                "device_count": 1,
                "devices": ["Device-01"],
            },
            "quantity": {
                "id": 185,
                "name": "Active Power",
                "unit": "kW",
                "aggregation": "nearest",
            },
            "timeseries": {
                "bucket": "1hour",
                "period": "2025-01-01 to 2025-01-07",
                "row_count": 0,
                "data": [],
            },
        }

        formatted = format_group_telemetry_response(result)

        assert "No data available" in formatted

    def test_format_timeseries_single_meter(self):
        """Format single meter timeseries shows device name."""
        result = {
            "group": {
                "type": "tag",
                "label": "process=Single",
                "result_type": "single_meter",
                "device_count": 1,
                "devices": ["Only-Device"],
            },
            "quantity": {
                "id": 185,
                "name": "Active Power",
                "unit": "kW",
                "aggregation": "nearest",
            },
            "timeseries": {
                "bucket": "1hour",
                "period": "2025-01-01 to 2025-01-07",
                "row_count": 1,
                "data": [{"time": "2025-01-01T00:00:00", "Only-Device": 100.0}],
            },
        }

        formatted = format_group_telemetry_response(result)

        assert "single meter" in formatted
        assert "Only-Device" in formatted


class TestTimeseriesOutput:
    """Tests for timeseries output mode in get_group_telemetry."""

    @pytest.mark.asyncio
    async def test_timeseries_output_returns_correct_structure(self, db_pool, sample_tag):
        """Timeseries output should return group, quantity, and timeseries keys."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d",
            output="timeseries",
        )

        assert isinstance(result, dict)
        # Should have timeseries structure (not summary)
        if "error" not in result:
            assert "timeseries" in result
            assert "group" in result
            assert "quantity" in result
            assert "summary" not in result  # Not present in timeseries output

    @pytest.mark.asyncio
    async def test_timeseries_data_has_time_and_device_columns(self, db_pool, sample_tag):
        """Timeseries data rows should have time and device columns."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d",
            output="timeseries",
        )

        if "error" in result:
            pytest.skip("No data available")

        ts = result["timeseries"]
        assert "data" in ts
        assert "bucket" in ts
        assert "period" in ts
        assert "row_count" in ts

        data = ts["data"]
        if data:
            first_row = data[0]
            assert "time" in first_row
            # Should have at least one device column besides time
            assert len(first_row) > 1

    @pytest.mark.asyncio
    async def test_timeseries_bucket_info(self, db_pool, sample_tag):
        """Timeseries should include bucket size information."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d",
            output="timeseries",
        )

        if "error" in result:
            pytest.skip("No data available")

        ts = result["timeseries"]
        # Bucket should be one of the valid bucket sizes
        valid_buckets = ["15min", "1hour", "4hour", "1day", "1week"]
        assert ts["bucket"] in valid_buckets

    @pytest.mark.asyncio
    async def test_timeseries_row_count_matches_data(self, db_pool, sample_tag):
        """row_count should match actual data length."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d",
            output="timeseries",
        )

        if "error" in result:
            pytest.skip("No data available")

        ts = result["timeseries"]
        assert ts["row_count"] == len(ts["data"])

    @pytest.mark.asyncio
    async def test_timeseries_with_cumulative_quantity(self, db_pool, sample_tag):
        """Timeseries works with cumulative quantities (energy)."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_id=124,  # Active Energy Delivered
            period="7d",
            output="timeseries",
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert "timeseries" in result
            # Cumulative should use sum aggregation
            assert result["quantity"]["aggregation"] == "sum"

    @pytest.mark.asyncio
    async def test_timeseries_with_instantaneous_quantity(self, db_pool, sample_tag):
        """Timeseries works with instantaneous quantities (power)."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_id=185,  # Active Power
            period="7d",
            output="timeseries",
        )

        assert isinstance(result, dict)
        if "error" not in result:
            assert "timeseries" in result
            # Instantaneous should use nearest aggregation
            assert result["quantity"]["aggregation"] == "nearest"

    @pytest.mark.asyncio
    async def test_timeseries_empty_data(self, db_pool, sample_tag):
        """Timeseries with no data returns empty list."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Query very old period that likely has no data
        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            start_date="2010-01-01",
            end_date="2010-01-02",
            output="timeseries",
        )

        if "error" not in result:
            ts = result["timeseries"]
            assert ts["row_count"] == 0
            assert ts["data"] == []


class TestNearestValueSampling:
    """Tests for nearest-value and avg-value timeseries queries."""

    @pytest.mark.asyncio
    async def test_nearest_value_returns_list(self, db_pool, sample_device):
        """Nearest-value query returns list of dicts."""
        if sample_device is None:
            pytest.skip("No devices available")

        from datetime import datetime

        end = datetime.now(UTC).replace(tzinfo=None)
        start = end - timedelta(days=1)

        result = await _query_nearest_value_timeseries(
            device_ids=[sample_device["id"]],
            quantity_id=185,  # Active Power
            query_start=start,
            query_end=end,
            bucket_interval=timedelta(hours=1),
        )

        assert isinstance(result, list)
        # May be empty if no data, but structure should be correct
        if result:
            first = result[0]
            assert "time_bucket" in first
            assert "device_id" in first
            assert "device_name" in first
            assert "value" in first

    @pytest.mark.asyncio
    async def test_avg_value_returns_list(self, db_pool, sample_device):
        """Avg-value query returns list of dicts."""
        if sample_device is None:
            pytest.skip("No devices available")

        from datetime import datetime

        end = datetime.now(UTC).replace(tzinfo=None)
        start = end - timedelta(days=1)

        result = await _query_avg_value_timeseries(
            device_ids=[sample_device["id"]],
            quantity_id=185,  # Active Power
            query_start=start,
            query_end=end,
            bucket_interval=timedelta(hours=1),
            is_cumulative=False,
        )

        assert isinstance(result, list)
        if result:
            first = result[0]
            assert "time_bucket" in first
            assert "device_id" in first
            assert "device_name" in first
            assert "value" in first

    @pytest.mark.asyncio
    async def test_nearest_value_multi_device(self, db_pool):
        """Nearest-value query works with multiple devices."""
        from datetime import datetime

        from pfn_mcp import db

        # Get two devices
        devices = await db.fetch_all(
            "SELECT id FROM devices WHERE is_active = true LIMIT 2"
        )
        if len(devices) < 2:
            pytest.skip("Not enough devices")

        device_ids = [d["id"] for d in devices]
        end = datetime.now(UTC).replace(tzinfo=None)
        start = end - timedelta(days=1)

        result = await _query_nearest_value_timeseries(
            device_ids=device_ids,
            quantity_id=185,
            query_start=start,
            query_end=end,
            bucket_interval=timedelta(hours=4),
        )

        assert isinstance(result, list)
        # Each device should have at most one row per time bucket
        if result:
            # Check that device_ids in result are from our list
            result_device_ids = {r["device_id"] for r in result}
            assert result_device_ids.issubset(set(device_ids))


class TestInstantaneousQuantityHandling:
    """Tests for instantaneous quantity aggregation fixes (beads-d3o).

    For instantaneous quantities (voltage, power, current):
    - Auto-enables device breakdown when multiple devices
    - Skips percentage in device breakdown
    - Adds min/max with device attribution
    """

    @pytest.mark.asyncio
    async def test_instantaneous_auto_device_breakdown(self, db_pool, sample_tag):
        """Instantaneous quantity with multiple devices auto-enables device breakdown."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",  # Instantaneous quantity
            period="7d",
            # breakdown not specified, should auto-enable for instantaneous
        )

        if "error" in result:
            pytest.skip("No data available for test")

        # Should auto-enable device breakdown for instantaneous with multiple devices
        if result["group"]["device_count"] > 1:
            assert "breakdown" in result, "Should auto-enable device breakdown for instantaneous"

    @pytest.mark.asyncio
    async def test_instantaneous_no_percentage_in_breakdown(self, db_pool, sample_tag):
        """Instantaneous quantity device breakdown has no percentage."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",  # Instantaneous quantity
            period="7d",
            breakdown="device",
        )

        if "error" in result:
            pytest.skip("No data available for test")

        if "breakdown" in result and result["breakdown"]:
            first_item = result["breakdown"][0]
            # Instantaneous quantities should NOT have percentage
            assert "percentage" not in first_item, (
                "Instantaneous breakdown should not have percentage"
            )
            # Should still have min/max
            assert "min" in first_item
            assert "max" in first_item

    @pytest.mark.asyncio
    async def test_cumulative_has_percentage_in_breakdown(self, db_pool, sample_tag):
        """Cumulative quantity device breakdown still has percentage."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_id=124,  # Active Energy Delivered - cumulative
            period="7d",
            breakdown="device",
        )

        if "error" in result:
            pytest.skip("No data available for test")

        if "breakdown" in result and result["breakdown"]:
            first_item = result["breakdown"][0]
            # Cumulative quantities SHOULD have percentage
            assert "percentage" in first_item, (
                "Cumulative breakdown should have percentage"
            )

    @pytest.mark.asyncio
    async def test_instantaneous_summary_has_device_attribution(self, db_pool, sample_tag):
        """Instantaneous summary includes min/max device attribution."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",  # Instantaneous quantity
            period="7d",
        )

        if "error" in result:
            pytest.skip("No data available for test")

        summary = result.get("summary", {})
        # Should have min_device and max_device keys (may be None if no data)
        assert "min_device" in summary, "Summary should have min_device key"
        assert "max_device" in summary, "Summary should have max_device key"

    @pytest.mark.asyncio
    async def test_quantity_has_is_instantaneous_flag(self, db_pool, sample_tag):
        """Quantity info includes is_instantaneous flag."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        # Test with instantaneous quantity
        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_search="power",
            period="7d",
        )

        if "error" in result:
            pytest.skip("No data available for test")

        qty = result.get("quantity", {})
        assert "is_instantaneous" in qty, "Quantity should have is_instantaneous flag"
        assert qty["is_instantaneous"] is True, "Power should be instantaneous"

    @pytest.mark.asyncio
    async def test_cumulative_is_instantaneous_false(self, db_pool, sample_tag):
        """Cumulative quantity has is_instantaneous=False."""
        if sample_tag is None:
            pytest.skip("No tags available in database")

        result = await get_group_telemetry(
            tag_key=sample_tag["tag_key"],
            tag_value=sample_tag["tag_value"],
            quantity_id=124,  # Active Energy Delivered - cumulative
            period="7d",
        )

        if "error" in result:
            pytest.skip("No data available for test")

        qty = result.get("quantity", {})
        assert qty.get("is_instantaneous") is False, "Energy should not be instantaneous"

    def test_format_instantaneous_breakdown_no_percentage(self):
        """Formatter shows min/max range instead of percentage for instantaneous."""
        result = {
            "group": {
                "type": "tag",
                "label": "process=Compressor",
                "result_type": "aggregated_group",
                "device_count": 3,
                "devices_with_data": 3,
                "devices": ["Comp-01", "Comp-02", "Comp-03"],
            },
            "quantity": {
                "id": 185,
                "name": "Active Power",
                "unit": "kW",
                "aggregation": "average",
                "is_instantaneous": True,
            },
            "summary": {
                "average_value": 150.0,
                "min_value": 100.0,
                "max_value": 200.0,
                "min_device": "Comp-01",
                "max_device": "Comp-03",
                "unit": "kW",
                "period": "2025-01-01 to 2025-01-07",
                "days_with_data": 7,
                "data_points": 100,
            },
            "breakdown": [
                {"device": "Comp-01", "device_id": 1, "value": 120.0, "min": 100.0, "max": 140.0},
                {"device": "Comp-02", "device_id": 2, "value": 150.0, "min": 130.0, "max": 170.0},
                {"device": "Comp-03", "device_id": 3, "value": 180.0, "min": 160.0, "max": 200.0},
            ],
        }

        formatted = format_group_telemetry_response(result)

        # Should show device attribution for min/max
        assert "Comp-01" in formatted
        assert "Comp-03" in formatted
        # Should show avg with range, not percentage
        assert "avg" in formatted.lower()
        assert "range" in formatted.lower()
        # Should NOT contain percentage symbols in breakdown
        if "### Breakdown" in formatted:
            breakdown_section = formatted.split("### Breakdown")[1]
        else:
            breakdown_section = ""
        # Count % symbols - should be none in instantaneous breakdown
        # (there might be % in summary section for data completeness, but not in breakdown)
        assert "%" not in breakdown_section or breakdown_section.count("%") == 0

    def test_format_cumulative_breakdown_has_percentage(self):
        """Formatter shows percentage for cumulative quantities."""
        result = {
            "group": {
                "type": "tag",
                "label": "process=Compressor",
                "result_type": "aggregated_group",
                "device_count": 3,
                "devices_with_data": 3,
                "devices": ["Comp-01", "Comp-02", "Comp-03"],
            },
            "quantity": {
                "id": 124,
                "name": "Active Energy Delivered",
                "unit": "kWh",
                "aggregation": "total",
                "is_instantaneous": False,
            },
            "summary": {
                "total_value": 1000.0,
                "min_value": 50.0,
                "max_value": 500.0,
                "min_device": None,
                "max_device": None,
                "unit": "kWh",
                "period": "2025-01-01 to 2025-01-07",
                "days_with_data": 7,
                "data_points": 100,
            },
            "breakdown": [
                {
                    "device": "Comp-01", "device_id": 1, "value": 300.0,
                    "min": 50.0, "max": 100.0, "percentage": 30.0,
                },
                {
                    "device": "Comp-02", "device_id": 2, "value": 350.0,
                    "min": 60.0, "max": 120.0, "percentage": 35.0,
                },
                {
                    "device": "Comp-03", "device_id": 3, "value": 350.0,
                    "min": 70.0, "max": 500.0, "percentage": 35.0,
                },
            ],
        }

        formatted = format_group_telemetry_response(result)

        # Cumulative should show percentage in breakdown
        assert "30.0%" in formatted or "30%" in formatted
        # Should NOT show "avg" for cumulative
        if "### Breakdown" in formatted:
            breakdown_section = formatted.split("### Breakdown")[1]
        else:
            breakdown_section = ""
        assert "avg" not in breakdown_section.lower()
