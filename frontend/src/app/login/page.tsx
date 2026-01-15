'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { useAuth } from '@/contexts/AuthContext';
import { getLoginUrl } from '@/lib/api';
import { isDevAuthEnabled, loginWithMockUser, MOCK_USERS, type MockUserKey } from '@/lib/auth';

export default function LoginPage() {
  const router = useRouter();
  const { isLoggedIn, isLoading, login } = useAuth();
  const devMode = isDevAuthEnabled();

  // Redirect if already logged in
  useEffect(() => {
    if (!isLoading && isLoggedIn) {
      router.replace('/chat');
    }
  }, [isLoggedIn, isLoading, router]);

  const handleKeycloakLogin = () => {
    window.location.href = getLoginUrl();
  };

  const handleDevLogin = (userKey: MockUserKey) => {
    const { token, user } = loginWithMockUser(userKey);
    login(token, user);
    router.replace('/chat');
  };

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <Card className="w-full max-w-md">
        <CardHeader className="text-center">
          <CardTitle className="text-2xl">PFN Chat</CardTitle>
          <CardDescription>
            Energy Monitoring Assistant
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <p className="text-center text-sm text-muted-foreground">
            Sign in with your organization account to start chatting with the
            energy monitoring assistant.
          </p>

          <Button onClick={handleKeycloakLogin} className="w-full" size="lg">
            Sign in with Keycloak
          </Button>

          {/* Dev mode login options */}
          {devMode && (
            <>
              <div className="relative my-2">
                <div className="absolute inset-0 flex items-center">
                  <span className="w-full border-t" />
                </div>
                <div className="relative flex justify-center text-xs uppercase">
                  <span className="bg-background px-2 text-muted-foreground">
                    Dev Mode
                  </span>
                </div>
              </div>

              <div className="grid gap-2">
                <Button
                  variant="outline"
                  onClick={() => handleDevLogin('superuser')}
                  className="w-full justify-start"
                >
                  <span className="mr-2 text-yellow-600">*</span>
                  {MOCK_USERS.superuser.name}
                  <span className="ml-auto text-xs text-muted-foreground">
                    Superuser
                  </span>
                </Button>
                <Button
                  variant="outline"
                  onClick={() => handleDevLogin('tenant_prs')}
                  className="w-full justify-start"
                >
                  {MOCK_USERS.tenant_prs.name}
                  <span className="ml-auto text-xs text-muted-foreground">
                    PRS
                  </span>
                </Button>
                <Button
                  variant="outline"
                  onClick={() => handleDevLogin('tenant_pen')}
                  className="w-full justify-start"
                >
                  {MOCK_USERS.tenant_pen.name}
                  <span className="ml-auto text-xs text-muted-foreground">
                    PEN
                  </span>
                </Button>
              </div>

              <p className="text-center text-xs text-muted-foreground">
                Dev mode enabled via NEXT_PUBLIC_DEV_AUTH
              </p>
            </>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
