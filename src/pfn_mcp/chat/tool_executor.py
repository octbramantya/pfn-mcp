"""Tool executor - executes tools with tenant injection."""

import logging
from typing import Any

from .tool_registry import get_tenant_aware_tools, get_tool

logger = logging.getLogger(__name__)

# Cache tenant-aware tools
_tenant_aware_tools: set[str] | None = None


def _get_tenant_aware_tools() -> set[str]:
    """Get cached set of tenant-aware tool names."""
    global _tenant_aware_tools
    if _tenant_aware_tools is None:
        _tenant_aware_tools = get_tenant_aware_tools()
    return _tenant_aware_tools


async def execute_tool(
    tool_name: str,
    tool_input: dict[str, Any],
    tenant_code: str | None = None,
) -> str:
    """
    Execute a tool with tenant injection.

    Args:
        tool_name: Name of the tool to execute
        tool_input: Tool parameters from LLM
        tenant_code: Tenant code to inject (None for superuser/all tenants)

    Returns:
        Formatted string response from the tool
    """
    # Get tool function and formatter
    tool_entry = get_tool(tool_name)
    if not tool_entry:
        return f"Error: Unknown tool '{tool_name}'"

    tool_func, format_func = tool_entry

    # Inject tenant for tenant-aware tools
    tenant_aware = _get_tenant_aware_tools()
    if tool_name in tenant_aware and tenant_code:
        tool_input["tenant"] = tenant_code
        logger.debug(f"Injected tenant '{tenant_code}' into {tool_name}")

    try:
        # Execute the tool
        logger.info(f"Executing tool: {tool_name} with params: {tool_input}")
        result = await tool_func(**tool_input)

        # Format the response
        # Some formatters need extra args (like list_devices needs search)
        if tool_name == "list_devices":
            formatted = format_func(result, tool_input.get("search", ""))
        else:
            formatted = format_func(result)

        return formatted

    except TypeError as e:
        # Handle missing required parameters
        logger.error(f"Tool {tool_name} parameter error: {e}")
        return f"Error: Missing or invalid parameters for {tool_name}: {e}"

    except Exception as e:
        # Handle other errors
        logger.error(f"Tool {tool_name} execution error: {e}")
        return f"Error executing {tool_name}: {e}"


class ToolExecutionResult:
    """Result of a tool execution."""

    def __init__(
        self,
        tool_name: str,
        tool_call_id: str,
        result: str,
        success: bool = True,
    ):
        self.tool_name = tool_name
        self.tool_call_id = tool_call_id
        self.result = result
        self.success = success

    def to_message(self) -> dict:
        """Convert to LiteLLM tool result message format."""
        return {
            "role": "tool",
            "tool_call_id": self.tool_call_id,
            "content": self.result,
        }


async def execute_tool_calls(
    tool_calls: list[dict],
    tenant_code: str | None = None,
) -> list[ToolExecutionResult]:
    """
    Execute multiple tool calls from LLM response.

    Args:
        tool_calls: List of tool calls from LLM (OpenAI format)
        tenant_code: Tenant code to inject

    Returns:
        List of ToolExecutionResult objects
    """
    results = []

    for tool_call in tool_calls:
        tool_call_id = tool_call.get("id", "")
        function = tool_call.get("function", {})
        tool_name = function.get("name", "")

        # Parse arguments (may be JSON string or dict)
        arguments = function.get("arguments", {})
        if isinstance(arguments, str):
            import json

            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError:
                results.append(
                    ToolExecutionResult(
                        tool_name=tool_name,
                        tool_call_id=tool_call_id,
                        result=f"Error: Invalid JSON arguments for {tool_name}",
                        success=False,
                    )
                )
                continue

        # Execute the tool
        result = await execute_tool(tool_name, arguments, tenant_code)
        success = not result.startswith("Error")

        results.append(
            ToolExecutionResult(
                tool_name=tool_name,
                tool_call_id=tool_call_id,
                result=result,
                success=success,
            )
        )

    return results
