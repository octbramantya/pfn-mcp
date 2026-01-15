"""PFN MCP System Prompts.

This module provides utilities for loading and managing system prompts
for the PFN Energy Intelligence Assistant.

Prompt files:
- core.md: Static identity, rules, and context
- workflows.md: Slash command definitions

Usage:
    from pfn_mcp.prompts import load_core_prompt, load_workflows_prompt, load_full_prompt

    # Load individual sections
    core = load_core_prompt()
    workflows = load_workflows_prompt()

    # Load combined prompt
    full = load_full_prompt(tenant="PRS")
"""

from datetime import datetime, timedelta, timezone
from pathlib import Path

PROMPTS_DIR = Path(__file__).parent

# UTC+7 timezone (WIB - Western Indonesia Time)
WIB = timezone(timedelta(hours=7))


def load_core_prompt() -> str:
    """Load the core identity and rules prompt."""
    return (PROMPTS_DIR / "core.md").read_text()


def load_workflows_prompt() -> str:
    """Load the slash command workflows prompt."""
    return (PROMPTS_DIR / "workflows.md").read_text()


def get_current_datetime_context() -> dict:
    """Get current date/time context for prompt injection.

    Returns:
        Dict with formatted date strings for prompt substitution.
    """
    now = datetime.now(WIB)
    yesterday = now - timedelta(days=1)
    day_before = now - timedelta(days=2)

    return {
        "current_datetime": now.strftime("%Y-%m-%d %H:%M WIB"),
        "current_date": now.strftime("%Y-%m-%d"),
        "current_day": now.strftime("%A"),  # e.g., "Wednesday"
        "yesterday_date": yesterday.strftime("%Y-%m-%d"),
        "yesterday_day": yesterday.strftime("%A"),
        "day_before_yesterday": day_before.strftime("%Y-%m-%d"),
    }


def load_full_prompt(tenant: str = "[TENANT_NAME]") -> str:
    """Load the complete prompt with tenant and datetime context.

    Args:
        tenant: Tenant name to inject into the prompt.

    Returns:
        Combined prompt string with placeholders replaced.
    """
    core = load_core_prompt()
    workflows = load_workflows_prompt()

    combined = f"{core}\n\n---\n\n{workflows}"

    # Replace tenant placeholders
    combined = combined.replace("[TENANT_NAME]", tenant).replace("[TENANT]", tenant)

    # Inject current datetime context
    dt_context = get_current_datetime_context()
    combined = combined.replace("[CURRENT_DATETIME]", dt_context["current_datetime"])
    combined = combined.replace("[CURRENT_DATE]", dt_context["current_date"])
    combined = combined.replace("[CURRENT_DAY]", dt_context["current_day"])
    combined = combined.replace("[YESTERDAY_DATE]", dt_context["yesterday_date"])
    combined = combined.replace("[YESTERDAY_DAY]", dt_context["yesterday_day"])
    combined = combined.replace("[DAY_BEFORE_YESTERDAY]", dt_context["day_before_yesterday"])

    return combined


__all__ = [
    "load_core_prompt",
    "load_workflows_prompt",
    "load_full_prompt",
    "get_current_datetime_context",
    "PROMPTS_DIR",
    "WIB",
]
