'use client';

import { useRef, useState } from 'react';

import { Button } from '@/components/ui/button';

interface ChatInputProps {
  onSend: (message: string) => void;
  onStop: () => void;
  isLoading: boolean;
  disabled: boolean;
}

export function ChatInput({
  onSend,
  onStop,
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
    <div className="max-w-3xl mx-auto">
      {/* Input container with inline send button */}
      <div className="relative flex items-end bg-secondary/50 rounded-2xl border border-border/50 focus-within:border-primary/30 focus-within:ring-2 focus-within:ring-primary/10 transition-all">
        <textarea
          ref={textareaRef}
          value={input}
          onChange={handleChange}
          onKeyDown={handleKeyDown}
          placeholder="Message..."
          className="flex-1 bg-transparent resize-none min-h-[52px] max-h-[200px] px-4 py-3.5 pr-14 text-foreground placeholder:text-muted-foreground/60 focus:outline-none"
          rows={1}
          disabled={disabled}
        />

        {/* Send/Stop button - positioned inside */}
        <div className="absolute right-2 bottom-2">
          {isLoading ? (
            <Button
              variant="ghost"
              size="icon"
              onClick={onStop}
              className="h-9 w-9 rounded-xl bg-destructive/10 text-destructive hover:bg-destructive/20"
            >
              <span className="text-sm">■</span>
            </Button>
          ) : (
            <Button
              onClick={handleSubmit}
              disabled={!input.trim() || disabled}
              size="icon"
              className="h-9 w-9 rounded-xl"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="h-4 w-4"
              >
                <path d="m5 12 7-7 7 7" />
                <path d="M12 19V5" />
              </svg>
            </Button>
          )}
        </div>
      </div>

      {/* Subtle hint */}
      <p className="text-xs text-muted-foreground/50 text-center mt-2">
        Enter to send · Shift+Enter for new line
      </p>
    </div>
  );
}
