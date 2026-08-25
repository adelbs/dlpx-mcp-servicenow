from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app import incident_agent
from app.config import settings


def _fake_ollama_response(arguments: dict | None):
    tool_calls = None
    if arguments is not None:
        tool_calls = [SimpleNamespace(function=SimpleNamespace(name="extract_incident_context", arguments=arguments))]
    return SimpleNamespace(message=SimpleNamespace(content="", tool_calls=tool_calls))


@pytest.mark.asyncio
async def test_extract_via_ollama_returns_tool_call_arguments():
    fake_chat = AsyncMock(
        return_value=_fake_ollama_response({"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"})
    )

    with patch.object(incident_agent, "_get_ollama_client", return_value=SimpleNamespace(chat=fake_chat)):
        result = await incident_agent._extract_via_ollama("some prompt")

    assert result == {"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"}
    fake_chat.assert_awaited_once()
    assert fake_chat.await_args.kwargs["model"] == settings.ollama_model
    assert fake_chat.await_args.kwargs["tools"] == [incident_agent._OLLAMA_TOOL]


@pytest.mark.asyncio
async def test_extract_via_ollama_raises_when_model_skips_the_tool_call():
    fake_chat = AsyncMock(return_value=_fake_ollama_response(None))

    with patch.object(incident_agent, "_get_ollama_client", return_value=SimpleNamespace(chat=fake_chat)):
        with pytest.raises(incident_agent.IncidentAgentError):
            await incident_agent._extract_via_ollama("some prompt")


@pytest.mark.asyncio
async def test_extract_incident_context_dispatches_to_ollama_by_default():
    assert settings.llm_provider == "ollama"
    fake_extract = AsyncMock(return_value={"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"})

    with patch.object(incident_agent, "_extract_via_ollama", new=fake_extract):
        result = await incident_agent.extract_incident_context("short desc", "desc", "2026-07-06 10:00:00")

    assert result == {"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"}
    fake_extract.assert_awaited_once()


@pytest.mark.asyncio
async def test_extract_incident_context_dispatches_to_anthropic_when_configured():
    fake_extract = AsyncMock(return_value={"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"})

    with (
        patch.object(settings, "llm_provider", "anthropic"),
        patch.object(incident_agent, "_extract_via_anthropic", new=fake_extract),
    ):
        result = await incident_agent.extract_incident_context("short desc", "desc", "2026-07-06 10:00:00")

    assert result == {"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"}
    fake_extract.assert_awaited_once()
