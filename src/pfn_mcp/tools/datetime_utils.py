"""Datetime utilities for consistent timezone handling.

The database stores timestamps in `timestamp without timezone` columns (UTC).
This module provides helpers to ensure all datetime operations are consistent.
"""

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

from pfn_mcp.config import settings

# User display timezone from config
DISPLAY_TZ = ZoneInfo(settings.display_timezone)


def ensure_utc(dt: datetime | None) -> datetime | None:
    """Ensure datetime is timezone-aware with UTC.

    Handles:
    - Naive datetimes: assumes UTC, adds tzinfo
    - Aware datetimes: converts to UTC if needed
    - None: returns None

    Use this when receiving datetimes from the database.
    """
    if dt is None:
        return None
    if dt.tzinfo is None:
        # Database stores UTC in timestamp without timezone
        return dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def utc_now() -> datetime:
    """Get current time as timezone-aware UTC datetime."""
    return datetime.now(UTC)


def start_of_day_utc(dt: datetime | None = None) -> datetime:
    """Get start of day in UTC.

    Args:
        dt: Optional datetime to get start of day for. Defaults to now.
    """
    if dt is None:
        dt = utc_now()
    elif dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.replace(hour=0, minute=0, second=0, microsecond=0)


def to_display_tz(dt: datetime | None) -> datetime | None:
    """Convert datetime to user display timezone (Asia/Jakarta).

    Use this for formatting datetimes in user-facing output.
    """
    if dt is None:
        return None
    dt = ensure_utc(dt)
    return dt.astimezone(DISPLAY_TZ)


def format_display_datetime(
    dt: datetime | str | None, fmt: str = "%Y-%m-%d %H:%M"
) -> str:
    """Format datetime for user display in configured timezone.

    Args:
        dt: Datetime to format (can be naive UTC, aware, or ISO string)
        fmt: strftime format string

    Returns:
        Formatted string or empty string if dt is None
    """
    if dt is None:
        return ""
    # Handle ISO string input
    if isinstance(dt, str):
        try:
            dt = datetime.fromisoformat(dt.replace("Z", "+00:00"))
        except ValueError:
            return dt  # Return as-is if parsing fails
    display_dt = to_display_tz(dt)
    return display_dt.strftime(fmt) if display_dt else ""


def format_display_date(dt: datetime | str | None) -> str:
    """Format datetime as date for user display."""
    return format_display_datetime(dt, "%Y-%m-%d")


def to_naive_utc(dt: datetime | None) -> datetime | None:
    """Convert datetime to naive UTC for database queries.

    Database columns use `timestamp without timezone` and store UTC.
    This function ensures datetimes are stripped of timezone info
    before being passed to queries, avoiding any asyncpg edge cases.

    Args:
        dt: Datetime to convert (can be naive or aware)

    Returns:
        Naive datetime in UTC, or None if input is None
    """
    if dt is None:
        return None
    if dt.tzinfo is not None:
        # Convert to UTC and strip timezone
        utc_dt = dt.astimezone(UTC)
        return utc_dt.replace(tzinfo=None)
    # Already naive, assume it's UTC
    return dt


def safe_datetime_diff(dt1: datetime, dt2: datetime) -> timedelta:
    """Safely subtract two datetimes, handling mixed timezone awareness.

    Args:
        dt1: First datetime (will be subtracted from dt2)
        dt2: Second datetime

    Returns:
        timedelta representing dt2 - dt1
    """
    # Ensure both are aware with UTC
    dt1_utc = ensure_utc(dt1)
    dt2_utc = ensure_utc(dt2)
    return dt2_utc - dt1_utc
