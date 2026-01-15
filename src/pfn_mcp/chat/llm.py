"""LLM client - direct Anthropic SDK integration for Claude models."""

import json
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any

import anthropic

from .config import chat_settings
from .prompts import build_system_prompt
from .tool_registry import get_tool_schemas_anthropic

logger = logging.getLogger(__name__)


@dataclass
class ChatMessage:
    """A message in the chat conversation."""

    role: str  # 'user', 'assistant', 'tool'
    content: str | None = None
    tool_calls: list[dict] | None = None  # For assistant messages with tool use
    tool_call_id: str | None = None  # For tool result messages
    name: str | None = None  # Tool name for tool results

    def to_anthropic(self) -> dict:
        """Convert to Anthropic message format."""
        if self.role == "tool":
            # Tool results are sent as user messages with tool_result content
            return {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": self.tool_call_id,
                        "content": self.content or "",
                    }
                ],
            }

        if self.role == "assistant" and self.tool_calls:
            # Assistant message with tool use
            content_blocks: list[dict] = []
            if self.content:
                content_blocks.append({"type": "text", "text": self.content})
            for tc in self.tool_calls:
                content_blocks.append({
                    "type": "tool_use",
                    "id": tc["id"],
                    "name": tc["function"]["name"],
                    "input": json.loads(tc["function"]["arguments"]) if isinstance(tc["function"]["arguments"], str) else tc["function"]["arguments"],
                })
            return {"role": "assistant", "content": content_blocks}

        # Regular user or assistant message
        return {"role": self.role, "content": self.content or ""}


@dataclass
class StreamChunk:
    """A chunk from streaming response."""

    content: str | None = None
    tool_calls: list[dict] | None = None
    finish_reason: str | None = None
    input_tokens: int = 0
    output_tokens: int = 0


@dataclass
class ChatResponse:
    """Complete response from LLM."""

    content: str | None = None
    tool_calls: list[dict] | None = None
    finish_reason: str | None = None
    input_tokens: int = 0
    output_tokens: int = 0
    model: str = ""


