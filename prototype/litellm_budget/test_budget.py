#!/usr/bin/env python3
"""
Test script for LiteLLM per-team budget enforcement.

This script:
1. Creates teams matching tenants (PRS, IOP, NAV)
2. Sets budget limits per team
3. Generates API keys for each team
4. Tests budget enforcement (requests should be rejected when exceeded)

Prerequisites:
- LiteLLM proxy running at http://localhost:4000
- LITELLM_MASTER_KEY environment variable set

Usage:
    # Setup teams and keys
    python test_budget.py setup

    # Test budget enforcement (sends requests until budget exceeded)
    python test_budget.py test --team PRS

    # Check team spend
    python test_budget.py status --team PRS

    # Reset team spend (for re-testing)
    python test_budget.py reset --team PRS
"""

import argparse
import json
import os
import sys
from urllib.request import urlopen, Request
from urllib.error import HTTPError

LITELLM_URL = os.environ.get("LITELLM_URL", "http://localhost:4000")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "sk-master-key")

# Tenant configuration (matching Valkyrie tenants)
TENANTS = {
    "PRS": {"name": "PT Rekayasa Sukses", "max_budget": 0.10, "budget_duration": "1d"},
    "IOP": {"name": "PT Inti Optima", "max_budget": 0.10, "budget_duration": "1d"},
    "NAV": {"name": "Navigant", "max_budget": 0.50, "budget_duration": "1d"},
}


def api_call(method: str, endpoint: str, data: dict = None) -> dict:
    """Make API call to LiteLLM proxy."""
    url = f"{LITELLM_URL}{endpoint}"
    headers = {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json",
    }

    body = json.dumps(data).encode() if data else None
    req = Request(url, data=body, headers=headers, method=method)

    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except HTTPError as e:
        error_body = e.read().decode()
        try:
            return {"error": json.loads(error_body), "status_code": e.code}
        except:
            return {"error": error_body, "status_code": e.code}


def setup_teams():
    """Create teams with budget limits."""
    print("\n=== Setting up Teams ===\n")

    created_teams = {}

    for code, config in TENANTS.items():
        print(f"Creating team '{code}' ({config['name']})...")

        result = api_call("POST", "/team/new", {
            "team_alias": code,
            "max_budget": config["max_budget"],
            "budget_duration": config["budget_duration"],
            "metadata": {
                "tenant_name": config["name"],
                "source": "pfn_mcp_prototype"
            }
        })

        if "error" in result:
            print(f"  Error: {result['error']}")
            # Try to get existing team
            teams = api_call("GET", f"/team/list")
            if "data" in teams:
                for team in teams["data"]:
                    if team.get("team_alias") == code:
                        created_teams[code] = team["team_id"]
                        print(f"  Team already exists: {team['team_id']}")
                        break
        else:
            team_id = result.get("team_id")
            created_teams[code] = team_id
            print(f"  Created: {team_id}")
            print(f"  Budget: ${config['max_budget']:.2f} / {config['budget_duration']}")

    print("\n=== Generating API Keys ===\n")

    team_keys = {}
    for code, team_id in created_teams.items():
        print(f"Generating key for team '{code}'...")

        result = api_call("POST", "/key/generate", {
            "team_id": team_id,
            "key_alias": f"{code.lower()}-key",
            "metadata": {"tenant_code": code}
        })

        if "error" in result:
            print(f"  Error: {result['error']}")
        else:
            key = result.get("key")
            team_keys[code] = key
            print(f"  Key: {key[:20]}...")

    print("\n=== Summary ===\n")
    print("Add these keys to your .env file:\n")
    for code, key in team_keys.items():
        print(f"# Team {code}")
        print(f"LITELLM_KEY_{code}={key}\n")

    # Also save to a file for easy reference
    with open("team_keys.json", "w") as f:
        json.dump({"teams": created_teams, "keys": team_keys}, f, indent=2)
    print("Keys saved to team_keys.json")


