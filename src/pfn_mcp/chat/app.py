"""FastAPI application for PFN Chat API."""

import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime
from urllib.parse import urlencode
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, StreamingResponse
from pydantic import BaseModel

from pfn_mcp.db import close_pool, init_pool

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
from .conversations import (
    add_message,
    create_conversation,
    delete_conversation,
    get_conversation,
    get_messages,
    get_tenant_id_by_code,
    list_conversations,
    update_conversation_title,
)
from .llm import ChatMessage, LLMClient
from .tool_executor import execute_tool_calls
from .usage import check_budget, get_user_usage

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan - initialize and cleanup resources."""
    # Startup
    logger.info("Starting PFN Chat API...")
    await init_pool()
    yield
    # Shutdown
    logger.info("Shutting down PFN Chat API...")
    await close_pool()


app = FastAPI(
    title="PFN Chat API",
    description="Backend API for PFN custom chat UI",
    version="0.1.0",
    lifespan=lifespan,
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


class ChatRequest(BaseModel):
    """Request body for chat endpoint."""

    message: str
    conversation_id: UUID | None = None  # None to create new conversation


class MessageResponse(BaseModel):
    """A single message in a conversation."""

    id: UUID
    role: str
    content: str
    tool_name: str | None = None
    tool_call_id: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    sequence: int
    created_at: datetime


class ConversationResponse(BaseModel):
    """Response for a single conversation."""

    id: UUID
    title: str | None
    model: str
    created_at: datetime
    updated_at: datetime
    message_count: int = 0


class ConversationDetailResponse(BaseModel):
    """Response for conversation with messages."""

    id: UUID
    title: str | None
    model: str
    created_at: datetime
    updated_at: datetime
    messages: list[MessageResponse]


class UsageResponse(BaseModel):
    """Response for usage endpoint."""

    total_input_tokens: int
    total_output_tokens: int
    total_tokens: int
    conversation_count: int
    period_start: datetime
    period_end: datetime
    # Budget info (percentage-based, no dollar amounts exposed to users)
    budget_used_percent: float | None = None
    budget_remaining_percent: float | None = None
    is_over_budget: bool = False
    is_near_limit: bool = False


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
# Chat Endpoint
# =============================================================================

# System prompt for the assistant
SYSTEM_PROMPT = """You are a helpful energy monitoring assistant for PFN.
You help users query and analyze energy consumption data from their power meters.
You have access to tools that can list devices, query electricity costs, and more.
Always be concise and helpful. When presenting data, format it clearly.
If you're unsure about something, ask for clarification."""


async def _generate_title(first_message: str) -> str:
    """Generate a title for the conversation from the first message."""
    # Simple title generation - first 50 chars or first sentence
    title = first_message.strip()
    if len(title) > 50:
        # Try to find a natural break point
        for sep in [".", "?", "!", "\n"]:
            idx = title.find(sep)
            if 0 < idx <= 50:
                title = title[:idx]
                break
        else:
            title = title[:47] + "..."
    return title


