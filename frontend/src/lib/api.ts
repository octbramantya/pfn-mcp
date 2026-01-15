/**
 * API client with authentication
 */

import { getToken, getUser } from './auth';
import type {
  Conversation,
  ConversationDetail,
  TokenResponse,
  UsageStats,
  User,
} from './types';

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8001';

/**
 * Get authorization headers including tenant context
 */
function getHeaders(): HeadersInit {
  const headers: HeadersInit = {
    'Content-Type': 'application/json',
  };

  const token = getToken();
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  // Add tenant context header for superusers
  const user = getUser();
  if (user?.is_superuser && user?.effective_tenant) {
    headers['X-Tenant-Context'] = user.effective_tenant;
  }

  return headers;
}

/**
 * Make authenticated API request
 */
async function fetchAPI<T>(
  endpoint: string,
  options: RequestInit = {}
): Promise<T> {
  const url = `${API_URL}${endpoint}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      ...getHeaders(),
      ...options.headers,
    },
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ detail: 'Request failed' }));
    throw new Error(error.detail || error.message || 'Request failed');
  }

  return response.json();
}

// =============================================================================
// Auth Endpoints
// =============================================================================

/**
 * Get login URL for OAuth redirect
 */
export function getLoginUrl(): string {
  const callbackUrl = `${window.location.origin}/auth/callback`;
  return `${API_URL}/api/auth/login?redirect_uri=${encodeURIComponent(callbackUrl)}`;
}

/**
 * Exchange authorization code for tokens
 */
export async function exchangeCode(code: string): Promise<TokenResponse> {
  const callbackUrl = `${window.location.origin}/auth/callback`;
  const url = `${API_URL}/api/auth/callback?code=${encodeURIComponent(code)}&redirect_uri=${encodeURIComponent(callbackUrl)}`;

  const response = await fetch(url);
  if (!response.ok) {
    const error = await response.json().catch(() => ({ detail: 'Auth failed' }));
    throw new Error(error.detail || 'Authentication failed');
  }

  return response.json();
}

/**
 * Get current user info
 */
export async function getCurrentUser(): Promise<User> {
  return fetchAPI<User>('/api/auth/me');
}

/**
 * Switch tenant context (superuser only)
 */
export async function switchTenant(tenantCode: string | null): Promise<void> {
  await fetchAPI('/api/auth/tenant', {
    method: 'PUT',
    body: JSON.stringify({ tenant_code: tenantCode }),
  });
}

// =============================================================================
// Conversation Endpoints
// =============================================================================

/**
 * List user's conversations
 */
export async function listConversations(
  limit = 50,
  offset = 0
): Promise<Conversation[]> {
  return fetchAPI<Conversation[]>(
    `/api/conversations?limit=${limit}&offset=${offset}`
  );
}

/**
 * Get conversation with messages
 */
export async function getConversation(id: string): Promise<ConversationDetail> {
  return fetchAPI<ConversationDetail>(`/api/conversations/${id}`);
}

/**
 * Delete conversation
 */
export async function deleteConversation(id: string): Promise<void> {
  await fetchAPI(`/api/conversations/${id}`, { method: 'DELETE' });
}

/**
 * Update conversation title
 */
export async function updateConversationTitle(
  id: string,
  title: string
): Promise<void> {
  await fetchAPI(`/api/conversations/${id}?title=${encodeURIComponent(title)}`, {
    method: 'PATCH',
  });
}

// =============================================================================
// Usage Endpoints
// =============================================================================

/**
 * Get usage statistics
 */
export async function getUsage(period = 'monthly'): Promise<UsageStats> {
  return fetchAPI<UsageStats>(`/api/usage?period=${period}`);
}

// =============================================================================
// Chat SSE
// =============================================================================

/**
 * Get chat endpoint URL for SSE
 */
export function getChatUrl(): string {
  return `${API_URL}/api/chat`;
}