def test_budget(team_code: str):
    """Test budget enforcement by sending requests until rejected."""
    print(f"\n=== Testing Budget for Team '{team_code}' ===\n")

    # Load keys from file
    try:
        with open("team_keys.json") as f:
            data = json.load(f)
            key = data["keys"].get(team_code)
            if not key:
                print(f"Error: No key found for team '{team_code}'")
                return
    except FileNotFoundError:
        print("Error: Run 'setup' first to generate team keys")
        return

    print(f"Using key: {key[:20]}...")
    print(f"Sending requests until budget exceeded...\n")

    request_count = 0
    total_cost = 0.0

    while True:
        request_count += 1
        print(f"Request #{request_count}...", end=" ")

        # Make a simple chat completion request
        result = api_call_with_key(key, "POST", "/v1/chat/completions", {
            "model": "gpt-4o-mini",  # Use cheaper model for testing
            "messages": [{"role": "user", "content": "Hi"}],
            "max_tokens": 10
        })

        if "error" in result:
            error = result["error"]
            if isinstance(error, dict) and "ExceededTokenBudget" in str(error):
                print("BUDGET EXCEEDED!")
                print(f"\nBudget enforcement working correctly!")
                print(f"Requests made: {request_count - 1}")
                break
            elif result.get("status_code") == 400:
                print(f"REJECTED: Budget exceeded")
                print(f"\nBudget enforcement working correctly!")
                print(f"Requests made: {request_count - 1}")
                break
            else:
                print(f"Error: {error}")
                break
        else:
            # Extract cost from response if available
            usage = result.get("usage", {})
            tokens = usage.get("total_tokens", 0)
            # Approximate cost for gpt-4o-mini: $0.15/1M input, $0.60/1M output
            est_cost = tokens * 0.0000006  # rough estimate
            total_cost += est_cost
            print(f"OK (tokens: {tokens}, est cost: ${est_cost:.6f})")

        if request_count >= 100:
            print("\nReached 100 requests without budget exceeded - check budget settings")
            break


def api_call_with_key(api_key: str, method: str, endpoint: str, data: dict = None) -> dict:
    """Make API call with a specific API key."""
    url = f"{LITELLM_URL}{endpoint}"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    body = json.dumps(data).encode() if data else None
    req = Request(url, data=body, headers=headers, method=method)

    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except HTTPError as e:
        error_body = e.read().decode()
        try:
            return {"error": json.loads(error_body), "status_code": e.code}
        except:
            return {"error": error_body, "status_code": e.code}


def check_status(team_code: str):
    """Check team spend status."""
    print(f"\n=== Team '{team_code}' Status ===\n")

    # Get team info
    teams = api_call("GET", "/team/list")

    if "data" not in teams:
        print(f"Error: {teams}")
        return

    for team in teams["data"]:
        if team.get("team_alias") == team_code:
            print(f"Team ID: {team['team_id']}")
            print(f"Alias: {team['team_alias']}")
            print(f"Max Budget: ${team.get('max_budget', 0):.2f}")
            print(f"Current Spend: ${team.get('spend', 0):.6f}")
            print(f"Budget Duration: {team.get('budget_duration', 'N/A')}")

            # Calculate remaining
            max_budget = team.get('max_budget', 0)
            spend = team.get('spend', 0)
            remaining = max_budget - spend
            print(f"Remaining: ${remaining:.6f}")

            if spend >= max_budget:
                print("\n*** BUDGET EXCEEDED ***")
            return

    print(f"Team '{team_code}' not found")


def reset_spend(team_code: str):
    """Reset team spend (for testing)."""
    print(f"\n=== Resetting Spend for Team '{team_code}' ===\n")

    # Get team ID
    teams = api_call("GET", "/team/list")
    team_id = None

    for team in teams.get("data", []):
        if team.get("team_alias") == team_code:
            team_id = team["team_id"]
            break

    if not team_id:
        print(f"Team '{team_code}' not found")
        return

    # Reset spend to 0
    result = api_call("POST", "/team/update", {
        "team_id": team_id,
        "spend": 0
    })

    if "error" in result:
        print(f"Error: {result['error']}")
    else:
        print(f"Spend reset to $0.00 for team '{team_code}'")


def main():
    parser = argparse.ArgumentParser(description="Test LiteLLM budget enforcement")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # Setup command
    subparsers.add_parser("setup", help="Create teams and generate API keys")

    # Test command
    test_parser = subparsers.add_parser("test", help="Test budget enforcement")
    test_parser.add_argument("--team", required=True, choices=list(TENANTS.keys()),
                            help="Team code to test")

    # Status command
    status_parser = subparsers.add_parser("status", help="Check team status")
    status_parser.add_argument("--team", required=True, choices=list(TENANTS.keys()),
                               help="Team code to check")

    # Reset command
    reset_parser = subparsers.add_parser("reset", help="Reset team spend")
    reset_parser.add_argument("--team", required=True, choices=list(TENANTS.keys()),
                              help="Team code to reset")

    args = parser.parse_args()

    if args.command == "setup":
        setup_teams()
    elif args.command == "test":
        test_budget(args.team)
    elif args.command == "status":
        check_status(args.team)
    elif args.command == "reset":
        reset_spend(args.team)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
