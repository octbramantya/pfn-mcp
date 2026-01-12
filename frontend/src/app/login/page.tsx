'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { useAuth } from '@/contexts/AuthContext';
import { getLoginUrl } from '@/lib/api';

export default function LoginPage() {
  const router = useRouter();
  const { isLoggedIn, isLoading } = useAuth();

  // Redirect if already logged in
  useEffect(() => {
    if (!isLoading && isLoggedIn) {
      router.replace('/chat');
    }
  }, [isLoggedIn, isLoading, router]);

  const handleLogin = () => {
    window.location.href = getLoginUrl();
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
          <Button onClick={handleLogin} className="w-full" size="lg">
            Sign in with Keycloak
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
