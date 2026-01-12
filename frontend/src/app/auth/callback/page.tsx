'use client';

import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense, useEffect, useState } from 'react';

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { useAuth } from '@/contexts/AuthContext';
import { exchangeCode } from '@/lib/api';

function CallbackContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { login, isLoggedIn } = useAuth();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // If already logged in, redirect to chat
    if (isLoggedIn) {
      router.replace('/chat');
      return;
    }

    const code = searchParams.get('code');
    const errorParam = searchParams.get('error');
    const errorDescription = searchParams.get('error_description');

    if (errorParam) {
      setError(errorDescription || errorParam);
      return;
    }

    if (!code) {
      setError('No authorization code received');
      return;
    }

    // Exchange code for tokens
    exchangeCode(code)
      .then((response) => {
        login(response.access_token, response.user);
        router.replace('/chat');
      })
      .catch((err) => {
        console.error('Auth callback error:', err);
        setError(err.message || 'Authentication failed');
      });
  }, [searchParams, login, router, isLoggedIn]);

  if (error) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <div className="w-full max-w-md space-y-4">
          <Alert variant="destructive">
            <AlertTitle>Authentication Failed</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
          <Button
            onClick={() => router.push('/login')}
            variant="outline"
            className="w-full"
          >
            Back to Login
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-center">
        <div className="text-muted-foreground">Completing sign in...</div>
      </div>
    </div>
  );
}

export default function AuthCallbackPage() {
  return (
    <Suspense
      fallback={
        <div className="flex min-h-screen items-center justify-center">
          <div className="text-muted-foreground">Loading...</div>
        </div>
      }
    >
      <CallbackContent />
    </Suspense>
  );
}
