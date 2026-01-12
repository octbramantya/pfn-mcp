'use client';

import { useEffect, useState } from 'react';

import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Skeleton } from '@/components/ui/skeleton';
import { deleteConversation, listConversations } from '@/lib/api';
import type { Conversation } from '@/lib/types';

export function ConversationList() {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [deleteTarget, setDeleteTarget] = useState<Conversation | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  // Load conversations
  useEffect(() => {
    const loadConversations = async () => {
      try {
        const data = await listConversations(50);
        setConversations(data);
      } catch (error) {
        console.error('Failed to load conversations:', error);
      } finally {
        setIsLoading(false);
      }
    };

    loadConversations();
  }, []);

  const handleDelete = async () => {
    if (!deleteTarget) return;

    setIsDeleting(true);
    try {
      await deleteConversation(deleteTarget.id);
      setConversations((prev) => prev.filter((c) => c.id !== deleteTarget.id));
      setDeleteTarget(null);
    } catch (error) {
      console.error('Failed to delete conversation:', error);
    } finally {
      setIsDeleting(false);
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
      <div className="p-2 space-y-2">
        {[...Array(5)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full" />
        ))}
      </div>
    );
  }

  if (conversations.length === 0) {
    return (
      <div className="p-4 text-center text-sm text-muted-foreground">
        No conversations yet
      </div>
    );
  }

  return (
    <>
      <div className="p-2 space-y-1">
        {conversations.map((conversation) => (
          <div
            key={conversation.id}
            className="group flex items-center gap-2 p-2 rounded-md hover:bg-sidebar-accent cursor-pointer"
          >
            <div className="flex-1 min-w-0">
              <div className="text-sm font-medium truncate text-sidebar-foreground">
                {conversation.title || 'Untitled'}
              </div>
              <div className="text-xs text-muted-foreground">
                {formatDate(conversation.updated_at)}
              </div>
            </div>
            <Button
              variant="ghost"
              size="sm"
              className="opacity-0 group-hover:opacity-100 h-6 w-6 p-0 text-muted-foreground hover:text-destructive"
              onClick={(e) => {
                e.stopPropagation();
                setDeleteTarget(conversation);
              }}
            >
              ×
            </Button>
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
    </>
  );
}
