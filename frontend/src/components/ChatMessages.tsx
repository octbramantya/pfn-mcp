'use client';

import { useEffect, useRef, useMemo } from 'react';

import { MessageBubble } from '@/components/MessageBubble';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import { useAuth } from '@/contexts/AuthContext';
import type { Message, StreamingMessage } from '@/lib/types';

// Slash commands from workflows.md
const QUICK_ACTIONS = [
  { command: '/daily-digest', label: 'Daily digest', description: "Yesterday's energy summary" },
  { command: '/weekly-summary', label: 'Weekly summary', description: 'Top consumers & trends' },
  { command: '/peak-report', label: 'Peak report', description: 'Peak power analysis' },
  { command: '/dept-breakdown', label: 'Breakdown', description: 'By department/process' },
];

function getGreeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

function getFirstName(fullName: string): string {
  return fullName.split(' ')[0];
}

interface ChatMessagesProps {
  messages: Message[];
  streamingMessage: StreamingMessage | null;
  isLoading: boolean;
  onSendMessage?: (message: string) => void;
}

export function ChatMessages({
  messages,
  streamingMessage,
  isLoading,
  onSendMessage,
}: ChatMessagesProps) {
  const { user } = useAuth();
  const scrollRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);

  const greeting = useMemo(() => getGreeting(), []);
  const firstName = useMemo(
    () => (user?.name ? getFirstName(user.name) : ''),
    [user?.name]
  );

  // Auto-scroll to bottom when new content arrives
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, streamingMessage?.content]);

  if (messages.length === 0 && !streamingMessage) {
    return (
      <div className="flex h-full items-center justify-center px-6">
        <div className="text-center max-w-lg">
          <h2 className="text-2xl font-medium text-foreground mb-3">
            {greeting}{firstName && `, ${firstName}`}
          </h2>
          <p className="text-muted-foreground text-base mb-6">
            How can I help you with energy monitoring today?
          </p>

          {/* Quick action buttons */}
          <div className="flex flex-wrap justify-center gap-2">
            {QUICK_ACTIONS.map((action) => (
              <button
                key={action.command}
                onClick={() => onSendMessage?.(action.command)}
                className="inline-flex items-center gap-2 px-3 py-2 rounded-lg border border-border bg-background hover:bg-accent hover:border-accent-foreground/20 transition-colors text-sm"
                title={action.description}
              >
                <span className="text-muted-foreground font-mono text-xs">{action.command}</span>
                <span className="text-foreground">{action.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    );
  }

  return (
    <ScrollArea className="h-full" ref={scrollRef}>
      <div className="flex flex-col gap-6 p-6 max-w-3xl mx-auto">
        {messages.map((message) => (
          <div key={message.id} className="message-item">
            <MessageBubble message={message} />
          </div>
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
            <div className="w-6 h-6 rounded-full bg-primary/10 flex items-center justify-center text-primary text-xs font-medium mt-1">
              A
            </div>
            <div className="flex-1 space-y-2 pt-1">
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
