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

from pathlib import Path

PROMPTS_DIR = Path(__file__).parent


def load_core_prompt() -> str:
    """Load the core identity and rules prompt."""
    return (PROMPTS_DIR / "core.md").read_text()


def load_workflows_prompt() -> str:
    """Load the slash command workflows prompt."""
    return (PROMPTS_DIR / "workflows.md").read_text()


def load_full_prompt(tenant: str = "[TENANT_NAME]") -> str:
    """Load the complete prompt with tenant context.

    Args:
        tenant: Tenant name to inject into the prompt.

    Returns:
        Combined prompt string with tenant placeholder replaced.
    """
    core = load_core_prompt()
    workflows = load_workflows_prompt()

    combined = f"{core}\n\n---\n\n{workflows}"
    return combined.replace("[TENANT_NAME]", tenant).replace("[TENANT]", tenant)


__all__ = [
    "load_core_prompt",
    "load_workflows_prompt",
    "load_full_prompt",
    "PROMPTS_DIR",
]
