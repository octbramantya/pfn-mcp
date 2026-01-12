"""Conversation and message CRUD operations."""

import logging
from datetime import datetime
from uuid import UUID

from pfn_mcp.db import execute, fetch_all, fetch_one, fetch_val

logger = logging.getLogger(__name__)


async def create_conversation(
    user_id: str,
    tenant_id: int,
    title: str | None = None,
    model: str = "claude-sonnet-4-20250514",
) -> dict:
    """
    Create a new conversation.

    Args:
        user_id: Keycloak subject ID
        tenant_id: Tenant ID for this conversation
        title: Optional title (can be set later)
        model: Model used for this conversation

    Returns:
        Created conversation dict with id, user_id, tenant_id, title, model, created_at
    """
    query = """
        INSERT INTO mcp.conversations (user_id, tenant_id, title, model)
        VALUES ($1, $2, $3, $4)
        RETURNING id, user_id, tenant_id, title, model, created_at, updated_at
    """
    result = await fetch_one(query, user_id, tenant_id, title, model)
    logger.info(f"Created conversation {result['id']} for user {user_id}")
    return result


async def get_conversation(conversation_id: UUID, user_id: str) -> dict | None:
    """
    Get a conversation by ID, verifying ownership.

    Args:
        conversation_id: Conversation UUID
        user_id: Keycloak subject ID (for ownership verification)

    Returns:
        Conversation dict or None if not found/not owned
    """
    query = """
        SELECT id, user_id, tenant_id, title, model, created_at, updated_at
        FROM mcp.conversations
        WHERE id = $1 AND user_id = $2
    """
    return await fetch_one(query, conversation_id, user_id)


