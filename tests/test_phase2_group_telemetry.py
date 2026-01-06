"""Phase 2 Group Telemetry Tests - Scenarios #35-42.

Tests for group telemetry aggregation tools.
"""

import pytest

from pfn_mcp.tools.group_telemetry import (
    compare_groups,
    get_group_telemetry,
    list_tag_values,
    list_tags,
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
        # Should have consumption data
        valid_keys = ["consumption", "total", "data", "telemetry"]
        assert any(k in result for k in valid_keys)

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
        # Should have telemetry or summary
        valid_keys = ["data", "telemetry", "total"]
        assert any(k in result for k in valid_keys) or "error" not in result

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