@app.post("/api/chat")
async def chat(
    request: ChatRequest,
    user: UserContext = Depends(get_current_user),
):
    """
    Send a message and receive a streaming response.

    This endpoint:
    1. Creates or retrieves a conversation
    2. Saves the user message
    3. Streams the LLM response with tool calls
    4. Saves the assistant response

    The response is Server-Sent Events (SSE) with these event types:
    - conversation: {id, title} - sent once at start
    - content: {text} - streaming text chunks
    - tool_call: {name, arguments} - when LLM calls a tool
    - tool_result: {name, result} - tool execution result
    - done: {input_tokens, output_tokens} - completion signal
    - error: {message} - if an error occurs
    """

    async def generate():
        try:
            # Check budget before processing
            is_allowed, budget_error = await check_budget(user.sub)
            if not is_allowed:
                err = {"message": budget_error, "type": "budget_exceeded"}
                yield f"event: error\ndata: {json.dumps(err)}\n\n"
                return

            # Resolve tenant ID for conversation
            tenant_code = user.effective_tenant or user.tenant_code
            if not tenant_code:
                # Superuser with no tenant selected - use a default
                tenant_id = 1  # TODO: Make configurable
            else:
                tenant_id = await get_tenant_id_by_code(tenant_code)
                if not tenant_id:
                    err = {"message": f"Unknown tenant: {tenant_code}"}
                    yield f"event: error\ndata: {json.dumps(err)}\n\n"
                    return

            # Get or create conversation
            conversation_id = request.conversation_id
            is_new_conversation = False

            if conversation_id:
                # Verify ownership
                conversation = await get_conversation(conversation_id, user.sub)
                if not conversation:
                    err = {"message": "Conversation not found"}
                    yield f"event: error\ndata: {json.dumps(err)}\n\n"
                    return
            else:
                # Create new conversation
                title = await _generate_title(request.message)
                conversation = await create_conversation(
                    user_id=user.sub,
                    tenant_id=tenant_id,
                    title=title,
                    model=chat_settings.llm_model,
                )
                conversation_id = conversation["id"]
                is_new_conversation = True

            # Send conversation info
            conv_info = {
                "id": str(conversation_id),
                "title": conversation.get("title"),
                "is_new": is_new_conversation,
            }
            yield f"event: conversation\ndata: {json.dumps(conv_info)}\n\n"

            # Save user message
            await add_message(
                conversation_id=conversation_id,
                role="user",
                content=request.message,
            )

            # Build message history
            db_messages = await get_messages(conversation_id, user.sub)

            messages = [ChatMessage(role="system", content=SYSTEM_PROMPT)]
            for msg in db_messages:
                if msg["role"] in ("user", "assistant"):
                    messages.append(ChatMessage(role=msg["role"], content=msg["content"]))
                elif msg["role"] == "tool":
                    messages.append(
                        ChatMessage(
                            role="tool",
                            content=msg["content"],
                            tool_call_id=msg["tool_call_id"],
                        )
                    )

            # Initialize LLM client
            client = LLMClient(model=chat_settings.llm_model)

            total_input_tokens = 0
            total_output_tokens = 0
            max_tool_iterations = 10
            iteration = 0

            # Tool loop - continue until no more tool calls
            while iteration < max_tool_iterations:
                iteration += 1
                accumulated_content = ""
                tool_calls = None

                # Stream response
                async for chunk in await client.chat(messages, stream=True):
                    if chunk.content:
                        accumulated_content += chunk.content
                        yield f"event: content\ndata: {json.dumps({'text': chunk.content})}\n\n"

                    if chunk.tool_calls:
                        tool_calls = chunk.tool_calls

                    if chunk.finish_reason:
                        total_input_tokens += chunk.input_tokens
                        total_output_tokens += chunk.output_tokens

                # Save assistant response
                if accumulated_content:
                    await add_message(
                        conversation_id=conversation_id,
                        role="assistant",
                        content=accumulated_content,
                        input_tokens=total_input_tokens,
                        output_tokens=total_output_tokens,
                    )

                # Handle tool calls
                if not tool_calls:
                    break  # No tool calls, we're done

                # Add assistant message with tool calls to history
                messages.append(
                    ChatMessage(
                        role="assistant",
                        content=accumulated_content or None,
                        tool_calls=tool_calls,
                    )
                )

                # Execute tools
                tool_results = await execute_tool_calls(tool_calls, tenant_code)

                for result in tool_results:
                    # Send tool events
                    call_data = {
                        "name": result.tool_name,
                        "call_id": result.tool_call_id,
                    }
                    yield f"event: tool_call\ndata: {json.dumps(call_data)}\n\n"

                    result_data = {
                        "name": result.tool_name,
                        "result": result.result[:1000],  # Truncate for SSE
                    }
                    yield f"event: tool_result\ndata: {json.dumps(result_data)}\n\n"

                    # Save tool result to database
                    await add_message(
                        conversation_id=conversation_id,
                        role="tool",
                        content=result.result,
                        tool_name=result.tool_name,
                        tool_call_id=result.tool_call_id,
                    )

                    # Add to message history
                    messages.append(
                        ChatMessage(
                            role="tool",
                            content=result.result,
                            tool_call_id=result.tool_call_id,
                        )
                    )

            # Send completion signal
            done_data = {
                "input_tokens": total_input_tokens,
                "output_tokens": total_output_tokens,
            }
            yield f"event: done\ndata: {json.dumps(done_data)}\n\n"

        except Exception as e:
            logger.exception("Chat error")
            yield f"event: error\ndata: {json.dumps({'message': str(e)})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        },
    )


