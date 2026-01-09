"""
title: Check Usage
description: Check your AI usage and remaining budget
author: PFN Team
author_url: https://forsanusa.id
version: 0.1.0
license: MIT

INSTALLATION:
1. Open WebUI Admin -> Workspace -> Functions -> Add Function
2. Set type to "Tool"
3. Paste this entire file
4. Save and enable
5. Configure Valves (LITELLM_URL, LITELLM_MASTER_KEY, TEAM_ID)
6. Enable this tool for your model in Workspace -> Models

USAGE:
- Ask "check my usage" or "how much budget do I have left"
- The tool will show a progress bar of your usage
"""

import json
from urllib.request import urlopen, Request
from urllib.error import HTTPError
from pydantic import BaseModel, Field
from typing import Callable, Awaitable


class Tools:
    """Check AI usage and remaining budget."""

    class Valves(BaseModel):
        """Admin configuration - set these in Open WebUI admin panel."""
        LITELLM_URL: str = Field(
            default="http://localhost:4000",
            description="LiteLLM proxy URL"
        )
        LITELLM_MASTER_KEY: str = Field(
            default="",
            description="LiteLLM master key for querying team info"
        )
        TEAM_ID: str = Field(
            default="",
            description="Team ID for this Open WebUI instance (from team_keys.json)"
        )

    def __init__(self):
        self.valves = self.Valves()

    def _api_call(self, endpoint: str) -> dict:
        """Make API call to LiteLLM proxy."""
        url = f"{self.valves.LITELLM_URL}{endpoint}"
        headers = {
            "Authorization": f"Bearer {self.valves.LITELLM_MASTER_KEY}",
            "Content-Type": "application/json",
        }
        req = Request(url, headers=headers, method="GET")

        try:
            with urlopen(req, timeout=10) as resp:
                return json.loads(resp.read())
        except HTTPError as e:
            error_body = e.read().decode()
            return {"error": error_body, "status_code": e.code}
        except Exception as e:
            return {"error": str(e)}

    def _create_progress_bar(self, percentage: float, width: int = 20) -> str:
        """Create a text-based progress bar."""
        filled = int(width * percentage / 100)
        empty = width - filled
        bar = "█" * filled + "░" * empty
        return f"[{bar}]"

    def _format_usage(self, spend: float, max_budget: float, budget_duration: str) -> str:
        """Format usage display like Claude Code /usage - no dollar values shown."""
        percentage = (spend / max_budget * 100) if max_budget > 0 else 0
        remaining_pct = 100 - percentage

        # Determine status color/emoji based on usage
        if percentage >= 90:
            status = "🔴"
            status_text = "Critical - approaching limit"
        elif percentage >= 75:
            status = "🟡"
            status_text = "High usage"
        elif percentage >= 50:
            status = "🟠"
            status_text = "Moderate usage"
        else:
            status = "🟢"
            status_text = "Good"

        # Format budget duration
        duration_display = {
            "1mo": "monthly",
            "30d": "30-day",
            "7d": "weekly",
            "1d": "daily",
        }.get(budget_duration, budget_duration)

        progress_bar = self._create_progress_bar(percentage)

        output = f"""## AI Usage Status {status}

{progress_bar} **{percentage:.1f}%** of {duration_display} limit used

**{remaining_pct:.1f}%** remaining | Status: {status_text}"""

        if percentage >= 90:
            output += "\n\n⚠️ **Warning:** You're approaching your usage limit. Usage will be blocked when limit is reached."
        elif percentage >= 100:
            output += "\n\n🚫 **Limit reached.** Please contact your administrator."

        return output.strip()

    async def check_usage(
        self,
        __user__: dict = None,
        __event_emitter__: Callable[[dict], Awaitable[None]] = None,
    ) -> str:
        """
        Check your current AI usage and remaining budget.

        Shows a progress bar indicating how much of your monthly budget has been used.

        :return: Usage status with progress bar
        """
        if __event_emitter__:
            await __event_emitter__({
                "type": "status",
                "data": {"description": "Checking usage...", "done": False}
            })

        # Validate configuration
        if not self.valves.LITELLM_MASTER_KEY:
            return "❌ **Configuration Error:** LITELLM_MASTER_KEY not configured. Please contact your administrator."

        if not self.valves.TEAM_ID:
            return "❌ **Configuration Error:** TEAM_ID not configured. Please contact your administrator."

        # Fetch team info
        result = self._api_call(f"/team/info?team_id={self.valves.TEAM_ID}")

        if "error" in result:
            return f"❌ **Error fetching usage:** {result['error']}"

        # Extract team data
        team_info = result.get("team_info", result)
        spend = team_info.get("spend", 0) or 0
        max_budget = team_info.get("max_budget", 0) or 0
        budget_duration = team_info.get("budget_duration", "1mo") or "1mo"
        team_alias = team_info.get("team_alias", "Unknown")

        if __event_emitter__:
            await __event_emitter__({
                "type": "status",
                "data": {"description": "Usage retrieved", "done": True}
            })

        return self._format_usage(spend, max_budget, budget_duration)