async def list_conversations(
    user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> list[dict]:
    """
    List conversations for a user, ordered by most recent first.

    Args:
        user_id: Keycloak subject ID
        limit: Max number of conversations to return
        offset: Pagination offset

    Returns:
        List of conversation dicts with message preview
    """
    query = """
        SELECT
            c.id,
            c.user_id,
            c.tenant_id,
            c.title,
            c.model,
            c.created_at,
            c.updated_at,
            (SELECT COUNT(*) FROM mcp.messages WHERE conversation_id = c.id) as message_count
        FROM mcp.conversations c
        WHERE c.user_id = $1
        ORDER BY c.updated_at DESC
        LIMIT $2 OFFSET $3
    """
    return await fetch_all(query, user_id, limit, offset)


async def update_conversation_title(
    conversation_id: UUID,
    user_id: str,
    title: str,
) -> bool:
    """
    Update conversation title.

    Args:
        conversation_id: Conversation UUID
        user_id: Keycloak subject ID (for ownership verification)
        title: New title

    Returns:
        True if updated, False if not found/not owned
    """
    query = """
        UPDATE mcp.conversations
        SET title = $1
        WHERE id = $2 AND user_id = $3
    """
    result = await execute(query, title, conversation_id, user_id)
    return result == "UPDATE 1"


async def delete_conversation(conversation_id: UUID, user_id: str) -> bool:
    """
    Delete a conversation and all its messages.

    Args:
        conversation_id: Conversation UUID
        user_id: Keycloak subject ID (for ownership verification)

    Returns:
        True if deleted, False if not found/not owned
    """
    query = """
        DELETE FROM mcp.conversations
        WHERE id = $1 AND user_id = $2
    """
    result = await execute(query, conversation_id, user_id)
    if result == "DELETE 1":
        logger.info(f"Deleted conversation {conversation_id}")
        return True
    return False


async def add_message(
    conversation_id: UUID,
    role: str,
    content: str,
    tool_name: str | None = None,
    tool_call_id: str | None = None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
) -> dict:
    """
    Add a message to a conversation.

    Args:
        conversation_id: Conversation UUID
        role: Message role ('user', 'assistant', 'tool')
        content: Message content
        tool_name: Tool name (for tool messages)
        tool_call_id: Tool call ID (for tool messages)
        input_tokens: Token count for input
        output_tokens: Token count for output

    Returns:
        Created message dict
    """
    # Get next sequence number
    seq_query = """
        SELECT COALESCE(MAX(sequence), 0) + 1
        FROM mcp.messages
        WHERE conversation_id = $1
    """
    sequence = await fetch_val(seq_query, conversation_id)

    # Insert message
    query = """
        INSERT INTO mcp.messages
            (conversation_id, role, content, tool_name, tool_call_id,
             input_tokens, output_tokens, sequence)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id, conversation_id, role, content, tool_name, tool_call_id,
                  input_tokens, output_tokens, sequence, created_at
    """
    result = await fetch_one(
        query,
        conversation_id,
        role,
        content,
        tool_name,
        tool_call_id,
        input_tokens,
        output_tokens,
        sequence,
    )

    # Update conversation's updated_at
    await execute(
        "UPDATE mcp.conversations SET updated_at = NOW() WHERE id = $1",
        conversation_id,
    )

    return result


async def get_messages(
    conversation_id: UUID,
    user_id: str,
    limit: int | None = None,
) -> list[dict]:
    """
    Get all messages for a conversation, ordered by sequence.

    Args:
        conversation_id: Conversation UUID
        user_id: Keycloak subject ID (for ownership verification)
        limit: Optional limit on messages (from most recent)

    Returns:
        List of message dicts ordered by sequence
    """
    # First verify ownership
    ownership_query = """
        SELECT 1 FROM mcp.conversations
        WHERE id = $1 AND user_id = $2
    """
    if not await fetch_val(ownership_query, conversation_id, user_id):
        return []

    if limit:
        # Get most recent N messages
        query = """
            SELECT id, conversation_id, role, content, tool_name, tool_call_id,
                   input_tokens, output_tokens, sequence, created_at
            FROM mcp.messages
            WHERE conversation_id = $1
            ORDER BY sequence DESC
            LIMIT $2
        """
        messages = await fetch_all(query, conversation_id, limit)
        return list(reversed(messages))  # Return in chronological order
    else:
        query = """
            SELECT id, conversation_id, role, content, tool_name, tool_call_id,
                   input_tokens, output_tokens, sequence, created_at
            FROM mcp.messages
            WHERE conversation_id = $1
            ORDER BY sequence ASC
        """
        return await fetch_all(query, conversation_id)


async def get_tenant_id_by_code(tenant_code: str) -> int | None:
    """
    Get tenant ID from tenant code.

    Args:
        tenant_code: Tenant code (e.g., 'PRS')

    Returns:
        Tenant ID or None if not found
    """
    query = "SELECT id FROM public.tenants WHERE tenant_code = $1"
    return await fetch_val(query, tenant_code)


async def get_conversation_token_usage(conversation_id: UUID) -> dict:
    """
    Get total token usage for a conversation.

    Args:
        conversation_id: Conversation UUID

    Returns:
        Dict with total_input_tokens and total_output_tokens
    """
    query = """
        SELECT
            COALESCE(SUM(input_tokens), 0) as total_input_tokens,
            COALESCE(SUM(output_tokens), 0) as total_output_tokens
        FROM mcp.messages
        WHERE conversation_id = $1
    """
    result = await fetch_one(query, conversation_id)
    return result or {"total_input_tokens": 0, "total_output_tokens": 0}


async def get_user_token_usage(
    user_id: str,
    since: datetime | None = None,
) -> dict:
    """
    Get total token usage for a user.

    Args:
        user_id: Keycloak subject ID
        since: Optional start date for the period

    Returns:
        Dict with total_input_tokens, total_output_tokens, conversation_count
    """
    if since:
        query = """
            SELECT
                COALESCE(SUM(m.input_tokens), 0) as total_input_tokens,
                COALESCE(SUM(m.output_tokens), 0) as total_output_tokens,
                COUNT(DISTINCT c.id) as conversation_count
            FROM mcp.conversations c
            LEFT JOIN mcp.messages m ON m.conversation_id = c.id
            WHERE c.user_id = $1 AND c.created_at >= $2
        """
        return await fetch_one(query, user_id, since) or {
            "total_input_tokens": 0,
            "total_output_tokens": 0,
            "conversation_count": 0,
        }
    else:
        query = """
            SELECT
                COALESCE(SUM(m.input_tokens), 0) as total_input_tokens,
                COALESCE(SUM(m.output_tokens), 0) as total_output_tokens,
                COUNT(DISTINCT c.id) as conversation_count
            FROM mcp.conversations c
            LEFT JOIN mcp.messages m ON m.conversation_id = c.id
            WHERE c.user_id = $1
        """
        return await fetch_one(query, user_id) or {
            "total_input_tokens": 0,
            "total_output_tokens": 0,
            "conversation_count": 0,
        }
