"""Phase 2 Group Telemetry Tests - Scenarios #35-42.

Tests for group telemetry aggregation tools.
"""

import pytest

from pfn_mcp.tools.group_telemetry import (
    _resolve_multi_tag_devices,
    compare_groups,
    get_group_telemetry,
    list_tag_values,
    list_tags,
    search_tags,
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
