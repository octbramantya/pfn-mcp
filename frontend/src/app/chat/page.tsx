'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

import { ChatInput } from '@/components/ChatInput';
import { ChatMessages } from '@/components/ChatMessages';
import { useConversations } from '@/contexts/ConversationsContext';
import { getConversation } from '@/lib/api';
import { streamChat } from '@/lib/sse';
import type { ChatEvent, Message, StreamingMessage, ToolCallDisplay } from '@/lib/types';

// Generate unique IDs
let messageIdCounter = 0;
function generateMessageId(prefix: string): string {
  return `${prefix}-${Date.now()}-${++messageIdCounter}`;
}

export default function ChatPage() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [streamingMessage, setStreamingMessage] = useState<StreamingMessage | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const abortControllerRef = useRef<AbortController | null>(null);
  const streamingContentRef = useRef<string>('');

  const { conversations, refresh, activeConversationId, setActiveConversationId, isNewChat, clearNewChatFlag } = useConversations();

  // Load conversation when active conversation changes
  useEffect(() => {
    const loadConversation = async () => {
      if (activeConversationId) {
        clearNewChatFlag(); // User selected a conversation, reset new chat flag
        try {
          const detail = await getConversation(activeConversationId);
          setConversationId(detail.id);
          // Filter out tool messages for display (they're shown inline)
          setMessages(detail.messages.filter((m) => m.role !== 'tool'));
        } catch (error) {
          console.error('Failed to load conversation:', error);
        }
      } else if (isNewChat) {
        // New chat requested - clear messages
        setConversationId(null);
        setMessages([]);
        setStreamingMessage(null);
      }
    };

    loadConversation();
  }, [activeConversationId, isNewChat, clearNewChatFlag]);

  // Load most recent conversation on mount (but not if user started new chat)
  useEffect(() => {
    if (conversations.length > 0 && !activeConversationId && !isNewChat) {
      setActiveConversationId(conversations[0].id);
    }
  }, [conversations, activeConversationId, setActiveConversationId, isNewChat]);

  const handleSendMessage = useCallback(
    async (content: string) => {
      if (isLoading) return;

      setIsLoading(true);

      // Add user message optimistically
      const userMessage: Message = {
        id: generateMessageId('user'),
        role: 'user',
        content,
        sequence: messages.length,
        created_at: new Date().toISOString(),
      };
      setMessages((prev) => [...prev, userMessage]);

      // Initialize streaming message
      streamingContentRef.current = '';
      setStreamingMessage({
        role: 'assistant',
        content: '',
        isStreaming: true,
        toolCalls: [],
      });

      // Create abort controller for this request
      abortControllerRef.current = new AbortController();

      try {
        let newConversationId = conversationId;

        for await (const event of streamChat(
          { message: content, conversation_id: conversationId },
          abortControllerRef.current.signal
        )) {
          handleStreamEvent(event, async (id) => {
            newConversationId = id;
            setConversationId(id);
            setActiveConversationId(id);
            clearNewChatFlag(); // Conversation created, reset flag
            // Refresh conversation list to show new conversation
            await refresh();
          });
        }
      } catch (error) {
        if ((error as Error).name !== 'AbortError') {
          console.error('Chat error:', error);
          setStreamingMessage((prev) =>
            prev
              ? {
                  ...prev,
                  content: prev.content + '\n\nError: ' + (error as Error).message,
                  isStreaming: false,
                }
              : null
          );
        }
      } finally {
        // Finalize streaming message - use ref to avoid side effects in state updater
        const finalContent = streamingContentRef.current;
        if (finalContent) {
          const finalMessage: Message = {
            id: generateMessageId('assistant'),
            role: 'assistant',
            content: finalContent,
            sequence: messages.length + 1,
            created_at: new Date().toISOString(),
          };
          setMessages((msgs) => [...msgs, finalMessage]);
        }
        streamingContentRef.current = '';
        setStreamingMessage(null);
        setIsLoading(false);
        abortControllerRef.current = null;
      }
    },
    [conversationId, isLoading, messages.length, refresh, setActiveConversationId]
  );

  const handleStreamEvent = (
    event: ChatEvent,
    onConversationId: (id: string) => void
  ) => {
    switch (event.type) {
      case 'conversation':
        if (event.is_new) {
          onConversationId(event.id);
        }
        break;

      case 'content':
        streamingContentRef.current += event.text;
        setStreamingMessage((prev) =>
          prev
            ? { ...prev, content: prev.content + event.text }
            : { role: 'assistant', content: event.text, isStreaming: true, toolCalls: [] }
        );
        break;

      case 'tool_call':
        setStreamingMessage((prev) => {
          if (!prev) return prev;
          const toolCall: ToolCallDisplay = {
            name: event.name,
            call_id: event.call_id,
            isLoading: true,
          };
          return { ...prev, toolCalls: [...prev.toolCalls, toolCall] };
        });
        break;

      case 'tool_result':
        setStreamingMessage((prev) => {
          if (!prev) return prev;
          const updatedTools = prev.toolCalls.map((tc) =>
            tc.name === event.name && tc.isLoading
              ? { ...tc, result: event.result, isLoading: false }
              : tc
          );
          return { ...prev, toolCalls: updatedTools };
        });
        break;

      case 'done':
        setStreamingMessage((prev) =>
          prev ? { ...prev, isStreaming: false } : null
        );
        break;

      case 'error':
        setStreamingMessage((prev) =>
          prev
            ? {
                ...prev,
                content: prev.content + (prev.content ? '\n\n' : '') + 'Error: ' + event.message,
                isStreaming: false,
              }
            : null
        );
        break;
    }
  };

  const handleStopGeneration = useCallback(() => {
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
    }
  }, []);

  return (
    <div className="flex h-full flex-col">
      {/* Messages Area */}
      <div className="flex-1 overflow-hidden">
        <ChatMessages
          messages={messages}
          streamingMessage={streamingMessage}
          isLoading={isLoading}
          onSendMessage={handleSendMessage}
        />
      </div>

      {/* Input Area */}
      <div className="border-t p-6">
        <ChatInput
          onSend={handleSendMessage}
          onStop={handleStopGeneration}
          isLoading={isLoading}
          disabled={false}
        />
      </div>
    </div>
  );
}
