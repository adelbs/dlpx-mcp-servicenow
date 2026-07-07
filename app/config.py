from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    anthropic_api_key: str
    anthropic_model: str = "claude-haiku-4-5-20251001"

    # Local mcp-proxy exposed by dlpx-mcp-remote-server, already running on
    # this same host — see docs/architecture.md for why this bypasses the
    # public OAuth gateway of that project.
    mcp_local_url: str = "http://127.0.0.1:8930/sse"

    servicenow_instance_url: str
    servicenow_user: str
    servicenow_password: str

    request_timeout_seconds: float = 30
    job_poll_interval_seconds: float = 5
    job_poll_timeout_seconds: float = 900


settings = Settings()
