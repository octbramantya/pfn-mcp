#!/usr/bin/env python3
"""
Sync Keycloak groups to Valkyrie auth tables.

This script:
1. Fetches all users from Keycloak realm who are in tenant groups
2. Maps Keycloak groups to tenant_id using tenant_code
3. Upserts auth_users records (email, name, email_verified)
4. Upserts auth_user_tenants records (user_id, tenant_id, product_id)
5. Deactivates memberships for users removed from groups

Can be run as a cron job (recommended: every 5 minutes) or on-demand.

Usage:
    # Set environment variables (see .env.example)
    export KEYCLOAK_URL=https://auth.forsanusa.id
    export KEYCLOAK_REALM=pfn
    export KEYCLOAK_ADMIN_USER=admin
    export KEYCLOAK_ADMIN_PASSWORD=***
    export VALKYRIE_DATABASE_URL=postgresql://postgres:***@88.222.213.96:5432/valkyrie

    # Run the sync
    python sync_keycloak_to_valkyrie.py

    # Or with --dry-run to preview changes
    python sync_keycloak_to_valkyrie.py --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import asyncpg

# Configuration from environment
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://localhost:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "pfn")
KEYCLOAK_ADMIN_USER = os.environ.get("KEYCLOAK_ADMIN_USER", "admin")
KEYCLOAK_ADMIN_PASSWORD = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin")
VALKYRIE_DATABASE_URL = os.environ.get(
    "VALKYRIE_DATABASE_URL",
    os.environ.get("DATABASE_URL", "postgresql://localhost:5432/valkyrie"),
)

# Product ID for MCP/Copilot access
COPILOT_PRODUCT_ID = 2

# Default role for new user-tenant assignments
DEFAULT_ROLE = "viewer"

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


@dataclass
class KeycloakUser:
    """User data from Keycloak."""

    id: str
    username: str
    email: str | None
    first_name: str | None
    last_name: str | None
    email_verified: bool
    groups: list[str]

    @property
    def display_name(self) -> str:
        """Get display name from first/last name or username."""
        parts = [self.first_name, self.last_name]
        name = " ".join(p for p in parts if p)
        return name or self.username


@dataclass
class SyncStats:
    """Statistics for sync operation."""

    users_processed: int = 0
    users_created: int = 0
    users_updated: int = 0
    memberships_created: int = 0
    memberships_reactivated: int = 0
    memberships_deactivated: int = 0
    errors: int = 0


# -----------------------------------------------------------------------------
# Keycloak API
# -----------------------------------------------------------------------------


def get_keycloak_token() -> str:
    """Get admin access token from Keycloak."""
    url = f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
    data = urlencode(
        {
            "username": KEYCLOAK_ADMIN_USER,
            "password": KEYCLOAK_ADMIN_PASSWORD,
            "grant_type": "password",
            "client_id": "admin-cli",
        }
    ).encode()

    req = Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())["access_token"]


def get_keycloak_users(token: str) -> list[dict]:
    """Get all users from Keycloak realm."""
    url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users?max=1000"
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def get_user_groups(token: str, user_id: str) -> list[dict]:
    """Get groups for a specific user."""
    url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/users/{user_id}/groups"
    req = Request(url, headers={"Authorization": f"Bearer {token}"})
    with urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def fetch_all_keycloak_users(token: str) -> list[KeycloakUser]:
    """Fetch all Keycloak users with their group memberships."""
    users = []
    raw_users = get_keycloak_users(token)

    for raw in raw_users:
        groups = get_user_groups(token, raw["id"])
        group_names = [g["name"] for g in groups]

        users.append(
            KeycloakUser(
                id=raw["id"],
                username=raw.get("username", ""),
                email=raw.get("email"),
                first_name=raw.get("firstName"),
                last_name=raw.get("lastName"),
                email_verified=raw.get("emailVerified", False),
                groups=group_names,
            )
        )

    return users


# -----------------------------------------------------------------------------
# Database Operations
# -----------------------------------------------------------------------------


async def get_tenant_mapping(conn: asyncpg.Connection) -> dict[str, int]:
    """Get mapping from tenant_code to tenant_id."""
    rows = await conn.fetch("SELECT id, tenant_code FROM tenants WHERE is_active = true")
    return {row["tenant_code"]: row["id"] for row in rows}


async def get_existing_user_by_email(conn: asyncpg.Connection, email: str) -> dict | None:
    """Get existing auth_user by email."""
    return await conn.fetchrow(
        "SELECT id, email, name, email_verified FROM auth_users WHERE email = $1", email
    )


async def upsert_auth_user(
    conn: asyncpg.Connection,
    email: str,
    name: str,
    email_verified: bool,
    dry_run: bool = False,
) -> tuple[int, bool]:
    """
    Upsert auth_users record.

    Returns (user_id, was_created).
    """
    existing = await get_existing_user_by_email(conn, email)

    if existing:
        user_id = existing["id"]
        # Check if update needed
        if existing["name"] != name or existing["email_verified"] != email_verified:
            if not dry_run:
                await conn.execute(
                    """
                    UPDATE auth_users
                    SET name = $2, email_verified = $3, updated_at = CURRENT_TIMESTAMP
                    WHERE id = $1
                    """,
                    user_id,
                    name,
                    email_verified,
                )
            logger.debug(f"Updated user: {email}")
        return user_id, False
    else:
        if dry_run:
            # Return fake ID for dry run
            return -1, True

        user_id = await conn.fetchval(
            """
            INSERT INTO auth_users (email, password_hash, name, email_verified, is_active)
            VALUES ($1, 'KEYCLOAK_AUTH', $2, $3, true)
            RETURNING id
            """,
            email,
            name,
            email_verified,
        )
        logger.info(f"Created user: {email} (id={user_id})")
        return user_id, True


async def get_user_tenant_memberships(
    conn: asyncpg.Connection, user_id: int, product_id: int
) -> dict[int, dict]:
    """Get existing tenant memberships for a user."""
    rows = await conn.fetch(
        """
        SELECT tenant_id, is_active
        FROM auth_user_tenants
        WHERE user_id = $1 AND product_id = $2
        """,
        user_id,
        product_id,
    )
    return {row["tenant_id"]: {"is_active": row["is_active"]} for row in rows}


async def upsert_user_tenant(
    conn: asyncpg.Connection,
    user_id: int,
    tenant_id: int,
    product_id: int,
    role: str,
    existing: dict | None,
    dry_run: bool = False,
) -> str:
    """
    Upsert auth_user_tenants record.

    Returns: "created", "reactivated", or "unchanged"
    """
    if existing is None:
        # New membership
        if not dry_run:
            await conn.execute(
                """
                INSERT INTO auth_user_tenants (user_id, tenant_id, product_id, role, is_active)
                VALUES ($1, $2, $3, $4, true)
                """,
                user_id,
                tenant_id,
                product_id,
                role,
            )
        return "created"
    elif not existing["is_active"]:
        # Reactivate
        if not dry_run:
            await conn.execute(
                """
                UPDATE auth_user_tenants
                SET is_active = true, updated_at = CURRENT_TIMESTAMP
                WHERE user_id = $1 AND tenant_id = $2 AND product_id = $3
                """,
                user_id,
                tenant_id,
                product_id,
            )
        return "reactivated"
    else:
        return "unchanged"


async def deactivate_membership(
    conn: asyncpg.Connection,
    user_id: int,
    tenant_id: int,
    product_id: int,
    dry_run: bool = False,
) -> None:
    """Deactivate a user-tenant membership."""
    if not dry_run:
        await conn.execute(
            """
            UPDATE auth_user_tenants
            SET is_active = false, updated_at = CURRENT_TIMESTAMP
            WHERE user_id = $1 AND tenant_id = $2 AND product_id = $3
            """,
            user_id,
            tenant_id,
            product_id,
        )


# -----------------------------------------------------------------------------
# Sync Logic
# -----------------------------------------------------------------------------


async def sync_user(
    conn: asyncpg.Connection,
    user: KeycloakUser,
    tenant_mapping: dict[str, int],
    stats: SyncStats,
    dry_run: bool = False,
) -> None:
    """Sync a single Keycloak user to Valkyrie."""
    stats.users_processed += 1

    # Skip users without email
    if not user.email:
        logger.warning(f"Skipping user {user.username}: no email")
        return

    # Get tenant IDs from groups
    tenant_ids = set()
    for group in user.groups:
        if group in tenant_mapping:
            tenant_ids.add(tenant_mapping[group])

    # Skip users not in any tenant group
    if not tenant_ids:
        logger.debug(f"Skipping user {user.email}: no tenant groups")
        return

    try:
        # Upsert auth_user
        user_id, was_created = await upsert_auth_user(
            conn,
            email=user.email,
            name=user.display_name,
            email_verified=user.email_verified,
            dry_run=dry_run,
        )

        if was_created:
            stats.users_created += 1
        else:
            stats.users_updated += 1

        # Skip membership sync for dry run with fake user_id
        if dry_run and user_id == -1:
            stats.memberships_created += len(tenant_ids)
            return

        # Get existing memberships
        existing_memberships = await get_user_tenant_memberships(
            conn, user_id, COPILOT_PRODUCT_ID
        )

        # Upsert memberships for current groups
        for tenant_id in tenant_ids:
            existing = existing_memberships.get(tenant_id)
            result = await upsert_user_tenant(
                conn,
                user_id=user_id,
                tenant_id=tenant_id,
                product_id=COPILOT_PRODUCT_ID,
                role=DEFAULT_ROLE,
                existing=existing,
                dry_run=dry_run,
            )

            if result == "created":
                stats.memberships_created += 1
                logger.info(f"Created membership: {user.email} -> tenant_id={tenant_id}")
            elif result == "reactivated":
                stats.memberships_reactivated += 1
                logger.info(f"Reactivated membership: {user.email} -> tenant_id={tenant_id}")

        # Deactivate memberships for groups user is no longer in
        for tenant_id, existing in existing_memberships.items():
            if tenant_id not in tenant_ids and existing["is_active"]:
                await deactivate_membership(
                    conn, user_id, tenant_id, COPILOT_PRODUCT_ID, dry_run=dry_run
                )
                stats.memberships_deactivated += 1
                logger.info(f"Deactivated membership: {user.email} -> tenant_id={tenant_id}")

    except Exception as e:
        stats.errors += 1
        logger.error(f"Error syncing user {user.email}: {e}")


async def run_sync(dry_run: bool = False) -> SyncStats:
    """Run the full sync operation."""
    stats = SyncStats()
    start_time = datetime.now(UTC)

    logger.info("=" * 60)
    logger.info("Starting Keycloak -> Valkyrie sync")
    logger.info(f"Keycloak: {KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}")
    db_display = VALKYRIE_DATABASE_URL.split("@")[-1] if "@" in VALKYRIE_DATABASE_URL else "local"
    logger.info(f"Database: {db_display}")
    if dry_run:
        logger.info("DRY RUN MODE - no changes will be made")
    logger.info("=" * 60)

    # Step 1: Get Keycloak token and users
    logger.info("Fetching Keycloak users...")
    try:
        token = get_keycloak_token()
        users = fetch_all_keycloak_users(token)
        logger.info(f"Found {len(users)} users in Keycloak")
    except Exception as e:
        logger.error(f"Failed to fetch Keycloak users: {e}")
        stats.errors += 1
        return stats

    # Step 2: Connect to database and sync
    try:
        conn = await asyncpg.connect(VALKYRIE_DATABASE_URL)
        logger.info("Connected to Valkyrie database")
    except Exception as e:
        logger.error(f"Failed to connect to database: {e}")
        stats.errors += 1
        return stats

    try:
        # Get tenant mapping
        tenant_mapping = await get_tenant_mapping(conn)
        logger.info(f"Tenant mapping: {tenant_mapping}")

        # Sync each user
        for user in users:
            await sync_user(conn, user, tenant_mapping, stats, dry_run=dry_run)

    finally:
        await conn.close()

    # Summary
    elapsed = (datetime.now(UTC) - start_time).total_seconds()
    logger.info("=" * 60)
    logger.info("Sync complete")
    logger.info(f"Time elapsed: {elapsed:.2f}s")
    logger.info(f"Users processed: {stats.users_processed}")
    logger.info(f"Users created: {stats.users_created}")
    logger.info(f"Users updated: {stats.users_updated}")
    logger.info(f"Memberships created: {stats.memberships_created}")
    logger.info(f"Memberships reactivated: {stats.memberships_reactivated}")
    logger.info(f"Memberships deactivated: {stats.memberships_deactivated}")
    logger.info(f"Errors: {stats.errors}")
    logger.info("=" * 60)

    return stats


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Sync Keycloak groups to Valkyrie auth tables"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without making them",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    try:
        stats = asyncio.run(run_sync(dry_run=args.dry_run))
        sys.exit(0 if stats.errors == 0 else 1)
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        sys.exit(130)
    except Exception as e:
        logger.error(f"Sync failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
