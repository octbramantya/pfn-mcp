"""Usage tracking and budget management."""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from litellm import get_model_cost_map

from pfn_mcp.db import fetch_one

from .config import chat_settings

logger = logging.getLogger(__name__)

# Cache model costs to avoid repeated lookups
_model_costs: dict | None = None


def _get_model_costs() -> dict:
    """Get model cost map from LiteLLM."""
    global _model_costs
    if _model_costs is None:
        _model_costs = get_model_cost_map("")
    return _model_costs


def get_cost_per_token(model: str) -> tuple[float, float]:
    """
    Get cost per token for a model.

    Args:
        model: Model name (e.g., 'claude-sonnet-4-20250514')

    Returns:
        Tuple of (input_cost_per_token, output_cost_per_token) in USD
    """
    costs = _get_model_costs()

    # Try exact match first
    if model in costs:
        info = costs[model]
        return (
            info.get("input_cost_per_token", 0.0),
            info.get("output_cost_per_token", 0.0),
        )

    # Try partial match (e.g., 'claude-sonnet-4' matches 'claude-sonnet-4-20250514')
    for key, info in costs.items():
        if model in key or key in model:
            return (
                info.get("input_cost_per_token", 0.0),
                info.get("output_cost_per_token", 0.0),
            )

    # Default to Claude Sonnet 4 pricing if model not found
    # $3/1M input, $15/1M output
    logger.warning(f"Model '{model}' not found in cost map, using default pricing")
    return (3e-06, 1.5e-05)


def calculate_cost(
    input_tokens: int,
    output_tokens: int,
    model: str | None = None,
) -> float:
    """
    Calculate cost in USD for token usage.

    Args:
        input_tokens: Number of input tokens
        output_tokens: Number of output tokens
        model: Model name (defaults to configured model)

    Returns:
        Cost in USD
    """
    model = model or chat_settings.llm_model
    input_cost, output_cost = get_cost_per_token(model)
    return (input_tokens * input_cost) + (output_tokens * output_cost)


@dataclass
class UsageStats:
    """Usage statistics for a user."""

    input_tokens: int
    output_tokens: int
    total_tokens: int
    cost_usd: float
    conversation_count: int
    period_start: datetime
    period_end: datetime
    budget_limit_usd: float | None
    budget_used_percent: float | None
    budget_remaining_usd: float | None
    is_over_budget: bool
    is_near_limit: bool


async def get_user_usage(
    user_id: str,
    period: str = "monthly",
) -> UsageStats:
    """
    Get usage statistics for a user.

    Args:
        user_id: Keycloak subject ID
        period: 'monthly', 'daily', or 'all'

    Returns:
        UsageStats with token counts, cost, and budget info
    """
    now = datetime.now(UTC)

    # Calculate period boundaries
    if period == "monthly":
        period_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        # Next month
        if now.month == 12:
            period_end = now.replace(year=now.year + 1, month=1, day=1)
        else:
            period_end = now.replace(month=now.month + 1, day=1)
    elif period == "daily":
        period_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        period_end = period_start + timedelta(days=1)
    else:  # all
        period_start = datetime(2020, 1, 1, tzinfo=UTC)
        period_end = now + timedelta(days=365)

    # Query usage from database
    query = """
        SELECT
            COALESCE(SUM(m.input_tokens), 0) as input_tokens,
            COALESCE(SUM(m.output_tokens), 0) as output_tokens,
            COUNT(DISTINCT c.id) as conversation_count
        FROM mcp.conversations c
        LEFT JOIN mcp.messages m ON m.conversation_id = c.id
        WHERE c.user_id = $1 AND c.created_at >= $2 AND c.created_at < $3
    """
    result = await fetch_one(query, user_id, period_start, period_end)

    input_tokens = result["input_tokens"] or 0
    output_tokens = result["output_tokens"] or 0
    total_tokens = input_tokens + output_tokens
    conversation_count = result["conversation_count"] or 0

    # Calculate cost
    cost_usd = calculate_cost(input_tokens, output_tokens)

    # Get budget info
    budget_limit = chat_settings.budget_monthly_usd
    if budget_limit:
        budget_used_percent = (cost_usd / budget_limit) * 100
        budget_remaining = max(0, budget_limit - cost_usd)
        is_over_budget = cost_usd >= budget_limit
        is_near_limit = budget_used_percent >= chat_settings.budget_warn_percent
    else:
        budget_used_percent = None
        budget_remaining = None
        is_over_budget = False
        is_near_limit = False

    return UsageStats(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
        cost_usd=cost_usd,
        conversation_count=conversation_count,
        period_start=period_start,
        period_end=period_end,
        budget_limit_usd=budget_limit,
        budget_used_percent=budget_used_percent,
        budget_remaining_usd=budget_remaining,
        is_over_budget=is_over_budget,
        is_near_limit=is_near_limit,
    )


async def check_budget(user_id: str) -> tuple[bool, str | None]:
    """
    Check if user is within budget.

    Args:
        user_id: Keycloak subject ID

    Returns:
        Tuple of (is_allowed, error_message)
        - (True, None) if allowed
        - (False, "error message") if blocked
    """
    # If no budget configured, always allow
    if not chat_settings.budget_monthly_usd:
        return True, None

    # If blocking is disabled, always allow
    if not chat_settings.budget_block_percent:
        return True, None

    usage = await get_user_usage(user_id, chat_settings.budget_period)

    if usage.is_over_budget:
        return False, "Monthly budget exceeded. Please contact support."

    if usage.budget_used_percent and usage.budget_used_percent >= (
        chat_settings.budget_block_percent or 100
    ):
        return False, "Monthly budget limit reached. Please contact support."

    return True, None


def format_usage_display(stats: UsageStats) -> str:
    """
    Format usage stats for display (percentage-based, no dollar amounts).

    Args:
        stats: UsageStats object

    Returns:
        Formatted string for display
    """
    lines = []

    # Token usage
    lines.append(f"Tokens used: {stats.total_tokens:,}")
    lines.append(f"  Input: {stats.input_tokens:,}")
    lines.append(f"  Output: {stats.output_tokens:,}")
    lines.append(f"Conversations: {stats.conversation_count}")

    # Budget progress bar (if budget is set)
    if stats.budget_used_percent is not None:
        pct = min(100, stats.budget_used_percent)
        bar_width = 20
        filled = int(pct / 100 * bar_width)
        bar = "█" * filled + "░" * (bar_width - filled)

        lines.append("")
        lines.append(f"Budget: [{bar}] {pct:.1f}%")

        if stats.is_over_budget:
            lines.append("⚠️ Budget exceeded")
        elif stats.is_near_limit:
            lines.append("⚠️ Approaching budget limit")

    return "\n".join(lines)
