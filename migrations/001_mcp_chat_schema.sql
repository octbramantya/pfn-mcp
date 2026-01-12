-- Migration: 001_mcp_chat_schema
-- Description: Create mcp schema for custom chat UI
-- Created: 2026-01-12

BEGIN;

-- Create schema
CREATE SCHEMA IF NOT EXISTS mcp;

-- Conversations (user-isolated)
-- user_id stores Keycloak subject ID (no FK - auth managed by Keycloak)
CREATE TABLE mcp.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(255) NOT NULL,
    tenant_id INTEGER NOT NULL REFERENCES public.tenants(id),
    title VARCHAR(255),
    model VARCHAR(100) DEFAULT 'claude-sonnet-4-20250514',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Messages
CREATE TABLE mcp.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES mcp.conversations(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL, -- 'user', 'assistant', 'tool_use', 'tool_result'
    content TEXT NOT NULL,
    tool_name VARCHAR(100),
    tool_call_id VARCHAR(100),
    input_tokens INTEGER,
    output_tokens INTEGER,
    sequence INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tenant branding
CREATE TABLE mcp.tenant_branding (
    tenant_id INTEGER PRIMARY KEY REFERENCES public.tenants(id),
    logo_url TEXT,
    primary_color VARCHAR(7),
    secondary_color VARCHAR(7),
    display_name VARCHAR(255),
    welcome_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for conversations
CREATE INDEX idx_conversations_user_id ON mcp.conversations(user_id);
CREATE INDEX idx_conversations_tenant_id ON mcp.conversations(tenant_id);
CREATE INDEX idx_conversations_updated_at ON mcp.conversations(updated_at DESC);

-- Indexes for messages
CREATE INDEX idx_messages_conversation_id ON mcp.messages(conversation_id);
CREATE INDEX idx_messages_sequence ON mcp.messages(conversation_id, sequence);

-- Trigger to update updated_at on conversations
CREATE OR REPLACE FUNCTION mcp.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER conversations_updated_at
    BEFORE UPDATE ON mcp.conversations
    FOR EACH ROW
    EXECUTE FUNCTION mcp.update_updated_at();

CREATE TRIGGER tenant_branding_updated_at
    BEFORE UPDATE ON mcp.tenant_branding
    FOR EACH ROW
    EXECUTE FUNCTION mcp.update_updated_at();

COMMIT;
