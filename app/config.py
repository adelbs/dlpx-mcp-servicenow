import shutil
import sys
from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


def _default_dct_mcp_command() -> str:
    """Locate the `dct-mcp-server` console script (installed by `uv sync` as
    a project dependency — see pyproject.toml and docs/architecture.md)
    without relying on $PATH: the systemd unit invokes uvicorn by absolute
    path and never "activates" the virtualenv, so its own $PATH may not
    include .venv/bin. sys.executable is that same virtualenv's Python in
    both cases (systemd's ExecStart and `uv run` in local dev), and its
    sibling directory holds every console script uv installed alongside it.
    """
    candidate = Path(sys.executable).parent / "dct-mcp-server"
    if candidate.exists():
        return str(candidate)
    return shutil.which("dct-mcp-server") or "dct-mcp-server"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Which backend app/incident_agent.py uses to extract app_name +
    # problem_timestamp from incident text. Defaults to "ollama" — runs
    # fully locally (see docs/architecture.md for model/hardware sizing), no
    # per-call API cost — at the trade-off of a much smaller model's
    # extraction reliability vs "anthropic".
    llm_provider: Literal["anthropic", "ollama"] = "ollama"

    # Required only when llm_provider="anthropic" (validated lazily in
    # app/incident_agent.py, not here, so an Ollama-only deployment doesn't
    # need this set at all).
    anthropic_api_key: str | None = None
    anthropic_model: str = "claude-haiku-4-5-20251001"

    # Local Ollama server (no API key — loopback only). ollama_model must
    # support tool calling (llama3.2/qwen2.5 do); see docs/architecture.md
    # for why 3B is the recommended default on modest hardware.
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "llama3.2:3b"

    # dxi-mcp-server (https://github.com/delphix/dxi-mcp-server, package
    # `dct-mcp-server`) is spawned directly as a stdio subprocess by
    # app/mcp_client.py — no local proxy or separate service required. See
    # docs/architecture.md for why (this used to go through
    # dlpx-mcp-remote-server's mcp-proxy).
    dct_mcp_command: str = Field(default_factory=_default_dct_mcp_command)
    dct_base_url: str
    dct_api_key: str

    servicenow_instance_url: str
    servicenow_user: str
    servicenow_password: str

    request_timeout_seconds: float = 30
    job_poll_interval_seconds: float = 5
    job_poll_timeout_seconds: float = 900


settings = Settings()
