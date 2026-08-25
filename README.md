# dlpx-mcp-servicenow

Incident-driven VDB orchestrator: when a ServiceNow analyst moves an Incident to **Prioritized**, this service
reads the incident text, asks an LLM (a local [Ollama](https://ollama.com) model by default, or Claude — see
`LLM_PROVIDER` below and [docs/architecture.md](docs/architecture.md)) to identify the affected application and
the moment the problem occurred, and uses Delphix to provision a VDB from the closest snapshot — ready for
investigation. Once the VDB is ready,
the orchestrator itself moves the incident to **In Progress**. When the analyst resolves the incident
(**Resolved**), the VDB is destroyed automatically and the orchestrator closes the incident (**Closed**). The
analyst only ever has to move an incident to Prioritized or Resolved — the orchestrator owns both ends of its own
automation.

See [docs/delphix_servicenow_orchestrator_spec.md](docs/delphix_servicenow_orchestrator_spec.md) for the full
design and [docs/servicenow_runbook_rebuild_from_scratch.md](docs/servicenow_runbook_rebuild_from_scratch.md) for
how the ServiceNow side was configured.

## Architecture, in one sentence

```
ServiceNow (Business Rule, RESTMessageV2) --HTTPS--> Nginx (this project's own vhost/certificate)
    --/servicenow-webhook--> uvicorn (this app)
    --stdio (subprocess)--> dxi-mcp-server --> Delphix DCT
```

This project is fully self-contained: it installs and owns its own Nginx, Let's Encrypt certificate, firewall
rules and systemd service, and spawns [`dxi-mcp-server`](https://github.com/delphix/dxi-mcp-server) (the official
Delphix DCT MCP server) directly as a subprocess of the app itself — no other project or already-running service
needs to be present on the host. See [docs/architecture.md](docs/architecture.md) for the full reasoning.

## Quick start (deploying to the server)

Everything is done through a single script, run from this development machine (nothing to install — just bash +
ssh/scp):

```bash
./orchestrator.sh
```

This opens a menu:

```
1) Install / reconfigure the server (from scratch)
2) View service status
3) Start service
4) Stop service
5) Update orchestrator (re-upload + restart)
6) Uninstall (remove everything from the server)
0) Exit
```

The first time you choose **1) Install**, the menu asks for the essentials (SSH host/user, the public hostname to
issue a certificate for, a Let's Encrypt email, which LLM provider to use, ServiceNow credentials, DCT
credentials) and
saves them to `deploy/deploy.conf` (gitignored) so it won't ask again. From there the script connects to the
server (CentOS/RHEL or Ubuntu/Debian) via SSH and does everything else: installs Nginx/Certbot/firewalld and `uv`, uploads the application
code (which pulls in `dxi-mcp-server` as a dependency), configures systemd, starts the service, and sets up this
project's own Nginx vhost and TLS certificate for `DOMAIN`.

At the end, it prints the URL to set as the `delphix.orchestrator_webhook_url` system property in ServiceNow.

You can also call an option directly without the interactive menu: `./orchestrator.sh 2` (view status).

## Running locally for development

`uv sync` also installs `dxi-mcp-server` (a project dependency — see `pyproject.toml`), which the app spawns
directly as a subprocess on startup, so you need a real (or reachable) DCT instance and API key even for local
development:

```bash
uv sync --extra dev
cp .env.example .env   # fill in the values, including DCT_BASE_URL/DCT_API_KEY
uv run uvicorn app.main:app --reload --port 8940
```

Test the two flows with the sample payloads before exposing anything publicly:

```bash
curl -X POST http://127.0.0.1:8940/servicenow-webhook \
    -H "Content-Type: application/json" \
    -d @tests/sample_provision_payload.json

curl -X POST http://127.0.0.1:8940/servicenow-webhook \
    -H "Content-Type: application/json" \
    -d @tests/sample_teardown_payload.json
```

## Repository structure

- [`app/`](app/) — the FastAPI application: `main.py` (the `/servicenow-webhook` route; its `lifespan` starts/stops
  the `dxi-mcp-server` subprocess), `incident_agent.py` (LLM call — Anthropic or local Ollama, see `LLM_PROVIDER` —
  to extract the affected app + timestamp),
  `delphix_client.py` + `mcp_client.py` (MCP client spawning and talking to `dxi-mcp-server` directly over stdio),
  `servicenow_client.py` (Table API `PATCH` of `work_notes` and `state`).
- [`deploy/`](deploy/) — everything related to installing/operating the remote service: the scripts that run on
  this machine (`deploy/lib/`), the ones that run inside the server (`deploy/remote/`, including
  `setup_nginx.sh`), and the systemd + Nginx templates (`deploy/templates/`).
- [`orchestrator.sh`](orchestrator.sh) — single entry point (interactive menu).
- [`docs/`](docs/) — [`architecture.md`](docs/architecture.md) (design decisions),
  [`delphix_servicenow_orchestrator_spec.md`](docs/delphix_servicenow_orchestrator_spec.md) (full handoff spec),
  [`servicenow_runbook_rebuild_from_scratch.md`](docs/servicenow_runbook_rebuild_from_scratch.md) (rebuild the
  ServiceNow side from scratch).
- [`tests/`](tests/) — sample webhook payloads and unit tests.

## Tests

```bash
uv sync --extra dev
uv run pytest
```
