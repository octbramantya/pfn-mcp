'use client';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react';

import { listConversations } from '@/lib/api';
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
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null);
  const [isNewChat, setIsNewChat] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const data = await listConversations(50);
      setConversations(data);
    } catch (error) {
      console.error('Failed to load conversations:', error);
    } finally {
      setIsLoading(false);
    }
  }, []);

  const startNewChat = useCallback(() => {
    setActiveConversationId(null);
    setIsNewChat(true);
  }, []);

  const clearNewChatFlag = useCallback(() => {
    setIsNewChat(false);
  }, []);

  const updateConversationTitle = useCallback((id: string, title: string) => {
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, title } : c))
    );
  }, []);

  // Load conversations on mount
  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <ConversationsContext.Provider
      value={{
        conversations,
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
