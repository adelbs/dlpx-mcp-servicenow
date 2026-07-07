import logging

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


_client = AsyncAnthropic(api_key=settings.anthropic_api_key)


async def extract_incident_context(short_description: str, description: str, opened_at: str) -> dict:
    prompt = (
        f"Incident short description: {short_description}\n"
        f"Incident description: {description}\n"
        f"Incident opened_at: {opened_at}\n\n"
        "Extract the affected application and the most likely timestamp of the problem."
    )
    logger.info("Prompt sent to Claude (model=%s):\n%s", settings.anthropic_model, prompt)

    message = await _client.messages.create(
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
