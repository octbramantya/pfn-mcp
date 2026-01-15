'use client';

import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';

import { ConversationList } from '@/components/ConversationList';
import { TenantSelector } from '@/components/TenantSelector';
import { UsageMeter } from '@/components/UsageMeter';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { useAuth } from '@/contexts/AuthContext';
import { ConversationsProvider, useConversations } from '@/contexts/ConversationsContext';

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
    <ConversationsProvider>
      <ChatLayoutInner
        sidebarOpen={sidebarOpen}
        setSidebarOpen={setSidebarOpen}
        user={user}
        logout={logout}
      >
        {children}
      </ChatLayoutInner>
    </ConversationsProvider>
  );
}

function ChatLayoutInner({
  children,
  sidebarOpen,
  setSidebarOpen,
  user,
  logout,
}: {
  children: React.ReactNode;
  sidebarOpen: boolean;
  setSidebarOpen: (open: boolean) => void;
  user: { email?: string; is_superuser?: boolean; effective_tenant?: string } | null;
  logout: () => void;
}) {
  const { startNewChat } = useConversations();

  return (
    <div className="flex h-screen bg-background">
      {/* Sidebar */}
      <aside
        className={`${
          sidebarOpen ? 'w-72' : 'w-0'
        } flex flex-col border-r border-border/40 bg-sidebar transition-all duration-300 overflow-hidden`}
      >
        {/* Sidebar Header with New Chat */}
        <div className="flex h-12 items-center justify-between px-4">
          <span className="font-medium text-sidebar-foreground tracking-tight">PFN Chat</span>
          <Button
            variant="ghost"
            size="icon"
            onClick={startNewChat}
            className="h-7 w-7 text-muted-foreground hover:text-foreground hover:bg-sidebar-accent"
            title="New Chat"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="h-4 w-4"
            >
              <path d="M12 5v14M5 12h14" />
            </svg>
          </Button>
        </div>

        {/* Conversations */}
        <div className="flex-1 overflow-y-auto overflow-x-hidden">
          <ConversationList />
        </div>

        {/* User Info */}
        <div className="p-4 space-y-3">
          <UsageMeter />
          <div className="flex items-center justify-between">
            <div className="text-sm text-muted-foreground truncate flex-1 mr-2">
              {user?.email}
            </div>
            <Button
              variant="ghost"
              size="sm"
              className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
              onClick={logout}
            >
              Sign Out
            </Button>
          </div>
          {user?.is_superuser && (
            <div className="text-xs text-muted-foreground/70">
              Tenant: {user?.effective_tenant || 'All'}
            </div>
          )}
        </div>
      </aside>

      {/* Main Content */}
      <main className="flex flex-1 flex-col overflow-hidden">
        {/* Header */}
        <header className="flex h-12 items-center justify-between px-4 border-b border-border/40">
          <div className="flex items-center gap-3">
            <Button
              variant="ghost"
              size="icon"
              onClick={() => setSidebarOpen(!sidebarOpen)}
              className="h-8 w-8 text-muted-foreground hover:text-foreground"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="h-4 w-4"
              >
                <path d="M3 12h18M3 6h18M3 18h18" />
              </svg>
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
