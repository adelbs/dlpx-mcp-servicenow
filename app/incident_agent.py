import logging

import ollama
from anthropic import AsyncAnthropic

from .config import settings

logger = logging.getLogger("orchestrator.incident_agent")

_TOOL_NAME = "extract_incident_context"

_EXTRACT_TOOL = {
    "name": _TOOL_NAME,
    "description": (
        "Extract the affected application/service and the most likely timestamp of the "
        "problem from a ServiceNow incident's text."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "app_name": {
                "type": "string",
                "description": (
                    "Short name of the affected application/service, matching how it's "
                    "referred to in the incident text (e.g. CRM, Billing, ERP)."
                ),
            },
            "problem_timestamp": {
                "type": "string",
                "description": (
                    "Best-guess timestamp of when the problem started, formatted as "
                    "'YYYY-MM-DD HH:MM:SS'. Use the incident's opened_at value if the text "
                    "doesn't mention a different time."
                ),
            },
        },
        "required": ["app_name", "problem_timestamp"],
    },
}


class IncidentAgentError(RuntimeError):
    pass


# Ollama's tool-calling format wraps the same JSON Schema shape Anthropic
# uses for input_schema inside {"type": "function", "function": {...,
# "parameters": ...}} — reusing _EXTRACT_TOOL["input_schema"] directly as
# "parameters" avoids keeping two copies of the schema in sync.
_OLLAMA_TOOL = {
    "type": "function",
    "function": {
        "name": _TOOL_NAME,
        "description": _EXTRACT_TOOL["description"],
        "parameters": _EXTRACT_TOOL["input_schema"],
    },
}

# Both clients are constructed lazily (not at import time): an Ollama-only
# deployment shouldn't need ANTHROPIC_API_KEY set at all, and AsyncAnthropic
# validates its api_key at construction.
_anthropic_client: AsyncAnthropic | None = None
_ollama_client: ollama.AsyncClient | None = None


def _get_anthropic_client() -> AsyncAnthropic:
    global _anthropic_client
    if _anthropic_client is None:
        if not settings.anthropic_api_key:
            raise IncidentAgentError(
                "ANTHROPIC_API_KEY is not set (required when LLM_PROVIDER=anthropic)"
            )
        _anthropic_client = AsyncAnthropic(api_key=settings.anthropic_api_key)
    return _anthropic_client


def _get_ollama_client() -> ollama.AsyncClient:
    global _ollama_client
    if _ollama_client is None:
        _ollama_client = ollama.AsyncClient(host=settings.ollama_base_url)
    return _ollama_client


async def _extract_via_anthropic(prompt: str) -> dict:
    message = await _get_anthropic_client().messages.create(
        model=settings.anthropic_model,
        max_tokens=300,
        tools=[_EXTRACT_TOOL],
        tool_choice={"type": "tool", "name": _TOOL_NAME},
        messages=[{"role": "user", "content": prompt}],
    )

    for block in message.content:
        if block.type == "tool_use":
            logger.info("Claude extracted: %s", block.input)
            return block.input

    raise IncidentAgentError("Claude did not return the expected tool_use block")


async def _extract_via_ollama(prompt: str) -> dict:
    response = await _get_ollama_client().chat(
        model=settings.ollama_model,
        messages=[{"role": "user", "content": prompt}],
        tools=[_OLLAMA_TOOL],
    )

    tool_calls = response.message.tool_calls
    if not tool_calls:
        raise IncidentAgentError(
            f"Ollama model '{settings.ollama_model}' did not return the expected tool call "
            f"(response content: {response.message.content!r})"
        )

    arguments = dict(tool_calls[0].function.arguments)
    logger.info("Ollama extracted: %s", arguments)
    return arguments


async def extract_incident_context(short_description: str, description: str, opened_at: str) -> dict:
    prompt = (
        f"Incident short description: {short_description}\n"
        f"Incident description: {description}\n"
        f"Incident opened_at: {opened_at}\n\n"
        "Extract the affected application and the most likely timestamp of the problem."
    )
    model = settings.ollama_model if settings.llm_provider == "ollama" else settings.anthropic_model
    logger.info("Prompt sent to %s (provider=%s):\n%s", model, settings.llm_provider, prompt)

    if settings.llm_provider == "ollama":
        return await _extract_via_ollama(prompt)
    return await _extract_via_anthropic(prompt)
