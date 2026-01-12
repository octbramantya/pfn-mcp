"""LLM client - unified interface via LiteLLM for multi-model support."""

import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any

import litellm
from litellm import acompletion

from .config import chat_settings
from .tool_registry import get_tool_schemas

logger = logging.getLogger(__name__)

# Configure LiteLLM
litellm.set_verbose = False


@dataclass
class ChatMessage:
    """A message in the chat conversation."""

    role: str  # 'user', 'assistant', 'system', 'tool'
    content: str | None = None
    tool_calls: list[dict] | None = None
    tool_call_id: str | None = None
    name: str | None = None  # Tool name for tool messages

    def to_dict(self) -> dict:
        """Convert to LiteLLM message format."""
        msg: dict[str, Any] = {"role": self.role}

        if self.content is not None:
            msg["content"] = self.content

        if self.tool_calls:
            msg["tool_calls"] = self.tool_calls

        if self.tool_call_id:
            msg["tool_call_id"] = self.tool_call_id

        if self.name:
            msg["name"] = self.name

        return msg


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
    Multi-model LLM client using LiteLLM.

    Supports Claude, MiniMax, OpenAI, and any LiteLLM-compatible model.
    """

    def __init__(self, model: str | None = None):
        """
        Initialize LLM client.

        Args:
            model: Model identifier (e.g., 'claude-sonnet-4-20250514', 'minimax/MiniMax-M2')
                   If None, uses default from settings.
        """
        self.model = model or chat_settings.llm_model
        self.tools = get_tool_schemas()

    async def chat(
        self,
        messages: list[ChatMessage],
        stream: bool = False,
        use_tools: bool = True,
        temperature: float = 0.7,
    ) -> ChatResponse | AsyncIterator[StreamChunk]:
        """
        Send a chat request to the LLM.

        Args:
            messages: Conversation history
            stream: Whether to stream the response
            use_tools: Whether to enable tool calling
            temperature: Sampling temperature

        Returns:
            ChatResponse for non-streaming, AsyncIterator[StreamChunk] for streaming
        """
        # Convert messages to LiteLLM format
        msg_dicts = [m.to_dict() for m in messages]

        # Build request kwargs
        kwargs: dict[str, Any] = {
            "model": self.model,
            "messages": msg_dicts,
            "temperature": temperature,
            "stream": stream,
        }

        # Add tools if enabled and model supports them
        if use_tools and self.tools and self._model_supports_tools():
            kwargs["tools"] = self.tools
            kwargs["tool_choice"] = "auto"

        logger.debug(f"LLM request: model={self.model}, messages={len(messages)}, stream={stream}")

        if stream:
            return self._stream_response(**kwargs)
        else:
            return await self._complete(**kwargs)

    def _model_supports_tools(self) -> bool:
        """Check if current model supports tool calling."""
        # Most modern models support tools
        # MiniMax M2 supports function calling
        model_lower = self.model.lower()

        # Known models with tool support
        tool_models = [
            "claude",
            "gpt-4",
            "gpt-3.5",
            "minimax",
            "gemini",
            "mistral",
        ]

        return any(m in model_lower for m in tool_models)

    async def _complete(self, **kwargs: Any) -> ChatResponse:
        """Non-streaming completion."""
        try:
            response = await acompletion(**kwargs)

            choice = response.choices[0]
            message = choice.message

            # Extract tool calls if present
            tool_calls = None
            if hasattr(message, "tool_calls") and message.tool_calls:
                tool_calls = [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in message.tool_calls
                ]

            # Get usage info
            usage = response.usage or {}
            input_tokens = getattr(usage, "prompt_tokens", 0)
            output_tokens = getattr(usage, "completion_tokens", 0)

            return ChatResponse(
                content=message.content,
                tool_calls=tool_calls,
                finish_reason=choice.finish_reason,
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                model=response.model,
            )

        except Exception as e:
            logger.error(f"LLM completion error: {e}")
            raise

    async def _stream_response(self, **kwargs: Any) -> AsyncIterator[StreamChunk]:
        """Streaming completion."""
        try:
            response = await acompletion(**kwargs)

            accumulated_tool_calls: dict[int, dict] = {}
            input_tokens = 0
            output_tokens = 0

            async for chunk in response:
                delta = chunk.choices[0].delta if chunk.choices else None
                finish_reason = chunk.choices[0].finish_reason if chunk.choices else None

                # Track usage if provided
                if hasattr(chunk, "usage") and chunk.usage:
                    input_tokens = getattr(chunk.usage, "prompt_tokens", input_tokens)
                    output_tokens = getattr(chunk.usage, "completion_tokens", output_tokens)

                # Content chunk
                content = None
                if delta and hasattr(delta, "content") and delta.content:
                    content = delta.content

                # Tool call chunks (accumulated across multiple chunks)
                if delta and hasattr(delta, "tool_calls") and delta.tool_calls:
                    for tc in delta.tool_calls:
                        idx = tc.index
                        if idx not in accumulated_tool_calls:
                            accumulated_tool_calls[idx] = {
                                "id": tc.id or "",
                                "type": "function",
                                "function": {"name": "", "arguments": ""},
                            }
                        if tc.id:
                            accumulated_tool_calls[idx]["id"] = tc.id
                        if tc.function:
                            if tc.function.name:
                                accumulated_tool_calls[idx]["function"]["name"] = tc.function.name
                            if tc.function.arguments:
                                accumulated_tool_calls[idx]["function"][
                                    "arguments"
                                ] += tc.function.arguments

                # Yield chunk
                tool_calls = None
                if finish_reason == "tool_calls" and accumulated_tool_calls:
                    tool_calls = list(accumulated_tool_calls.values())

                yield StreamChunk(
                    content=content,
                    tool_calls=tool_calls,
                    finish_reason=finish_reason,
                    input_tokens=input_tokens,
                    output_tokens=output_tokens,
                )

        except Exception as e:
            logger.error(f"LLM streaming error: {e}")
            raise


# Convenience function for simple usage
async def chat_completion(
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
    use_tools: bool = True,
) -> ChatResponse | AsyncIterator[StreamChunk]:
    """
    Simple chat completion function.

    Args:
        messages: List of message dicts with 'role' and 'content'
        model: Model to use (defaults to settings)
        stream: Whether to stream
        use_tools: Whether to enable tools

    Returns:
        ChatResponse or streaming iterator
    """
    client = LLMClient(model=model)
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
