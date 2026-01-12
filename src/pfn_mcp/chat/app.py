"""FastAPI application for PFN Chat API."""

from urllib.parse import urlencode

from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from .auth import (
    TokenResponse,
    UserContext,
    create_jwt_token,
    exchange_code_for_token,
    get_current_user,
    get_keycloak_userinfo,
    get_user_groups,
    resolve_tenant_from_groups,
)
from .config import chat_settings

app = FastAPI(
    title="PFN Chat API",
    description="Backend API for PFN custom chat UI",
    version="0.1.0",
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class UserInfoResponse(BaseModel):
    """Response for /api/auth/me endpoint."""

    sub: str
    email: str
    name: str
    tenant_code: str | None
    is_superuser: bool
    effective_tenant: str | None
    groups: list[str]
    branding: dict | None = None  # Will be populated from database


class TenantSwitchRequest(BaseModel):
    """Request body for tenant switching."""

    tenant_code: str | None = None  # None to see all tenants


# =============================================================================
# Health Check
# =============================================================================


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "pfn-chat-api"}


# =============================================================================
# Auth Endpoints
# =============================================================================


@app.get("/api/auth/login")
async def login(redirect_uri: str = Query(..., description="Frontend callback URL")):
    """
    Initiate Keycloak OAuth login.

    Redirects user to Keycloak login page.
    After login, Keycloak redirects back to the frontend callback URL with an auth code.
    """
    params = {
        "client_id": chat_settings.keycloak_client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": "openid email profile",
    }
    auth_url = f"{chat_settings.keycloak_auth_url}?{urlencode(params)}"
    return RedirectResponse(url=auth_url)


@app.get("/api/auth/callback", response_model=TokenResponse)
async def callback(
    code: str = Query(..., description="Authorization code from Keycloak"),
    redirect_uri: str = Query(..., description="Same redirect_uri used in login"),
):
    """
    Handle Keycloak OAuth callback.

    Exchanges authorization code for tokens, fetches user info,
    resolves tenant from groups, and returns a JWT.
    """
    # Exchange code for Keycloak tokens
    token_data = await exchange_code_for_token(code, redirect_uri)
    kc_access_token = token_data["access_token"]

    # Get user info from Keycloak
    userinfo = await get_keycloak_userinfo(kc_access_token)

    # Get user groups (from token or admin API)
    groups = await get_user_groups(kc_access_token, userinfo["sub"])

    # Resolve tenant from groups
    tenant_code, is_superuser = resolve_tenant_from_groups(groups)

    # Build user context
    user = UserContext(
        sub=userinfo["sub"],
        email=userinfo.get("email", ""),
        name=userinfo.get("name", userinfo.get("preferred_username", "")),
        tenant_code=tenant_code,
        is_superuser=is_superuser,
        groups=groups,
        effective_tenant=tenant_code,  # Initially same as tenant_code
    )

    # Create our JWT
    jwt_token = create_jwt_token(user)

    return TokenResponse(
        access_token=jwt_token,
        expires_in=chat_settings.jwt_expire_minutes * 60,
        user=user,
    )


@app.get("/api/auth/me", response_model=UserInfoResponse)
async def get_me(user: UserContext = Depends(get_current_user)):
    """
    Get current user info including tenant context and branding.

    The effective_tenant reflects any superuser tenant switching.
    """
    # TODO: Fetch branding from mcp.tenant_branding table
    branding = None

    return UserInfoResponse(
        sub=user.sub,
        email=user.email,
        name=user.name,
        tenant_code=user.tenant_code,
        is_superuser=user.is_superuser,
        effective_tenant=user.effective_tenant,
        groups=user.groups,
        branding=branding,
    )


@app.put("/api/auth/tenant")
async def switch_tenant(
    request: TenantSwitchRequest,
    user: UserContext = Depends(get_current_user),
):
    """
    Switch tenant context (superuser only).

    Regular users cannot switch tenants and will get a 403 error.
    Superusers can switch to any tenant or set to None to see all.

    Note: This doesn't modify the JWT. The frontend should include
    X-Tenant-Context header in subsequent requests.
    """
    if not user.is_superuser:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only superusers can switch tenants",
        )

    return {
        "message": "Tenant context updated",
        "effective_tenant": request.tenant_code,
        "instruction": "Include X-Tenant-Context header in subsequent requests",
    }


# =============================================================================
# Entry Point
# =============================================================================


def run():
    """Run the chat API server."""
    import uvicorn

    uvicorn.run(
        "pfn_mcp.chat.app:app",
        host=chat_settings.chat_host,
        port=chat_settings.chat_port,
        reload=True,
    )


if __name__ == "__main__":
    run()
