"""
MemoryMate MCP agent client.

Reasoning switches between OpenAI GPT-4.1 and a local Granite model. Both
backends use the OpenAI tool-calling API. Set AGENT_BACKEND in the environment.

The public entry point, execute_agent_with_tools(), is used by the FastAPI
endpoint and the voice agent.
"""

import asyncio
import json
import logging
import sys
from typing import Any, Dict, List, Optional

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from openai import AuthenticationError, OpenAI

import config


logging.basicConfig(
    level=config.LOG_LEVEL,
    format=config.LOG_FORMAT,
    handlers=[
        logging.FileHandler("mcp_agent_client.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("MCP_AgentClient")

MAX_ITERATIONS = 10

SYSTEM_PROMPT = """You are MemoryMate Assistant, a concise voice assistant.

Use the available tools whenever the user asks about the current date or time,
medications, or reminders. Never invent medication or reminder data. If more
than one tool is needed, call every needed tool before answering. Base the final
answer only on tool results and the user's request.

For the next medication, get the current date and time and all medications,
then compare every scheduled time. Treat an earlier time as occurring tomorrow.
Keep responses short, natural, and suitable for text-to-speech.
"""


def _build_openai_tools(mcp_tools: List[Any]) -> List[Dict[str, Any]]:
    """Convert MCP tool definitions to OpenAI function tool definitions."""
    result = []
    for tool in mcp_tools:
        schema = getattr(tool, "inputSchema", None) or {
            "type": "object",
            "properties": {},
        }
        result.append(
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description or "No description provided",
                    "parameters": schema,
                },
            }
        )
    return result


def _agent_runtime():
    """Return the chat client and model name for the selected backend."""
    if config.AGENT_BACKEND == "granite":
        logger.info(
            "Agent backend: local Granite (%s) at %s",
            config.GRANITE_MODEL,
            config.GRANITE_BASE_URL,
        )
        client = OpenAI(
            api_key=config.GRANITE_API_KEY or "ollama",
            base_url=config.GRANITE_BASE_URL,
        )
        return client, config.GRANITE_MODEL

    if config.AGENT_BACKEND != "openai":
        logger.warning(
            "Unknown AGENT_BACKEND '%s'; using OpenAI GPT-4.1",
            config.AGENT_BACKEND,
        )

    if not config.OPENAI_API_KEY:
        return None, config.OPENAI_MODEL

    client_kwargs = {"api_key": config.OPENAI_API_KEY}
    if config.OPENAI_BASE_URL:
        client_kwargs["base_url"] = config.OPENAI_BASE_URL
    logger.info("Agent backend: OpenAI (%s)", config.OPENAI_MODEL)
    return OpenAI(**client_kwargs), config.OPENAI_MODEL


def _tool_result_text(result: Any) -> str:
    """Extract all text blocks from an MCP tool result."""
    content = getattr(result, "content", None) or []
    parts = [
        block.text
        for block in content
        if getattr(block, "text", None) is not None
    ]
    return "\n".join(parts) if parts else str(result)


async def execute_agent_with_tools(query: str) -> Optional[str]:
    """Answer a user query with GPT-4.1 or local Granite and the MCP tools."""
    client, model_name = _agent_runtime()
    if client is None:
        logger.error("OPENAI_API_KEY is not configured")
        return (
            "OpenAI is not configured yet. Add the API key, or set "
            "AGENT_BACKEND=granite to use the local Granite model."
        )

    logger.info("Starting agent execution for query: %s", query)
    server_params = StdioServerParameters(
        command=sys.executable,
        args=config.MCP_SERVER_ARGS,
    )

    try:
        async with stdio_client(server_params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                mcp_tools = (await session.list_tools()).tools
                tools = _build_openai_tools(mcp_tools)
                tools_by_name = {tool.name: tool for tool in mcp_tools}

                messages: List[Any] = [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": query},
                ]

                for iteration in range(1, MAX_ITERATIONS + 1):
                    logger.info(
                        "Calling %s, iteration %d",
                        model_name,
                        iteration,
                    )

                    try:
                        response = await asyncio.to_thread(
                            client.chat.completions.create,
                            model=model_name,
                            messages=messages,
                            tools=tools,
                            tool_choice="auto",
                            temperature=0.2,
                            max_tokens=512,
                        )
                    except AuthenticationError:
                        logger.exception("Agent authentication failed")
                        if config.AGENT_BACKEND == "granite":
                            return (
                                "The local Granite server rejected the request. "
                                "Check GRANITE_BASE_URL, GRANITE_MODEL, and "
                                "GRANITE_API_KEY in .env."
                            )
                        return (
                            "OpenAI authentication failed. Please replace the "
                            "OPENAI_API_KEY value in .env."
                        )
                    message = response.choices[0].message
                    messages.append(message)

                    if not message.tool_calls:
                        answer = (message.content or "").strip()
                        if answer:
                            logger.info("Agent final response: %s", answer)
                            return answer
                        logger.error("Agent returned neither text nor tool calls")
                        return "Sorry, I could not produce a response."

                    for tool_call in message.tool_calls:
                        function_name = tool_call.function.name
                        logger.info("Executing tool: %s", function_name)

                        try:
                            arguments = json.loads(tool_call.function.arguments or "{}")
                        except json.JSONDecodeError as exc:
                            tool_text = f"Invalid tool arguments: {exc}"
                        else:
                            if function_name not in tools_by_name:
                                tool_text = f"Unknown tool: {function_name}"
                            else:
                                try:
                                    result = await session.call_tool(
                                        function_name,
                                        arguments,
                                    )
                                    tool_text = _tool_result_text(result)
                                except Exception as exc:
                                    logger.exception(
                                        "Tool %s failed",
                                        function_name,
                                    )
                                    tool_text = f"Tool execution failed: {exc}"

                        messages.append(
                            {
                                "role": "tool",
                                "tool_call_id": tool_call.id,
                                "content": tool_text,
                            }
                        )

                logger.error("Agent reached the maximum tool iterations")
                return "Sorry, I could not finish that request."

    except Exception as exc:
        logger.exception("Agent execution failed")
        return f"I encountered an error while processing your request: {exc}"


async def test_agent() -> None:
    """Run a small manual test set."""
    test_queries = [
        "What's my next medication?",
        "Show all my reminders",
    ]
    for query in test_queries:
        print(f"\nQuery: {query}")
        print(f"Answer: {await execute_agent_with_tools(query)}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] != "test":
        print("Usage: python3 mcp_agent_client.py [test]")
    else:
        asyncio.run(test_agent())
