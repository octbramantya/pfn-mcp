"""Authentication module for Keycloak OAuth and JWT handling."""

from datetime import UTC, datetime, timedelta

import httpx
import jwt
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from .config import chat_settings

# Security scheme
security = HTTPBearer(auto_error=False)


class UserContext(BaseModel):
    """User context extracted from JWT."""

    sub: str  # Keycloak subject ID
    email: str
    name: str
    tenant_code: str | None = None  # None for superusers
    is_superuser: bool = False
    groups: list[str] = []
    # Effective tenant (can be switched by superuser)
    effective_tenant: str | None = None


class TokenResponse(BaseModel):
    """JWT token response."""

    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserContext


async def exchange_code_for_token(code: str, redirect_uri: str) -> dict:
    """Exchange authorization code for Keycloak tokens."""
    async with httpx.AsyncClient() as client:
        response = await client.post(
            chat_settings.keycloak_token_url,
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
                "client_id": chat_settings.keycloak_client_id,
                "client_secret": chat_settings.keycloak_client_secret,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if response.status_code != 200:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Failed to exchange code: {response.text}",
            )
        return response.json()


async def get_keycloak_userinfo(access_token: str) -> dict:
    """Fetch user info from Keycloak using access token."""
    async with httpx.AsyncClient() as client:
        response = await client.get(
            chat_settings.keycloak_userinfo_url,
            headers={"Authorization": f"Bearer {access_token}"},
        )
        if response.status_code != 200:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Failed to fetch user info from Keycloak",
            )
        return response.json()


async def get_user_groups(access_token: str, user_sub: str) -> list[str]:
    """
    Fetch user groups from Keycloak.

    Groups are included in the token if the client mapper is configured,
    otherwise we fetch from the admin API.
    """
    # First try to decode groups from the access token itself
    try:
        # Keycloak tokens are JWTs - decode without verification to get claims
        claims = jwt.decode(access_token, options={"verify_signature": False})
        if "groups" in claims:
            return claims["groups"]
    except jwt.DecodeError:
        pass

    # Fallback: groups not in token (would need admin API access)
    # For now, return empty - client mapper should be configured
    return []


def resolve_tenant_from_groups(groups: list[str]) -> tuple[str | None, bool]:
    """
    Resolve tenant code and superuser status from Keycloak groups.

    Returns:
        (tenant_code, is_superuser)
        - ("PRS", False) for regular user in PRS tenant
        - (None, True) for superuser
        - (None, False) for user with no tenant group
    """
    # Normalize group names (remove leading slash if present)
    normalized = [g.lstrip("/") for g in groups]

    if "superuser" in normalized:
        return None, True

    # First non-superuser group is the tenant
    for group in normalized:
        if group != "superuser":
            return group, False

    return None, False


def create_jwt_token(user: UserContext) -> str:
    """Create a JWT token for the user."""
    expire = datetime.now(UTC) + timedelta(minutes=chat_settings.jwt_expire_minutes)
    payload = {
        "sub": user.sub,
        "email": user.email,
        "name": user.name,
        "tenant_code": user.tenant_code,
        "is_superuser": user.is_superuser,
        "groups": user.groups,
        "exp": expire,
        "iat": datetime.now(UTC),
    }
    return jwt.encode(payload, chat_settings.jwt_secret, algorithm=chat_settings.jwt_algorithm)


def decode_jwt_token(token: str) -> dict:
    """Decode and validate a JWT token."""
    # Dev mode: accept mock tokens from frontend
    if chat_settings.dev_auth and token.endswith(".mock-signature"):
        try:
            return jwt.decode(token, options={"verify_signature": False})
        except jwt.DecodeError as e:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Invalid mock token: {e}",
            )

    # Production: validate signature
    try:
        return jwt.decode(
            token,
            chat_settings.jwt_secret,
            algorithms=[chat_settings.jwt_algorithm],
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token has expired",
        )
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid token: {e}",
        )


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    x_tenant_context: str | None = Header(None),
) -> UserContext:
    """
    FastAPI dependency to get current user from JWT.

    Superusers can override tenant context via X-Tenant-Context header.
    """
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )

    payload = decode_jwt_token(credentials.credentials)

    user = UserContext(
        sub=payload["sub"],
        email=payload["email"],
        name=payload["name"],
        tenant_code=payload.get("tenant_code"),
        is_superuser=payload.get("is_superuser", False),
        groups=payload.get("groups", []),
    )

    # Resolve effective tenant
    if user.is_superuser and x_tenant_context:
        # Superuser explicitly selected a tenant
        user.effective_tenant = x_tenant_context
    elif user.is_superuser:
        # Superuser with no selection - sees all tenants
        user.effective_tenant = None
    else:
        # Regular user - locked to their tenant
        user.effective_tenant = user.tenant_code

    return user


async def get_optional_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    x_tenant_context: str | None = Header(None),
) -> UserContext | None:
    """FastAPI dependency for optional authentication."""
    if not credentials:
        return None
    try:
        return await get_current_user(credentials, x_tenant_context)
    except HTTPException:
        return None