class LLMClient:
    """
    Claude LLM client using direct Anthropic SDK.

    Provides reliable tool calling without LiteLLM abstraction layer issues.
    Supports Anthropic prompt caching for token efficiency.
    """

    def __init__(
        self,
        model: str | None = None,
        tenant_name: str | None = None,
        enable_prompt_cache: bool | None = None,
    ):
        """
        Initialize LLM client.

        Args:
            model: Model identifier (e.g., 'claude-sonnet-4-20250514')
                   If None, uses default from settings.
            tenant_name: Tenant context for system prompt
            enable_prompt_cache: Whether to use Anthropic prompt caching.
                   If None, uses setting from config.
        """
        self.model = model or chat_settings.llm_model
        self.client = anthropic.AsyncAnthropic(api_key=chat_settings.anthropic_api_key)
        self.tools = get_tool_schemas_anthropic()
        self.tenant_name = tenant_name
        self.enable_prompt_cache = (
            enable_prompt_cache
            if enable_prompt_cache is not None
            else chat_settings.enable_prompt_cache
        )

    async def chat(
        self,
        messages: list[ChatMessage],
        stream: bool = False,
        use_tools: bool = True,
        temperature: float = 0.7,
    ) -> ChatResponse | AsyncIterator[StreamChunk]:
        """
        Send a chat request to Claude.

        Args:
            messages: Conversation history
            stream: Whether to stream the response
            use_tools: Whether to enable tool calling
            temperature: Sampling temperature

        Returns:
            ChatResponse for non-streaming, AsyncIterator[StreamChunk] for streaming
        """
        # Convert messages to Anthropic format
        anthropic_messages = self._convert_messages(messages)

        # Build request kwargs
        kwargs: dict[str, Any] = {
            "model": self.model,
            "messages": anthropic_messages,
            "max_tokens": chat_settings.llm_max_tokens,
            "temperature": temperature,
        }

        # Add system prompt with optional caching
        system_prompt = build_system_prompt(
            tenant_name=self.tenant_name,
            enable_cache=self.enable_prompt_cache,
        )
        if system_prompt:
            kwargs["system"] = system_prompt

        # Add tools if enabled
        if use_tools and self.tools:
            kwargs["tools"] = self.tools

        logger.debug(f"Claude request: model={self.model}, messages={len(messages)}, stream={stream}")

        if stream:
            return self._stream_response(**kwargs)
        else:
            return await self._complete(**kwargs)

    def _convert_messages(self, messages: list[ChatMessage]) -> list[dict]:
        """Convert messages to Anthropic format, merging consecutive same-role messages."""
        anthropic_messages: list[dict] = []

        for msg in messages:
            # Skip system messages - they're passed as top-level parameter
            if msg.role == "system":
                continue

            converted = msg.to_anthropic()

            # Anthropic requires alternating user/assistant messages
            # Merge consecutive same-role messages
            if anthropic_messages and anthropic_messages[-1]["role"] == converted["role"]:
                last = anthropic_messages[-1]
                # Merge content
                if isinstance(last["content"], str) and isinstance(converted["content"], str):
                    last["content"] = last["content"] + "\n" + converted["content"]
                elif isinstance(last["content"], list) and isinstance(converted["content"], list):
                    last["content"].extend(converted["content"])
                elif isinstance(last["content"], str) and isinstance(converted["content"], list):
                    last["content"] = [{"type": "text", "text": last["content"]}] + converted["content"]
                elif isinstance(last["content"], list) and isinstance(converted["content"], str):
                    last["content"].append({"type": "text", "text": converted["content"]})
            else:
                anthropic_messages.append(converted)

        return anthropic_messages

    async def _complete(self, **kwargs: Any) -> ChatResponse:
        """Non-streaming completion."""
        try:
            response = await self.client.messages.create(**kwargs)

            # Extract content and tool calls
            content_parts: list[str] = []
            tool_calls: list[dict] = []

            for block in response.content:
                if block.type == "text":
                    content_parts.append(block.text)
                elif block.type == "tool_use":
                    tool_calls.append({
                        "id": block.id,
                        "type": "function",
                        "function": {
                            "name": block.name,
                            "arguments": json.dumps(block.input),
                        },
                    })

            return ChatResponse(
                content="\n".join(content_parts) if content_parts else None,
                tool_calls=tool_calls if tool_calls else None,
                finish_reason=response.stop_reason,
                input_tokens=response.usage.input_tokens,
                output_tokens=response.usage.output_tokens,
                model=response.model,
            )

        except anthropic.APIError as e:
            logger.error(f"Claude API error: {e}")
            raise

    async def _stream_response(self, **kwargs: Any) -> AsyncIterator[StreamChunk]:
        """Streaming completion."""
        try:
            async with self.client.messages.stream(**kwargs) as stream:
                accumulated_text = ""
                tool_calls: list[dict] = []
                current_tool: dict | None = None
                input_tokens = 0
                output_tokens = 0

                async for event in stream:
                    if event.type == "message_start":
                        input_tokens = event.message.usage.input_tokens

                    elif event.type == "content_block_start":
                        if event.content_block.type == "tool_use":
                            current_tool = {
                                "id": event.content_block.id,
                                "type": "function",
                                "function": {
                                    "name": event.content_block.name,
                                    "arguments": "",
                                },
                            }

                    elif event.type == "content_block_delta":
                        if event.delta.type == "text_delta":
                            yield StreamChunk(content=event.delta.text)
                            accumulated_text += event.delta.text
                        elif event.delta.type == "input_json_delta" and current_tool:
                            current_tool["function"]["arguments"] += event.delta.partial_json

                    elif event.type == "content_block_stop":
                        if current_tool:
                            tool_calls.append(current_tool)
                            current_tool = None

                    elif event.type == "message_delta":
                        output_tokens = event.usage.output_tokens
                        # Final chunk with tool calls and finish reason
                        yield StreamChunk(
                            tool_calls=tool_calls if tool_calls else None,
                            finish_reason=event.delta.stop_reason,
                            input_tokens=input_tokens,
                            output_tokens=output_tokens,
                        )

        except anthropic.APIError as e:
            logger.error(f"Claude streaming error: {e}")
            raise


# Convenience function for simple usage
async def chat_completion(
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
    use_tools: bool = True,
    tenant_name: str | None = None,
) -> ChatResponse | AsyncIterator[StreamChunk]:
    """
    Simple chat completion function.

    Args:
        messages: List of message dicts with 'role' and 'content'
        model: Model to use (defaults to settings)
        stream: Whether to stream
        use_tools: Whether to enable tools
        tenant_name: Tenant context for system prompt

    Returns:
        ChatResponse or streaming iterator
    """
    client = LLMClient(model=model, tenant_name=tenant_name)
    chat_messages = [
        ChatMessage(
            role=m["role"],
            content=m.get("content"),
            tool_calls=m.get("tool_calls"),
            tool_call_id=m.get("tool_call_id"),
        )
        for m in messages
    ]
    return await client.chat(chat_messages, stream=stream, use_tools=use_tools)
