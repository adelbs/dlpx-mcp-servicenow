import json
import logging
import os
from asyncio import Lock
from contextlib import AsyncExitStack

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from .config import settings

logger = logging.getLogger("orchestrator.mcp_client")


class MCPToolError(RuntimeError):
    pass


class DCTAPIError(RuntimeError):
    pass


# dxi-mcp-server only speaks stdio (no built-in SSE/HTTP mode — confirmed
# against its source: it always calls `run_stdio_async()`), so it's spawned
# once as a subprocess and kept alive for the app's lifetime (started/stopped
# by app/main.py's lifespan), rather than per call. A fresh subprocess per
# call would reload/cache dxi-mcp-server's DCT OpenAPI spec every time, and
# app/delphix_client.py's poll_job() calls this every few seconds for up to
# job_poll_timeout_seconds (900s default) while waiting on a provision/delete
# job — that would mean dozens of process spawns per incident.
_exit_stack: AsyncExitStack | None = None
_session: ClientSession | None = None
_lock = Lock()


async def start() -> None:
    """Spawn dct-mcp-server and open the long-lived MCP session. Call once at
    app startup; safe to call again (no-op) if already started."""
    global _exit_stack, _session
    if _session is not None:
        return

    params = StdioServerParameters(
        command=settings.dct_mcp_command,
        env={**os.environ, "DCT_API_KEY": settings.dct_api_key, "DCT_BASE_URL": settings.dct_base_url},
    )
    stack = AsyncExitStack()
    try:
        read, write = await stack.enter_async_context(stdio_client(params))
        session = await stack.enter_async_context(ClientSession(read, write))
        await session.initialize()
    except Exception:
        await stack.aclose()
        raise

    _exit_stack = stack
    _session = session
    logger.info("dct-mcp-server started (command=%r) and MCP session initialized.", settings.dct_mcp_command)


async def stop() -> None:
    """Terminate the dct-mcp-server subprocess and close the MCP session."""
    global _exit_stack, _session
    if _exit_stack is not None:
        await _exit_stack.aclose()
    _exit_stack = None
    _session = None


def _extract_text(result) -> str:
    parts = [block.text for block in result.content if getattr(block, "type", None) == "text"]
    return "\n".join(parts)


async def call_tool(name: str, arguments: dict) -> dict:
    """Call an MCP tool (dxi-mcp-server exposes exactly two: `discovery` and
    `execute` — see app/delphix_client.py's module docstring) and return its
    JSON-decoded structured content."""
    if _session is None:
        raise MCPToolError(
            "MCP session with dct-mcp-server isn't started — app/main.py's lifespan should have "
            "called mcp_client.start() at boot."
        )
    arguments = {k: v for k, v in arguments.items() if v is not None}
    # Serializes tool calls over the single shared stdio session — this app's
    # actual traffic is low-volume/sequential per incident, so a lock is a
    # simple way to sidestep any doubt about concurrent-call safety on one
    # stdio pipe, rather than something observed to be needed.
    async with _lock:
        result = await _session.call_tool(name, arguments)

    text = _extract_text(result)
    if result.isError:
        raise MCPToolError(f"MCP tool '{name}' returned an error: {text}")

    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


async def dct_execute(
    path: str,
    method: str,
    path_params: dict | None = None,
    query_params: dict | None = None,
    body: dict | None = None,
) -> dict:
    """Call the DCT REST API via dxi-mcp-server's `execute` tool, transparently
    resolving the confirmation gate it puts in front of destructive operations
    (delete, rollback, ...).

    That gate exists so an interactive client can show a human a confirmation
    prompt before, say, deleting a VDB. This orchestrator has no interactive
    user at the point it calls this — the human approval already happened
    when the ServiceNow analyst moved the incident to In Progress/Resolved —
    so it re-submits with the returned confirmation_token automatically,
    logging a warning each time for auditability.
    """
    envelope = await call_tool(
        "execute",
        {
            "path": path,
            "method": method,
            "path_params": path_params,
            "query_params": query_params,
            "body": body,
        },
    )

    if envelope.get("status") == "confirmation_required":
        logger.warning(
            "DCT operation %s %s required confirmation (level=%s) — auto-confirming "
            "(approval already happened via the ServiceNow incident transition).",
            method,
            path,
            envelope.get("confirmation_level"),
        )
        envelope = await call_tool(
            "execute",
            {
                "path": path,
                "method": method,
                "path_params": path_params,
                "query_params": query_params,
                "body": body,
                "confirmation_token": envelope.get("confirmation_token"),
            },
        )

    if envelope.get("status") == "error":
        raise DCTAPIError(f"DCT API {method} {path} failed: {envelope}")

    return envelope.get("response", {})
