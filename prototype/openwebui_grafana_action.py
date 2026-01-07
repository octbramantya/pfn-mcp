"""
title: Open Grafana
description: Quick link to open Grafana dashboards in a new tab
author: PFN Team
author_url: https://forsanusa.id
version: 0.1.0
license: MIT
icon_url: data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI0Y0NjgwMCIgZD0iTTIyIDEyYzAtNS41Mi00LjQ4LTEwLTEwLTEwUzIgNi40OCAyIDEyczQuNDggMTAgMTAgMTAgMTAtNC40OCAxMC0xMHptLTEwIDhhOCA4IDAgMSAxIDAtMTYgOCA4IDAgMCAxIDAgMTZ6bTAtMTRjLTMuMzEgMC02IDIuNjktNiA2czIuNjkgNiA2IDYgNi0yLjY5IDYtNi0yLjY5LTYtNi02em0wIDEwYy0yLjIxIDAtNC0xLjc5LTQtNHMxLjc5LTQgNC00IDQgMS43OSA0IDQtMS43OSA0LTQgNHptMC02Yy0xLjEgMC0yIC45LTIgMnMuOSAyIDIgMiAyLS45IDItMi0uOS0yLTItMnoiLz48L3N2Zz4=

INSTALLATION:
1. Open WebUI Admin → Workspace → Functions → Add Function
2. Set type to "Action"
3. Paste this entire file
4. Save and enable

USAGE:
- Button appears in message response toolbar
- Click to open Grafana in new tab
- SSO preserved via Keycloak session
"""

from pydantic import BaseModel, Field


class Action:
    """Open Grafana action - quick link to dashboards."""

    class Valves(BaseModel):
        """Admin configuration."""
        GRAFANA_URL: str = Field(
            default="https://viz.forsanusa.id/graf",
            description="Grafana dashboard URL"
        )

    def __init__(self):
        self.valves = self.Valves()

    async def action(
        self,
        body: dict,
        __user__: dict = None,
        __event_emitter__=None,
        __event_call__=None,
    ) -> None:
        """
        Open Grafana dashboard in a new tab.

        This action emits a status message with a clickable link.
        The user's Keycloak session is preserved, enabling SSO.
        """
        grafana_url = self.valves.GRAFANA_URL

        if __event_emitter__:
            await __event_emitter__(
                {
                    "type": "status",
                    "data": {
                        "description": f"Opening Grafana...",
                        "done": False,
                    },
                }
            )

            # Emit clickable link
            await __event_emitter__(
                {
                    "type": "message",
                    "data": {
                        "content": f"**[Click here to open Grafana Dashboard]({grafana_url})**\n\n_Opens in a new tab. You'll be logged in automatically via Keycloak SSO._"
                    },
                }
            )

            await __event_emitter__(
                {
                    "type": "status",
                    "data": {
                        "description": "Link ready",
                        "done": True,
                    },
                }
            )
