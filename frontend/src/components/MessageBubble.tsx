'use client';

import { useMemo, useState } from 'react';
import ReactMarkdown from 'react-markdown';

import { Button } from '@/components/ui/button';
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
      {/* Avatar - smaller, more subtle */}
      <div
        className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-medium shrink-0 mt-1 ${
          isUser
            ? 'bg-secondary text-secondary-foreground'
            : 'bg-primary/10 text-primary'
        }`}
      >
        {isUser ? 'U' : 'A'}
      </div>

      {/* Content */}
      <div className={`flex flex-col gap-3 max-w-[85%] ${isUser ? 'items-end' : 'items-start'}`}>
        {/* Thinking indicator */}
        {isThinking && (
          <div className="flex items-center gap-2 text-muted-foreground text-sm">
            <span className="w-3 h-3 border-2 border-current border-t-transparent rounded-full animate-spin" />
            Thinking...
          </div>
        )}

        {/* Message content - only show if there's content or not thinking */}
        {(displayContent || !isThinking) && (
          <>
            {isUser ? (
              /* User message - subtle pill bubble */
              <div className="bg-secondary text-secondary-foreground px-4 py-3 rounded-2xl rounded-tr-md whitespace-pre-wrap break-words leading-relaxed">
                {displayContent || message.content}
              </div>
            ) : (
              /* AI message - no bubble, flows naturally */
              <div className="prose dark:prose-invert max-w-none break-words">
                <ReactMarkdown>
                  {displayContent || (isStreaming ? '' : message.content)}
                </ReactMarkdown>
                {isStreaming && !isThinking && (
                  <span className="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
                )}
              </div>
            )}
          </>
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
    <div className="border border-border/50 rounded-lg p-3 text-sm bg-muted/30">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-muted-foreground">
          {tool.isLoading ? (
            <span className="w-3 h-3 border-2 border-current border-t-transparent rounded-full animate-spin" />
          ) : (
            <span className="text-primary">✓</span>
          )}
          <span className="font-mono text-xs">{tool.name}</span>
        </div>
        {tool.result && (
          <Button
            variant="ghost"
            size="sm"
            className="h-6 px-2 text-xs text-muted-foreground hover:text-foreground"
            onClick={() => setExpanded(!expanded)}
          >
            {expanded ? 'Hide' : 'Show'}
          </Button>
        )}
      </div>
      {expanded && tool.result && (
        <pre className="mt-3 p-3 bg-muted rounded-md text-xs overflow-x-auto max-h-40 overflow-y-auto">
          {tool.result}
        </pre>
      )}
    </div>
  );
}
