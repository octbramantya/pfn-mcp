'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

import { ChatInput } from '@/components/ChatInput';
import { ChatMessages } from '@/components/ChatMessages';
import { getConversation, listConversations } from '@/lib/api';
import { streamChat } from '@/lib/sse';
import type { ChatEvent, Message, StreamingMessage, ToolCallDisplay } from '@/lib/types';

export default function ChatPage() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [streamingMessage, setStreamingMessage] = useState<StreamingMessage | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const abortControllerRef = useRef<AbortController | null>(null);

  // Load most recent conversation on mount
  useEffect(() => {
    const loadRecentConversation = async () => {
      try {
        const conversations = await listConversations(1);
        if (conversations.length > 0) {
          const recent = conversations[0];
          const detail = await getConversation(recent.id);
          setConversationId(detail.id);
          // Filter out tool messages for display (they're shown inline)
          setMessages(detail.messages.filter((m) => m.role !== 'tool'));
        }
      } catch (error) {
        console.error('Failed to load recent conversation:', error);
      }
    };

    loadRecentConversation();
  }, []);

  const handleSendMessage = useCallback(
    async (content: string) => {
      if (isLoading) return;

      setIsLoading(true);

      // Add user message optimistically
      const userMessage: Message = {
        id: `temp-${Date.now()}`,
        role: 'user',
        content,
        sequence: messages.length,
        created_at: new Date().toISOString(),
      };
      setMessages((prev) => [...prev, userMessage]);

      // Initialize streaming message
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
          handleStreamEvent(event, (id) => {
            newConversationId = id;
            setConversationId(id);
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
        // Finalize streaming message
        setStreamingMessage((prev) => {
          if (prev && prev.content) {
            const finalMessage: Message = {
              id: `msg-${Date.now()}`,
              role: 'assistant',
              content: prev.content,
              sequence: messages.length + 1,
              created_at: new Date().toISOString(),
            };
            setMessages((msgs) => [...msgs, finalMessage]);
          }
          return null;
        });
        setIsLoading(false);
        abortControllerRef.current = null;
      }
    },
    [conversationId, isLoading, messages.length]
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

  const handleNewConversation = useCallback(() => {
    setConversationId(null);
    setMessages([]);
    setStreamingMessage(null);
  }, []);

  return (
    <div className="flex h-full flex-col">
      {/* Messages Area */}
      <div className="flex-1 overflow-hidden">
        <ChatMessages
          messages={messages}
          streamingMessage={streamingMessage}
          isLoading={isLoading}
        />
      </div>

      {/* Input Area */}
      <div className="border-t p-4">
        <ChatInput
          onSend={handleSendMessage}
          onStop={handleStopGeneration}
          onNewChat={handleNewConversation}
          isLoading={isLoading}
          disabled={false}
        />
      </div>
    </div>
  );
}
