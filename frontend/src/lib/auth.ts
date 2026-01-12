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
