'use client';

import { useState } from 'react';

import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import type { Message, ToolCallDisplay } from '@/lib/types';

interface MessageBubbleProps {
  message: Message;
  toolCalls?: ToolCallDisplay[];
  isStreaming?: boolean;
}

export function MessageBubble({
  message,
  toolCalls = [],
  isStreaming = false,
}: MessageBubbleProps) {
  const isUser = message.role === 'user';

  return (
    <div className={`flex gap-3 ${isUser ? 'flex-row-reverse' : ''}`}>
      {/* Avatar */}
      <div
        className={`w-8 h-8 rounded-full flex items-center justify-center text-sm shrink-0 ${
          isUser
            ? 'bg-secondary text-secondary-foreground'
            : 'bg-primary text-primary-foreground'
        }`}
      >
        {isUser ? 'U' : 'AI'}
      </div>

      {/* Content */}
      <div className={`flex flex-col gap-2 max-w-[80%] ${isUser ? 'items-end' : ''}`}>
        <Card
          className={`p-3 ${
            isUser
              ? 'bg-primary text-primary-foreground'
              : 'bg-card text-card-foreground'
          }`}
        >
          {/* Message content */}
          <div className="whitespace-pre-wrap break-words">
            {message.content}
            {isStreaming && (
              <span className="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
            )}
          </div>
        </Card>

        {/* Tool calls */}
        {toolCalls.length > 0 && (
          <div className="flex flex-col gap-2 w-full">
            {toolCalls.map((tool, index) => (
              <ToolCallCard key={`${tool.call_id}-${index}`} tool={tool} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function ToolCallCard({ tool }: { tool: ToolCallDisplay }) {
  const [expanded, setExpanded] = useState(false);

  return (
    <Card className="p-2 bg-muted/50 text-sm">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          {tool.isLoading ? (
            <span className="w-3 h-3 border-2 border-current border-t-transparent rounded-full animate-spin" />
          ) : (
            <span className="text-green-600">✓</span>
          )}
          <span className="font-mono text-xs">{tool.name}</span>
        </div>
        {tool.result && (
          <Button
            variant="ghost"
            size="sm"
            className="h-6 px-2 text-xs"
            onClick={() => setExpanded(!expanded)}
          >
            {expanded ? 'Hide' : 'Show'}
          </Button>
        )}
      </div>
      {expanded && tool.result && (
        <pre className="mt-2 p-2 bg-background rounded text-xs overflow-x-auto max-h-40 overflow-y-auto">
          {tool.result}
        </pre>
      )}
    </Card>
  );
}
