'use client';

import { useState } from 'react';

import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { Input } from '@/components/ui/input';
import { Skeleton } from '@/components/ui/skeleton';
import { useConversations } from '@/contexts/ConversationsContext';
import { deleteConversation, getConversation, updateConversationTitle } from '@/lib/api';
import type { Conversation, ConversationDetail } from '@/lib/types';

// Hoisted RegExp for performance (avoid recreation on each render)
const THINK_BLOCK_RE = /<think>[\s\S]*?<\/think>/gi;

export function ConversationList() {
  const { conversations, isLoading, refresh, activeConversationId, setActiveConversationId } = useConversations();
  const [deleteTarget, setDeleteTarget] = useState<Conversation | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [renameTarget, setRenameTarget] = useState<Conversation | null>(null);
  const [newTitle, setNewTitle] = useState('');
  const [isRenaming, setIsRenaming] = useState(false);

  const handleDelete = async () => {
    if (!deleteTarget) return;

    setIsDeleting(true);
    try {
      await deleteConversation(deleteTarget.id);
      await refresh();
      setDeleteTarget(null);
    } catch (error) {
      console.error('Failed to delete conversation:', error);
    } finally {
      setIsDeleting(false);
    }
  };

  const handleRename = async () => {
    if (!renameTarget || !newTitle.trim()) return;

    setIsRenaming(true);
    try {
      await updateConversationTitle(renameTarget.id, newTitle.trim());
      await refresh();
      setRenameTarget(null);
      setNewTitle('');
    } catch (error) {
      console.error('Failed to rename conversation:', error);
    } finally {
      setIsRenaming(false);
    }
  };

  const openRenameDialog = (conversation: Conversation, e: React.MouseEvent) => {
    e.stopPropagation();
    setRenameTarget(conversation);
    setNewTitle(conversation.title || '');
  };

  // Export helpers
  const stripThinkingBlocks = (content: string): string => {
    // Remove <think>...</think> blocks (including multiline)
    // Reset lastIndex since global regex has mutable state
    THINK_BLOCK_RE.lastIndex = 0;
    return content.replace(THINK_BLOCK_RE, '').trim();
  };

  const formatToolCallParams = (argsJson: string): string => {
    try {
      const args = JSON.parse(argsJson);
      return JSON.stringify(args, null, 2);
    } catch {
      return argsJson;
    }
  };

  const formatConversationToTxt = (conv: ConversationDetail, debugMode: boolean = false): string => {
    const lines: string[] = [];

    // Header
    lines.push(`# ${conv.title || 'Untitled Conversation'}`);
    lines.push(`Model: ${conv.model}`);
    lines.push(`Date: ${new Date(conv.created_at).toLocaleString()}`);
    if (debugMode) {
      lines.push('[DEBUG MODE - includes tool calls, parameters, and thinking]');
    }
    lines.push('');
    lines.push('---');
    lines.push('');

    // Messages
    for (const msg of conv.messages) {
      // Skip tool messages in normal mode
      if (msg.role === 'tool' && !debugMode) continue;

      const timestamp = new Date(msg.created_at).toLocaleString();

      if (msg.role === 'tool') {
        lines.push(`[TOOL: ${msg.tool_name}] ${timestamp}`);
      } else {
        lines.push(`[${msg.role.toUpperCase()}] ${timestamp}`);
      }

      // Strip thinking blocks in normal mode
      const content = debugMode ? msg.content : stripThinkingBlocks(msg.content);
      if (content) {
        lines.push(content);
      }

      // In debug mode, show tool calls with parameters for assistant messages
      if (debugMode && msg.role === 'assistant' && msg.tool_calls?.length) {
        lines.push('');
        lines.push('>>> Tool Calls:');
        for (const tc of msg.tool_calls) {
          lines.push(`  [${tc.function.name}]`);
          lines.push('  Parameters:');
          const formattedParams = formatToolCallParams(tc.function.arguments);
          // Indent each line of the JSON
          for (const line of formattedParams.split('\n')) {
            lines.push(`    ${line}`);
          }
        }
      }

      lines.push('');
    }

    return lines.join('\n');
  };

  const downloadTxt = (content: string, filename: string) => {
    const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename.replace(/[^a-z0-9]/gi, '_') + '.txt';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const handleExport = async (conversation: Conversation, debugMode: boolean = false) => {
    try {
      const detail = await getConversation(conversation.id);
      const txt = formatConversationToTxt(detail, debugMode);
      const suffix = debugMode ? '-debug' : '';
      downloadTxt(txt, `${conversation.title || 'conversation'}${suffix}`);
    } catch (error) {
      console.error('Failed to export conversation:', error);
    }
  };

  const formatDate = (dateString: string) => {
    const date = new Date(dateString);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));

    if (days === 0) {
      return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } else if (days === 1) {
      return 'Yesterday';
    } else if (days < 7) {
      return date.toLocaleDateString([], { weekday: 'short' });
    } else {
      return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
    }
  };

  if (isLoading) {
    return (
      <div className="p-2 space-y-1">
        {[...Array(5)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full rounded-lg" />
        ))}
      </div>
    );
  }

  if (conversations.length === 0) {
    return (
      <div className="p-4 text-center text-sm text-muted-foreground/70">
        No conversations yet
      </div>
    );
  }

  return (
    <>
      <div className="p-2 space-y-0.5 overflow-hidden">
        {conversations.map((conversation) => (
          <div
            key={conversation.id}
            className={`group relative px-3 py-2 rounded-lg cursor-pointer transition-colors overflow-hidden ${
              activeConversationId === conversation.id
                ? 'bg-sidebar-accent'
                : 'hover:bg-sidebar-accent/50'
            }`}
            onClick={() => setActiveConversationId(conversation.id)}
          >
            {/* Content - with right padding for menu */}
            <div className="pr-8 overflow-hidden">
              <div className="text-sm text-sidebar-foreground truncate">
                {conversation.title || 'Untitled'}
              </div>
              <div className="text-xs text-muted-foreground/70 mt-0.5">
                {formatDate(conversation.updated_at)}
              </div>
            </div>
            {/* Three-dot menu - appears on hover */}
            <div className="absolute right-2 top-1/2 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity">
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <button
                    className="p-1.5 text-muted-foreground hover:text-foreground rounded-md hover:bg-black/5"
                    onClick={(e) => e.stopPropagation()}
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className="h-4 w-4">
                      <circle cx="12" cy="5" r="2"/>
                      <circle cx="12" cy="12" r="2"/>
                      <circle cx="12" cy="19" r="2"/>
                    </svg>
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-40">
                  <DropdownMenuItem onClick={(e) => { e.stopPropagation(); openRenameDialog(conversation, e); }}>
                    Rename
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={(e) => { e.stopPropagation(); handleExport(conversation, false); }}>
                    Export as TXT
                  </DropdownMenuItem>
                  <DropdownMenuItem onClick={(e) => { e.stopPropagation(); handleExport(conversation, true); }}>
                    Export (Debug)
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    className="text-destructive focus:text-destructive"
                    onClick={(e) => { e.stopPropagation(); setDeleteTarget(conversation); }}
                  >
                    Delete
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </div>
        ))}
      </div>

      {/* Delete confirmation dialog */}
      <Dialog open={!!deleteTarget} onOpenChange={() => setDeleteTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Conversation</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete &ldquo;{deleteTarget?.title || 'Untitled'}&rdquo;?
              This action cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setDeleteTarget(null)}
              disabled={isDeleting}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={isDeleting}
            >
              {isDeleting ? 'Deleting...' : 'Delete'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Rename dialog */}
      <Dialog open={!!renameTarget} onOpenChange={() => setRenameTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Rename Conversation</DialogTitle>
            <DialogDescription>
              Enter a new title for this conversation.
            </DialogDescription>
          </DialogHeader>
          <Input
            value={newTitle}
            onChange={(e) => setNewTitle(e.target.value)}
            placeholder="Conversation title"
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !isRenaming) {
                handleRename();
              }
            }}
          />
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setRenameTarget(null)}
              disabled={isRenaming}
            >
              Cancel
            </Button>
            <Button
              onClick={handleRename}
              disabled={isRenaming || !newTitle.trim()}
            >
              {isRenaming ? 'Saving...' : 'Save'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
