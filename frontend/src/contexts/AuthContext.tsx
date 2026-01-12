'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';

import {
  clearAuth,
  getToken,
  getUser,
  isAuthenticated,
  setAuth,
  updateUser,
} from '@/lib/auth';
import type { User } from '@/lib/types';

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  isLoggedIn: boolean;
  login: (token: string, user: User) => void;
  logout: () => void;
  setEffectiveTenant: (tenantCode: string | null) => void;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  // Check for existing auth on mount
  useEffect(() => {
    const checkAuth = () => {
      if (isAuthenticated()) {
        const storedUser = getUser();
        setUser(storedUser);
      } else {
        clearAuth();
        setUser(null);
      }
      setIsLoading(false);
    };

    checkAuth();
  }, []);

  const login = useCallback((token: string, userData: User) => {
    setAuth(token, userData);
    setUser(userData);
  }, []);

  const logout = useCallback(() => {
    clearAuth();
    setUser(null);
  }, []);

  const setEffectiveTenant = useCallback((tenantCode: string | null) => {
    if (!user) return;
    const updatedUser = { ...user, effective_tenant: tenantCode };
    updateUser({ effective_tenant: tenantCode });
    setUser(updatedUser);
  }, [user]);

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isLoggedIn: !!user && isAuthenticated(),
        login,
        logout,
        setEffectiveTenant,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
