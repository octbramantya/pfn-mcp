#!/usr/bin/env python3
"""
Setup Keycloak OIDC client for Grafana.

Task: pfn_mcp-dn3 - Setup: Keycloak client for Grafana

Usage:
    python setup_grafana_keycloak.py --password YOUR_KEYCLOAK_ADMIN_PASSWORD

Or set environment variable:
    export KEYCLOAK_ADMIN_PASSWORD=your-password
    python setup_grafana_keycloak.py
"""

import argparse
import os
import sys

import httpx

# Configuration
KC_URL = os.getenv("KEYCLOAK_URL", "https://auth.forsanusa.id")
KC_REALM = os.getenv("KEYCLOAK_REALM", "pfn")
KC_ADMIN = os.getenv("KEYCLOAK_ADMIN_USER", "admin")
GRAFANA_URL = "https://viz.forsanusa.id"


def get_admin_token(password: str) -> str:
    """Get Keycloak admin access token."""
    resp = httpx.post(
        f"{KC_URL}/realms/master/protocol/openid-connect/token",
        data={
            "username": KC_ADMIN,
            "password": password,
            "grant_type": "password",
            "client_id": "admin-cli",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def create_grafana_client(token: str) -> str | None:
    """Create Grafana OIDC client in Keycloak."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    client_config = {
        "clientId": "grafana",
        "name": "Grafana",
        "description": "Grafana visualization platform",
        "enabled": True,
        "clientAuthenticatorType": "client-secret",
        "protocol": "openid-connect",
        "publicClient": False,
        "standardFlowEnabled": True,
        "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": False,
        "rootUrl": GRAFANA_URL,
        "baseUrl": GRAFANA_URL,
        "redirectUris": [f"{GRAFANA_URL}/login/generic_oauth"],
        "webOrigins": [GRAFANA_URL],
        "attributes": {"post.logout.redirect.uris": f"{GRAFANA_URL}/*"},
    }

    resp = httpx.post(
        f"{KC_URL}/admin/realms/{KC_REALM}/clients",
        headers=headers,
        json=client_config,
        timeout=30,
    )

    if resp.status_code == 201:
        print("✓ Created grafana client")
        return None
    elif resp.status_code == 409:
        print("⚠ Client 'grafana' already exists")
        return None
    else:
        resp.raise_for_status()
        return None


def get_client_uuid(token: str) -> str:
    """Get the UUID of the grafana client."""
    headers = {"Authorization": f"Bearer {token}"}
    resp = httpx.get(
        f"{KC_URL}/admin/realms/{KC_REALM}/clients",
        headers=headers,
        params={"clientId": "grafana"},
        timeout=30,
    )
    resp.raise_for_status()
    clients = resp.json()
    if not clients:
        raise ValueError("Grafana client not found")
    return clients[0]["id"]


def get_client_secret(token: str, client_uuid: str) -> str:
    """Get the client secret."""
    headers = {"Authorization": f"Bearer {token}"}
    resp = httpx.get(
        f"{KC_URL}/admin/realms/{KC_REALM}/clients/{client_uuid}/client-secret",
        headers=headers,
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["value"]


def create_group_mapper(token: str, client_uuid: str) -> None:
    """Create group membership mapper for the client."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    mapper_config = {
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": False,
        "config": {
            "full.path": "false",
            "introspection.token.claim": "true",
            "userinfo.token.claim": "true",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
        },
    }

    resp = httpx.post(
        f"{KC_URL}/admin/realms/{KC_REALM}/clients/{client_uuid}/protocol-mappers/models",
        headers=headers,
        json=mapper_config,
        timeout=30,
    )

    if resp.status_code == 201:
        print("✓ Created groups mapper")
    elif resp.status_code == 409:
        print("⚠ Groups mapper already exists")
    else:
        resp.raise_for_status()


def create_role_mapper(token: str, client_uuid: str) -> None:
    """Create realm role mapper for Grafana role mapping."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    mapper_config = {
        "name": "grafana-roles",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-realm-role-mapper",
        "consentRequired": False,
        "config": {
            "introspection.token.claim": "true",
            "userinfo.token.claim": "true",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "roles",
            "multivalued": "true",
        },
    }

    resp = httpx.post(
        f"{KC_URL}/admin/realms/{KC_REALM}/clients/{client_uuid}/protocol-mappers/models",
        headers=headers,
        json=mapper_config,
        timeout=30,
    )

    if resp.status_code == 201:
        print("✓ Created roles mapper")
    elif resp.status_code == 409:
        print("⚠ Roles mapper already exists")
    else:
        resp.raise_for_status()


def main():
    parser = argparse.ArgumentParser(
        description="Setup Keycloak OIDC client for Grafana"
    )
    parser.add_argument(
        "--password",
        "-p",
        help="Keycloak admin password (or set KEYCLOAK_ADMIN_PASSWORD env var)",
    )
    args = parser.parse_args()

    password = args.password or os.getenv("KEYCLOAK_ADMIN_PASSWORD")
    if not password:
        print("Error: Keycloak admin password required")
        print("  Use --password or set KEYCLOAK_ADMIN_PASSWORD")
        sys.exit(1)

    print(f"Keycloak URL: {KC_URL}")
    print(f"Realm: {KC_REALM}")
    print(f"Grafana URL: {GRAFANA_URL}")
    print()

    # Get admin token
    print("=== Getting Keycloak admin token ===")
    token = get_admin_token(password)
    print("✓ Got admin token")
    print()

    # Create client
    print("=== Creating Grafana client ===")
    create_grafana_client(token)
    print()

    # Get client UUID and secret
    print("=== Getting client details ===")
    client_uuid = get_client_uuid(token)
    print(f"✓ Client UUID: {client_uuid}")
    client_secret = get_client_secret(token, client_uuid)
    print(f"✓ Client Secret: {client_secret}")
    print()

    # Create mappers
    print("=== Creating protocol mappers ===")
    create_group_mapper(token, client_uuid)
    create_role_mapper(token, client_uuid)
    print()

    # Print configuration
    print("=" * 50)
    print("Grafana Keycloak client setup complete!")
    print("=" * 50)
    print()
    print("Add these environment variables to Grafana:")
    print()
    print(f"GF_SERVER_ROOT_URL={GRAFANA_URL}")
    print()
    print("GF_AUTH_GENERIC_OAUTH_ENABLED=true")
    print('GF_AUTH_GENERIC_OAUTH_NAME="Keycloak"')
    print("GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true")
    print("GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true")
    print("GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana")
    print(f"GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET={client_secret}")
    print("GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile groups")
    print(
        f"GF_AUTH_GENERIC_OAUTH_AUTH_URL={KC_URL}/realms/{KC_REALM}/protocol/openid-connect/auth"
    )
    print(
        f"GF_AUTH_GENERIC_OAUTH_TOKEN_URL={KC_URL}/realms/{KC_REALM}/protocol/openid-connect/token"
    )
    print(
        f"GF_AUTH_GENERIC_OAUTH_API_URL={KC_URL}/realms/{KC_REALM}/protocol/openid-connect/userinfo"
    )
    print()
    print("# Role mapping (map Keycloak groups to Grafana roles)")
    print('GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], \'Admin\') && \'Admin\' || \'Viewer\'"')
    print()
    print("# Disable default login to force OAuth")
    print("GF_AUTH_DISABLE_LOGIN_FORM=true")
    print()


if __name__ == "__main__":
    main()
