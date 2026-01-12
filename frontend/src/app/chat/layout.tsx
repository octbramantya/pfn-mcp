'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';

import { ConversationList } from '@/components/ConversationList';
import { TenantSelector } from '@/components/TenantSelector';
import { UsageMeter } from '@/components/UsageMeter';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { useAuth } from '@/contexts/AuthContext';

export default function ChatLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const router = useRouter();
  const { isLoggedIn, isLoading, user, logout } = useAuth();
  const [sidebarOpen, setSidebarOpen] = useState(true);

  // Redirect to login if not authenticated
  useEffect(() => {
    if (!isLoading && !isLoggedIn) {
      router.replace('/login');
    }
  }, [isLoggedIn, isLoading, router]);

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  if (!isLoggedIn) {
    return null;
  }

  return (
    <div className="flex h-screen bg-background">
      {/* Sidebar */}
      <aside
        className={`${
          sidebarOpen ? 'w-64' : 'w-0'
        } flex flex-col border-r bg-sidebar transition-all duration-300 overflow-hidden`}
      >
        {/* Sidebar Header */}
        <div className="flex h-14 items-center justify-between border-b px-4">
          <span className="font-semibold text-sidebar-foreground">PFN Chat</span>
        </div>

        {/* Conversations */}
        <ScrollArea className="flex-1">
          <ConversationList />
        </ScrollArea>

        {/* User Info */}
        <div className="border-t p-4 space-y-3">
          <UsageMeter />
          <div className="text-sm text-muted-foreground truncate">
            {user?.email}
          </div>
          {user?.is_superuser && (
            <div className="text-xs text-muted-foreground">
              Tenant: {user?.effective_tenant || 'All'}
            </div>
          )}
          <Button
            variant="outline"
            size="sm"
            className="w-full"
            onClick={logout}
          >
            Sign Out
          </Button>
        </div>
      </aside>

      {/* Main Content */}
      <main className="flex flex-1 flex-col overflow-hidden">
        {/* Header */}
        <header className="flex h-14 items-center justify-between border-b px-4">
          <div className="flex items-center">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setSidebarOpen(!sidebarOpen)}
              className="mr-4"
            >
              {sidebarOpen ? '←' : '→'}
            </Button>
            <span className="text-sm text-muted-foreground">
              Energy Monitoring Assistant
            </span>
          </div>
          <TenantSelector />
        </header>

        {/* Chat Area */}
        <div className="flex-1 overflow-hidden">{children}</div>
      </main>
    </div>
  );
}
