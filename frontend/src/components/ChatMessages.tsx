'use client';

import { useEffect, useRef } from 'react';

import { MessageBubble } from '@/components/MessageBubble';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import type { Message, StreamingMessage } from '@/lib/types';

interface ChatMessagesProps {
  messages: Message[];
  streamingMessage: StreamingMessage | null;
  isLoading: boolean;
}

export function ChatMessages({
  messages,
  streamingMessage,
  isLoading,
}: ChatMessagesProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new content arrives
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, streamingMessage?.content]);

  if (messages.length === 0 && !streamingMessage) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="text-center">
          <h2 className="text-xl font-semibold text-foreground mb-2">
            Welcome to PFN Chat
          </h2>
          <p className="text-muted-foreground max-w-md">
            Ask me about energy consumption, electricity costs, power demand, or
            any other data from your power meters.
          </p>
        </div>
      </div>
    );
  }

  return (
    <ScrollArea className="h-full" ref={scrollRef}>
      <div className="flex flex-col gap-4 p-4 max-w-4xl mx-auto">
        {messages.map((message) => (
          <MessageBubble key={message.id} message={message} />
        ))}

        {/* Streaming message */}
        {streamingMessage && (
          <MessageBubble
            message={{
              id: 'streaming',
              role: 'assistant',
              content: streamingMessage.content,
              sequence: messages.length,
              created_at: new Date().toISOString(),
            }}
            toolCalls={streamingMessage.toolCalls}
            isStreaming={streamingMessage.isStreaming}
          />
        )}

        {/* Loading indicator when waiting for first chunk */}
        {isLoading && !streamingMessage?.content && (
          <div className="flex gap-3">
            <div className="w-8 h-8 rounded-full bg-primary flex items-center justify-center text-primary-foreground text-sm">
              AI
            </div>
            <div className="flex-1 space-y-2">
              <Skeleton className="h-4 w-3/4" />
              <Skeleton className="h-4 w-1/2" />
            </div>
          </div>
        )}

        {/* Scroll anchor */}
        <div ref={bottomRef} />
      </div>
    </ScrollArea>
  );
}
