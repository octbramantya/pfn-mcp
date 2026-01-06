"""Unit tests for datetime handling in Phase 2 tools.

These tests verify that datetime operations don't fail with
timezone-related errors.
"""

import pytest
from datetime import datetime, timedelta, UTC

from pfn_mcp.tools.datetime_utils import ensure_utc, utc_now, start_of_day_utc
from pfn_mcp.tools.electricity_cost import parse_period


class TestEnsureUtc:
    """Tests for ensure_utc helper."""

    def test_none_returns_none(self):
        assert ensure_utc(None) is None

    def test_naive_datetime_gets_utc(self):
        naive = datetime(2025, 12, 1, 10, 30, 0)
        result = ensure_utc(naive)
        assert result.tzinfo is not None
        assert result.tzinfo == UTC

    def test_aware_datetime_preserved(self):
        aware = datetime(2025, 12, 1, 10, 30, 0, tzinfo=UTC)
        result = ensure_utc(aware)
        assert result.tzinfo == UTC
        assert result == aware


class TestParsePeriod:
    """Tests for parse_period datetime handling.

    Note: parse_period returns naive UTC datetimes for asyncpg/PostgreSQL
    compatibility with timestamp without timezone columns.
    """

    def test_relative_days_returns_naive_utc(self):
        """parse_period('7d') should return naive UTC datetimes."""
        result = parse_period("7d", None, None)
        assert result[0] is not None
        start, end = result
        # Should be naive (no tzinfo) for database compatibility
        assert start.tzinfo is None
        assert end.tzinfo is None

    def test_relative_months_returns_naive_utc(self):
        """parse_period('1M') should return naive UTC datetimes."""
        result = parse_period("1M", None, None)
        assert result[0] is not None
        start, end = result
        assert start.tzinfo is None
        assert end.tzinfo is None

    def test_month_period_returns_naive_utc(self):
        """parse_period('2025-12') should return naive UTC datetimes."""
        result = parse_period("2025-12", None, None)
        assert result[0] is not None
        start, end = result
        assert start.tzinfo is None
        assert end.tzinfo is None

    def test_explicit_dates_returns_naive_utc(self):
        """parse_period with explicit dates should return naive UTC datetimes."""
        result = parse_period(None, "2025-12-01", "2025-12-15")
        assert result[0] is not None
        start, end = result
        assert start.tzinfo is None
        assert end.tzinfo is None

    def test_date_range_returns_naive_utc(self):
        """parse_period('2025-12-01 to 2025-12-15') should return naive UTC datetimes."""
        result = parse_period("2025-12-01 to 2025-12-15", None, None)
        assert result[0] is not None
        start, end = result
        assert start.tzinfo is None
        assert end.tzinfo is None


class TestDatetimeSubtraction:
    """Tests for datetime subtraction operations."""

    def test_aware_minus_aware_works(self):
        """Subtracting two aware datetimes should work."""
        dt1 = datetime(2025, 12, 1, 10, 0, 0, tzinfo=UTC)
        dt2 = datetime(2025, 12, 8, 10, 0, 0, tzinfo=UTC)
        diff = dt2 - dt1
        assert diff == timedelta(days=7)

    def test_naive_minus_naive_works(self):
        """Subtracting two naive datetimes should work."""
        dt1 = datetime(2025, 12, 1, 10, 0, 0)
        dt2 = datetime(2025, 12, 8, 10, 0, 0)
        diff = dt2 - dt1
        assert diff == timedelta(days=7)

    def test_mixed_fails_without_conversion(self):
        """Subtracting naive from aware should fail."""
        aware = datetime(2025, 12, 1, 10, 0, 0, tzinfo=UTC)
        naive = datetime(2025, 12, 8, 10, 0, 0)
        with pytest.raises(TypeError, match="offset-naive and offset-aware"):
            _ = naive - aware

    def test_mixed_works_with_ensure_utc(self):
        """Using ensure_utc should fix mixed datetime subtraction."""
        aware = datetime(2025, 12, 1, 10, 0, 0, tzinfo=UTC)
        naive = datetime(2025, 12, 8, 10, 0, 0)
        # This would fail without ensure_utc
        naive_fixed = ensure_utc(naive)
        diff = naive_fixed - aware
        assert diff == timedelta(days=7)


class TestToNaiveUtc:
    """Tests for to_naive_utc helper."""

    def test_none_returns_none(self):
        from pfn_mcp.tools.datetime_utils import to_naive_utc
        assert to_naive_utc(None) is None

    def test_aware_datetime_stripped(self):
        from pfn_mcp.tools.datetime_utils import to_naive_utc
        aware = datetime(2025, 12, 1, 10, 30, 0, tzinfo=UTC)
        result = to_naive_utc(aware)
        assert result.tzinfo is None
        assert result == datetime(2025, 12, 1, 10, 30, 0)

    def test_naive_datetime_unchanged(self):
        from pfn_mcp.tools.datetime_utils import to_naive_utc
        naive = datetime(2025, 12, 1, 10, 30, 0)
        result = to_naive_utc(naive)
        assert result == naive


class TestSafeDatetimeDiff:
    """Tests for safe_datetime_diff helper."""

    def test_aware_minus_aware(self):
        from pfn_mcp.tools.datetime_utils import safe_datetime_diff
        dt1 = datetime(2025, 12, 1, 10, 0, 0, tzinfo=UTC)
        dt2 = datetime(2025, 12, 8, 10, 0, 0, tzinfo=UTC)
        diff = safe_datetime_diff(dt1, dt2)
        assert diff == timedelta(days=7)

    def test_naive_minus_naive(self):
        from pfn_mcp.tools.datetime_utils import safe_datetime_diff
        dt1 = datetime(2025, 12, 1, 10, 0, 0)
        dt2 = datetime(2025, 12, 8, 10, 0, 0)
        diff = safe_datetime_diff(dt1, dt2)
        assert diff == timedelta(days=7)

    def test_mixed_works(self):
        """Mixed naive/aware should work with safe_datetime_diff."""
        from pfn_mcp.tools.datetime_utils import safe_datetime_diff
        aware = datetime(2025, 12, 1, 10, 0, 0, tzinfo=UTC)
        naive = datetime(2025, 12, 8, 10, 0, 0)
        diff = safe_datetime_diff(aware, naive)
        assert diff == timedelta(days=7)


class TestTimeRangeCalculation:
    """Tests for time range calculations used in Phase 2 tools."""

    def test_time_range_from_parse_period(self):
        """Time range calculation should work with parse_period results."""
        result = parse_period("7d", None, None)
        assert result[0] is not None
        start, end = result
        time_range = end - start
        # Should be approximately 7 days + 1 day (end of today)
        assert time_range.days >= 7
        assert time_range.days <= 9  # Allow some flexibility for timing

    def test_time_range_total_seconds(self):
        """total_seconds() should work on time range."""
        result = parse_period("24h", None, None)
        # 24h is not supported, should return error or use default
        if result[0] is None:
            # parse_period uses 'd' for days, not 'h' for hours
            pytest.skip("24h format not supported in parse_period")
        start, end = result
        time_range = end - start
        hours = time_range.total_seconds() / 3600
        assert hours > 0
