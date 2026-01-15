/**
 * TypeScript interfaces for the PFN Chat UI
 */

// User context from JWT
export interface User {
  sub: string;
  email: string;
  name: string;
  tenant_code: string | null;
  is_superuser: boolean;
  effective_tenant: string | null;
  groups: string[];
  branding?: TenantBranding | null;
}

// Tenant branding configuration
export interface TenantBranding {
  logo_url?: string | null;
  primary_color?: string | null;
  secondary_color?: string | null;
  display_name?: string | null;
  welcome_message?: string | null;
}

// Token response from OAuth callback
export interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  user: User;
}

// Conversation list item
export interface Conversation {
  id: string;
  title: string | null;
  model: string;
  created_at: string;
  updated_at: string;
  message_count: number;
}

// Tool call from LLM (stored in assistant messages)
export interface ToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string; // JSON string of parameters
  };
}

// Message in a conversation
export interface Message {
  id: string;
  role: 'user' | 'assistant' | 'tool';
  content: string;
  tool_name?: string | null;
  tool_call_id?: string | null;
  tool_calls?: ToolCall[] | null; // Tool calls made by assistant
  input_tokens?: number | null;
  output_tokens?: number | null;
  sequence: number;
  created_at: string;
}

// Conversation with messages
export interface ConversationDetail extends Conversation {
  messages: Message[];
}

// Usage statistics
export interface UsageStats {
  total_input_tokens: number;
  total_output_tokens: number;
  total_tokens: number;
  conversation_count: number;
  period_start: string;
  period_end: string;
  budget_used_percent: number | null;
  budget_remaining_percent: number | null;
  is_over_budget: boolean;
  is_near_limit: boolean;
}

// SSE Event types
export type ChatEvent =
  | { type: 'conversation'; id: string; title: string | null; is_new: boolean }
  | { type: 'content'; text: string }
  | { type: 'tool_call'; name: string; call_id: string }
  | { type: 'tool_result'; name: string; result: string }
  | { type: 'done'; input_tokens: number; output_tokens: number }
  | { type: 'error'; message: string };

// Chat request
export interface ChatRequest {
  message: string;
  conversation_id?: string | null;
}

// Streaming message for UI state
export interface StreamingMessage {
  role: 'assistant';
  content: string;
  isStreaming: boolean;
  toolCalls: ToolCallDisplay[];
}

// Tool call display in UI
export interface ToolCallDisplay {
  name: string;
  call_id: string;
  result?: string;
  isLoading: boolean;
}
