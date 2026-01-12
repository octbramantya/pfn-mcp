'use client';

import { useRouter } from 'next/navigation';
import { useEffect } from 'react';

import { useAuth } from '@/contexts/AuthContext';

export default function Home() {
  const router = useRouter();
  const { isLoggedIn, isLoading } = useAuth();

  useEffect(() => {
    if (!isLoading) {
      if (isLoggedIn) {
        router.replace('/chat');
      } else {
        router.replace('/login');
      }
    }
  }, [isLoggedIn, isLoading, router]);

  // Show loading state while checking auth
  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-muted-foreground">Loading...</div>
    </div>
  );
}
