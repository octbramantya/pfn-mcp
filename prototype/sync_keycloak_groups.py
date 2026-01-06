#!/usr/bin/env python3
"""
Sync Keycloak groups to Open WebUI user.info

This script:
1. Fetches all users from Keycloak realm
2. Gets their group memberships
3. Updates Open WebUI user.info with tenant_code

Can be run as a cron job or on-demand.

Usage:
    # From host (requires requests)
    python sync_keycloak_groups.py

    # Or from within Open WebUI container
    docker exec proto-openwebui python /path/to/sync_keycloak_groups.py
"""

import os
import json
import sqlite3
from urllib.request import urlopen, Request
from urllib.parse import urlencode

# Configuration
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://localhost:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "pfn")
KEYCLOAK_ADMIN_USER = os.environ.get("KEYCLOAK_ADMIN_USER", "admin")
KEYCLOAK_ADMIN_PASSWORD = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin")
OPENWEBUI_DB_PATH = os.environ.get("OPENWEBUI_DB_PATH", "/app/backend/data/webui.db")


def get_keycloak_token() -> str:
    """Get admin access token from Keycloak."""
    url = f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
    data = urlencode({
        "username": KEYCLOAK_ADMIN_USER,
        "password": KEYCLOAK_ADMIN_PASSWORD,
        "grant_type": "password",
        "client_id": "admin-cli"
    }).encode()

    req = Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(req) as resp:
        return json.loads(resp.read())["access_token"]


def get_keycloak_users(token: str) -> list:
    """Get all users from Keycloak realm."""
    url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users"
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    with urlopen(req) as resp:
        return json.loads(resp.read())


def get_user_groups(token: str, user_id: str) -> list:
    """Get groups for a specific user."""
    url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users/{user_id}/groups"
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    with urlopen(req) as resp:
        return json.loads(resp.read())


def update_openwebui_user(oauth_sub: str, tenant_code: str, groups: list) -> bool:
    """Update Open WebUI user.info with tenant data."""
    conn = sqlite3.connect(OPENWEBUI_DB_PATH)
    cursor = conn.cursor()

    # Find user by oauth_sub
    cursor.execute(
        "SELECT id, info FROM user WHERE json_extract(oauth, '$.oidc.sub') = ?",
        (oauth_sub,)
    )
    row = cursor.fetchone()

    if not row:
        print(f"  User with oauth_sub {oauth_sub} not found in Open WebUI")
        return False

    user_id, current_info = row

    # Parse existing info or create new
    info = json.loads(current_info) if current_info else {}
    info["tenant_code"] = tenant_code
    info["keycloak_groups"] = groups

    # Update
    cursor.execute(
        "UPDATE user SET info = ? WHERE id = ?",
        (json.dumps(info), user_id)
    )
    conn.commit()
    conn.close()

    return True


def sync_all():
    """Main sync function."""
    print("Starting Keycloak -> Open WebUI group sync...")

    # Get Keycloak token
    print("1. Getting Keycloak admin token...")
    token = get_keycloak_token()

    # Get all users
    print("2. Fetching Keycloak users...")
    users = get_keycloak_users(token)
    print(f"   Found {len(users)} users")

    # Process each user
    print("3. Syncing user groups...")
    synced = 0
    for user in users:
        kc_user_id = user["id"]
        username = user.get("username", "unknown")

        # Get groups
        groups = get_user_groups(token, kc_user_id)
        group_names = [g["name"] for g in groups]

        if not group_names:
            print(f"   {username}: No groups, skipping")
            continue

        # Use first group as tenant
        tenant_code = group_names[0]

        # Update Open WebUI
        if update_openwebui_user(kc_user_id, tenant_code, group_names):
            print(f"   {username}: tenant={tenant_code}, groups={group_names}")
            synced += 1

    print(f"\nSync complete: {synced}/{len(users)} users updated")


if __name__ == "__main__":
    sync_all()
