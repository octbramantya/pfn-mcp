"""Prompt loader with Anthropic prompt caching support.

Loads modular prompts from markdown files and composes them with
cache_control for optimal token efficiency.

Prompt priority:
1. Markdown files in src/pfn_mcp/prompts/ (core.md, workflows.md)
2. Legacy system_prompt from config (if markdown files not found)
"""

import logging
from functools import lru_cache
from pathlib import Path
from typing import Any

from pfn_mcp.prompts import get_current_datetime_context

from .config import chat_settings

logger = logging.getLogger(__name__)

# Prompt directory
PROMPTS_DIR = Path(__file__).parent.parent / "prompts"


@lru_cache(maxsize=1)
def _load_prompt_file(filename: str) -> str:
    """Load a prompt file from the prompts directory."""
    filepath = PROMPTS_DIR / filename
    if not filepath.exists():
        logger.warning(f"Prompt file not found: {filepath}")
        return ""
    return filepath.read_text(encoding="utf-8")


@lru_cache(maxsize=1)
def get_static_prompt() -> str:
    """
    Load and compose the static (cacheable) portion of the system prompt.

    Priority:
    1. Markdown files: core.md + workflows.md
    2. Legacy system_prompt from config
    3. Minimal fallback

    Returns:
        Combined static prompt string (~1000 tokens)
    """
    core = _load_prompt_file("core.md")
    workflows = _load_prompt_file("workflows.md")

    if not core:
        # Fallback to legacy config system_prompt
        if chat_settings.system_prompt:
            logger.info("Using legacy system_prompt from config")
            return chat_settings.system_prompt

        logger.warning("No prompts found - using minimal fallback")
        return "You are an energy monitoring assistant. Use tools to query data."

    parts = [core]
    if workflows:
        parts.append(workflows)

    return "\n\n".join(parts)


def _replace_date_placeholders(prompt: str) -> str:
    """Replace date placeholders with current values (WIB timezone).

    Placeholders replaced:
    - [CURRENT_DATETIME] -> 2026-01-19 14:30 WIB
    - [CURRENT_DATE] -> 2026-01-19
    - [CURRENT_DAY] -> Sunday
    - [YESTERDAY_DATE] -> 2026-01-18
    - [YESTERDAY_DAY] -> Saturday
    - [DAY_BEFORE_YESTERDAY] -> 2026-01-17
    """
    dt = get_current_datetime_context()
    replacements = {
        "[CURRENT_DATETIME]": dt["current_datetime"],
        "[CURRENT_DATE]": dt["current_date"],
        "[CURRENT_DAY]": dt["current_day"],
        "[YESTERDAY_DATE]": dt["yesterday_date"],
        "[YESTERDAY_DAY]": dt["yesterday_day"],
        "[DAY_BEFORE_YESTERDAY]": dt["day_before_yesterday"],
    }
    for placeholder, value in replacements.items():
        prompt = prompt.replace(placeholder, value)
    return prompt


def build_system_prompt(
    tenant_name: str | None = None,
    enable_cache: bool = True,
) -> list[dict[str, Any]] | str:
    """
    Build the complete system prompt with optional caching.

    Args:
        tenant_name: Current tenant context (injected dynamically)
        enable_cache: Whether to use Anthropic prompt caching

    Returns:
        If enable_cache=True: List of content blocks with cache_control
        If enable_cache=False: Plain string (for compatibility)
    """
    static_prompt = get_static_prompt()

    # Replace date placeholders with current values (runs per-request)
    static_prompt = _replace_date_placeholders(static_prompt)

    if not enable_cache:
        # Simple string format (backwards compatible)
        if tenant_name:
            return f"{static_prompt}\n\nCurrent tenant: {tenant_name}"
        return static_prompt

    # Structured format with cache_control
    blocks: list[dict[str, Any]] = [
        {
            "type": "text",
            "text": static_prompt,
            "cache_control": {"type": "ephemeral"}
        }
    ]

    # Add dynamic tenant context (not cached)
    if tenant_name:
        blocks.append({
            "type": "text",
            "text": f"Current tenant: {tenant_name}"
        })

    return blocks


def clear_prompt_cache() -> None:
    """Clear the prompt cache (useful for development/hot-reload)."""
    _load_prompt_file.cache_clear()
    get_static_prompt.cache_clear()
    logger.info("Prompt cache cleared")
