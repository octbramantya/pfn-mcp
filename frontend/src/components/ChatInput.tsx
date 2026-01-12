'use client';

import { useRef, useState } from 'react';

import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';

interface ChatInputProps {
  onSend: (message: string) => void;
  onStop: () => void;
  onNewChat: () => void;
  isLoading: boolean;
  disabled: boolean;
}

export function ChatInput({
  onSend,
  onStop,
  onNewChat,
  isLoading,
  disabled,
}: ChatInputProps) {
  const [input, setInput] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const handleSubmit = () => {
    const trimmed = input.trim();
    if (!trimmed || isLoading || disabled) return;

    onSend(trimmed);
    setInput('');

    // Reset textarea height
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto';
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const handleChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setInput(e.target.value);

    // Auto-resize textarea
    const textarea = e.target;
    textarea.style.height = 'auto';
    textarea.style.height = Math.min(textarea.scrollHeight, 200) + 'px';
  };

  return (
    <div className="flex flex-col gap-2 max-w-4xl mx-auto">
      <div className="flex gap-2">
        <Button variant="outline" size="sm" onClick={onNewChat}>
          New Chat
        </Button>
      </div>

      <div className="flex gap-2 items-end">
        <Textarea
          ref={textareaRef}
          value={input}
          onChange={handleChange}
          onKeyDown={handleKeyDown}
          placeholder="Ask about energy consumption, costs, or power demand..."
          className="resize-none min-h-[44px] max-h-[200px]"
          rows={1}
          disabled={disabled}
        />

        {isLoading ? (
          <Button
            variant="destructive"
            size="icon"
            onClick={onStop}
            className="shrink-0"
          >
            ■
          </Button>
        ) : (
          <Button
            onClick={handleSubmit}
            disabled={!input.trim() || disabled}
            size="icon"
            className="shrink-0"
          >
            ↑
          </Button>
        )}
      </div>

      <p className="text-xs text-muted-foreground text-center">
        Press Enter to send, Shift+Enter for new line
      </p>
    </div>
  );
}
