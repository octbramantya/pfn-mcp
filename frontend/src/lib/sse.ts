/**
 * SSE (Server-Sent Events) utilities for chat streaming
 */

import { getToken, getUser } from './auth';
import type { ChatEvent, ChatRequest } from './types';

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8001';

/**
 * Parse SSE event data into typed ChatEvent
 */
export function parseSSEEvent(eventType: string, data: string): ChatEvent | null {
  try {
    const parsed = JSON.parse(data);

    switch (eventType) {
      case 'conversation':
        return {
          type: 'conversation',
          id: parsed.id,
          title: parsed.title,
          is_new: parsed.is_new,
        };
      case 'content':
        return { type: 'content', text: parsed.text };
      case 'tool_call':
        return {
          type: 'tool_call',
          name: parsed.name,
          call_id: parsed.call_id,
        };
      case 'tool_result':
        return {
          type: 'tool_result',
          name: parsed.name,
          result: parsed.result,
        };
      case 'title_update':
        return {
          type: 'title_update',
          id: parsed.id,
          title: parsed.title,
        };
      case 'done':
        return {
          type: 'done',
          input_tokens: parsed.input_tokens,
          output_tokens: parsed.output_tokens,
        };
      case 'error':
        return { type: 'error', message: parsed.message };
      default:
        console.warn('Unknown SSE event type:', eventType);
        return null;
    }
  } catch (e) {
    console.error('Failed to parse SSE event:', e, data);
    return null;
  }
}

/**
 * Stream chat response using fetch with ReadableStream
 * This is more flexible than EventSource for POST requests
 */
export async function* streamChat(
  request: ChatRequest,
  signal?: AbortSignal
): AsyncGenerator<ChatEvent> {
  const token = getToken();
  const user = getUser();

  const headers: HeadersInit = {
    'Content-Type': 'application/json',
  };

  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  if (user?.is_superuser && user?.effective_tenant) {
    headers['X-Tenant-Context'] = user.effective_tenant;
  }

  const response = await fetch(`${API_URL}/api/chat`, {
    method: 'POST',
    headers,
    body: JSON.stringify(request),
    signal,
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ message: 'Request failed' }));
    yield { type: 'error', message: error.message || error.detail || 'Chat request failed' };
    return;
  }

  const reader = response.body?.getReader();
  if (!reader) {
    yield { type: 'error', message: 'No response body' };
    return;
  }

  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();

      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // Process complete SSE events
      const lines = buffer.split('\n');
      buffer = lines.pop() || ''; // Keep incomplete line in buffer

      let currentEvent = '';
      let currentData = '';

      for (const line of lines) {
        if (line.startsWith('event: ')) {
          currentEvent = line.slice(7);
        } else if (line.startsWith('data: ')) {
          currentData = line.slice(6);
        } else if (line === '' && currentEvent && currentData) {
          // Empty line marks end of event
          const event = parseSSEEvent(currentEvent, currentData);
          if (event) {
            yield event;
          }
          currentEvent = '';
          currentData = '';
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}
