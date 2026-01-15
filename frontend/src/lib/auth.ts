/**
 * JWT token management utilities
 */

import { User } from './types';

const TOKEN_KEY = 'pfn_chat_token';
const USER_KEY = 'pfn_chat_user';

/**
 * Store JWT token and user in localStorage
 */
export function setAuth(token: string, user: User): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(USER_KEY, JSON.stringify(user));
}

/**
 * Get stored JWT token
 */
export function getToken(): string | null {
  if (typeof window === 'undefined') return null;
  return localStorage.getItem(TOKEN_KEY);
}

/**
 * Get stored user data
 */
export function getUser(): User | null {
  if (typeof window === 'undefined') return null;
  const userJson = localStorage.getItem(USER_KEY);
  if (!userJson) return null;
  try {
    return JSON.parse(userJson) as User;
  } catch {
    return null;
  }
}

/**
 * Clear auth data (logout)
 */
export function clearAuth(): void {
  if (typeof window === 'undefined') return;
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
}

/**
 * Check if token is expired by decoding JWT payload
 */
export function isTokenExpired(token: string): boolean {
  try {
    const payload = token.split('.')[1];
    const decoded = JSON.parse(atob(payload));
    const exp = decoded.exp * 1000; // Convert to milliseconds
    return Date.now() > exp;
  } catch {
    return true;
  }
}

/**
 * Check if user is authenticated with valid token
 */
export function isAuthenticated(): boolean {
  const token = getToken();
  if (!token) return false;
  return !isTokenExpired(token);
}

/**
 * Update user data in storage (e.g., after tenant switch)
 */
export function updateUser(updates: Partial<User>): void {
  const user = getUser();
  if (!user) return;
  const updatedUser = { ...user, ...updates };
  localStorage.setItem(USER_KEY, JSON.stringify(updatedUser));
}

// =============================================================================
// Development Mode - Mock Authentication
// =============================================================================

/**
 * Check if dev auth mode is enabled
 */
export function isDevAuthEnabled(): boolean {
  return process.env.NEXT_PUBLIC_DEV_AUTH === 'true';
}

/**
 * Create a mock JWT token (valid for 24 hours)
 */
function createMockToken(user: User): string {
  const header = { alg: 'none', typ: 'JWT' };
  const payload = {
    sub: user.sub,
    email: user.email,
    name: user.name,
    tenant_code: user.tenant_code,
    is_superuser: user.is_superuser,
    groups: user.groups,
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 86400, // 24 hours
  };
  const encHeader = btoa(JSON.stringify(header));
  const encPayload = btoa(JSON.stringify(payload));
  return `${encHeader}.${encPayload}.mock-signature`;
}

/**
 * Mock user presets for development
 */
export const MOCK_USERS = {
  superuser: {
    sub: 'dev-superuser-001',
    email: 'admin@dev.local',
    name: 'Dev Admin',
    tenant_code: null,
    is_superuser: true,
    groups: ['superuser', 'PRS', 'PEN'],
    effective_tenant: null,
  } as User,
  tenant_prs: {
    sub: 'dev-user-prs-001',
    email: 'user.prs@dev.local',
    name: 'PRS User',
    tenant_code: 'PRS',
    is_superuser: false,
    groups: ['PRS'],
    effective_tenant: 'PRS',
  } as User,
  tenant_pen: {
    sub: 'dev-user-pen-001',
    email: 'user.pen@dev.local',
    name: 'PEN User',
    tenant_code: 'PEN',
    is_superuser: false,
    groups: ['PEN'],
    effective_tenant: 'PEN',
  } as User,
};

export type MockUserKey = keyof typeof MOCK_USERS;

/**
 * Login with a mock user (dev mode only)
 */
export function loginWithMockUser(userKey: MockUserKey): { token: string; user: User } {
  if (!isDevAuthEnabled()) {
    throw new Error('Mock auth is only available in dev mode');
  }
  const user = { ...MOCK_USERS[userKey] };
  const token = createMockToken(user);
  setAuth(token, user);
  return { token, user };
}
