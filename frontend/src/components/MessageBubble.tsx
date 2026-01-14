'use client';

import { useMemo, useState } from 'react';
import ReactMarkdown from 'react-markdown';

import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import type { Message, ToolCallDisplay } from '@/lib/types';

interface MessageBubbleProps {
  message: Message;
  toolCalls?: ToolCallDisplay[];
  isStreaming?: boolean;
}

/**
 * Process content to handle <think> blocks from models like MiniMax.
 * Returns the visible content and whether thinking is in progress.
 */
function processThinkBlocks(content: string, isStreaming: boolean): {
  displayContent: string;
  isThinking: boolean;
} {
  // Check if we're in the middle of a <think> block (streaming)
  const hasOpenThink = content.includes('<think>');
  const hasCloseThink = content.includes('</think>');
  const isThinking = isStreaming && hasOpenThink && !hasCloseThink;

  // Remove completed <think>...</think> blocks
  const displayContent = content
    .replace(/<think>[\s\S]*?<\/think>\s*/g, '')
    // Also remove incomplete <think> block if streaming
    .replace(/<think>[\s\S]*$/g, '')
    .trim();

  return { displayContent, isThinking };
}

export function MessageBubble({
  message,
  toolCalls = [],
  isStreaming = false,
}: MessageBubbleProps) {
  const isUser = message.role === 'user';

  // Process think blocks for assistant messages
  const { displayContent, isThinking } = useMemo(() => {
    if (isUser) {
      return { displayContent: message.content, isThinking: false };
    }
    return processThinkBlocks(message.content, isStreaming);
  }, [message.content, isStreaming, isUser]);

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
        {/* Thinking indicator */}
        {isThinking && (
          <div className="flex items-center gap-2 text-muted-foreground text-sm">
            <span className="w-3 h-3 border-2 border-current border-t-transparent rounded-full animate-spin" />
            Thinking...
          </div>
        )}

        {/* Message card - only show if there's content or not thinking */}
        {(displayContent || !isThinking) && (
          <Card
            className={`p-3 ${
              isUser
                ? 'bg-primary text-primary-foreground'
                : 'bg-card text-card-foreground'
            }`}
          >
            {/* Message content */}
            {isUser ? (
              <div className="whitespace-pre-wrap break-words">
                {displayContent || message.content}
              </div>
            ) : (
              <div className="prose prose-sm dark:prose-invert max-w-none break-words">
                <ReactMarkdown>
                  {displayContent || (isStreaming ? '' : message.content)}
                </ReactMarkdown>
                {isStreaming && !isThinking && (
                  <span className="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
                )}
              </div>
            )}
          </Card>
        )}

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
