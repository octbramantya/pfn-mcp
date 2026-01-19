'use client';

import {
  createContext,
  useCallback,
  useContext,
  useState,
  type ReactNode,
} from 'react';
import useSWR from 'swr';

import { swrFetcher } from '@/lib/swr';
import type { Conversation } from '@/lib/types';

interface ConversationsContextType {
  conversations: Conversation[];
  isLoading: boolean;
  refresh: () => Promise<void>;
  activeConversationId: string | null;
  setActiveConversationId: (id: string | null) => void;
  startNewChat: () => void;
  isNewChat: boolean;
  clearNewChatFlag: () => void;
  updateConversationTitle: (id: string, title: string) => void;
}

const ConversationsContext = createContext<ConversationsContextType | undefined>(undefined);

export function ConversationsProvider({ children }: { children: ReactNode }) {
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [isNewChat, setIsNewChat] = useState(false);

  // Use SWR for automatic deduplication and caching
  const {
    data: conversations,
    isLoading,
    mutate,
  } = useSWR<Conversation[]>(
    '/api/conversations?limit=50&offset=0',
    swrFetcher,
    {
      revalidateOnFocus: false,
      dedupingInterval: 2000,
    }
  );

  const refresh = useCallback(async () => {
    await mutate();
  }, [mutate]);

  const startNewChat = useCallback(() => {
    setActiveConversationId(null);
    setIsNewChat(true);
  }, []);

  const clearNewChatFlag = useCallback(() => {
    setIsNewChat(false);
  }, []);

  const updateConversationTitle = useCallback((id: string, title: string) => {
    // Optimistically update the cache
    mutate(
      (current) => current?.map((c) => (c.id === id ? { ...c, title } : c)),
      { revalidate: false }
    );
  }, [mutate]);

  return (
    <ConversationsContext.Provider
      value={{
        conversations: conversations ?? [],
        isLoading,
        refresh,
        activeConversationId,
        setActiveConversationId,
        startNewChat,
        isNewChat,
        clearNewChatFlag,
        updateConversationTitle,
      }}
    >
      {children}
    </ConversationsContext.Provider>
  );
}

export function useConversations() {
  const context = useContext(ConversationsContext);
  if (context === undefined) {
    throw new Error('useConversations must be used within a ConversationsProvider');
  }
  return context;
}