# =============================================================================
# Conversation Endpoints
# =============================================================================


@app.get("/api/conversations", response_model=list[ConversationResponse])
async def list_user_conversations(
    user: UserContext = Depends(get_current_user),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
):
    """
    List user's conversations, ordered by most recent first.
    """
    conversations = await list_conversations(user.sub, limit, offset)
    return [
        ConversationResponse(
            id=c["id"],
            title=c["title"],
            model=c["model"],
            created_at=c["created_at"],
            updated_at=c["updated_at"],
            message_count=c.get("message_count", 0),
        )
        for c in conversations
    ]


@app.get("/api/conversations/{conversation_id}", response_model=ConversationDetailResponse)
async def get_conversation_detail(
    conversation_id: UUID,
    user: UserContext = Depends(get_current_user),
):
    """
    Get a conversation with all its messages.
    """
    conversation = await get_conversation(conversation_id, user.sub)
    if not conversation:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    messages = await get_messages(conversation_id, user.sub)

    return ConversationDetailResponse(
        id=conversation["id"],
        title=conversation["title"],
        model=conversation["model"],
        created_at=conversation["created_at"],
        updated_at=conversation["updated_at"],
        messages=[
            MessageResponse(
                id=m["id"],
                role=m["role"],
                content=m["content"],
                tool_name=m.get("tool_name"),
                tool_call_id=m.get("tool_call_id"),
                input_tokens=m.get("input_tokens"),
                output_tokens=m.get("output_tokens"),
                sequence=m["sequence"],
                created_at=m["created_at"],
            )
            for m in messages
        ],
    )


@app.delete("/api/conversations/{conversation_id}")
async def delete_user_conversation(
    conversation_id: UUID,
    user: UserContext = Depends(get_current_user),
):
    """
    Delete a conversation and all its messages.
    """
    deleted = await delete_conversation(conversation_id, user.sub)
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    return {"message": "Conversation deleted", "id": str(conversation_id)}


@app.patch("/api/conversations/{conversation_id}")
async def update_conversation(
    conversation_id: UUID,
    title: str = Query(..., min_length=1, max_length=255),
    user: UserContext = Depends(get_current_user),
):
    """
    Update conversation title.
    """
    updated = await update_conversation_title(conversation_id, user.sub, title)
    if not updated:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    return {"message": "Conversation updated", "id": str(conversation_id), "title": title}


# =============================================================================
# Usage Endpoint
# =============================================================================


@app.get("/api/usage", response_model=UsageResponse)
async def get_usage(
    user: UserContext = Depends(get_current_user),
    period: str = Query("monthly", description="Period: 'monthly', 'daily', or 'all'"),
):
    """
    Get user's token usage and budget status.

    Returns percentage-based budget info (no dollar amounts shown to users).
    """
    # Map 'month' to 'monthly' for backwards compatibility
    if period == "month":
        period = "monthly"
    elif period == "week":
        period = "daily"  # We don't have weekly, use daily

    stats = await get_user_usage(user.sub, period)

    # Calculate remaining percent
    remaining_pct = None
    if stats.budget_used_percent is not None:
        remaining_pct = max(0, 100 - stats.budget_used_percent)

    return UsageResponse(
        total_input_tokens=stats.input_tokens,
        total_output_tokens=stats.output_tokens,
        total_tokens=stats.total_tokens,
        conversation_count=stats.conversation_count,
        period_start=stats.period_start,
        period_end=stats.period_end,
        budget_used_percent=stats.budget_used_percent,
        budget_remaining_percent=remaining_pct,
        is_over_budget=stats.is_over_budget,
        is_near_limit=stats.is_near_limit,
    )


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
