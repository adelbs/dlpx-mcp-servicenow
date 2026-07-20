# dlpx-servicenow-mcp

Incident-driven VDB orchestrator: when a ServiceNow analyst moves an Incident to **Prioritized**, this service
reads the incident text, asks Claude to identify the affected application and the moment the problem occurred,
and uses Delphix to provision a VDB from the closest snapshot — ready for investigation. Once the VDB is ready,
the orchestrator itself moves the incident to **In Progress**. When the analyst resolves the incident
(**Resolved**), the VDB is destroyed automatically and the orchestrator closes the incident (**Closed**). The
analyst only ever has to move an incident to Prioritized or Resolved — the orchestrator owns both ends of its own
automation.

See [docs/delphix_servicenow_orchestrator_spec.md](docs/delphix_servicenow_orchestrator_spec.md) for the full
design and [docs/servicenow_runbook_rebuild_from_scratch.md](docs/servicenow_runbook_rebuild_from_scratch.md) for
how the ServiceNow side was configured.

## Architecture, in one sentence

```
ServiceNow (Business Rule, RESTMessageV2) --HTTPS--> Nginx (dlpx-mcp-remote-server's shared vhost)
    --/servicenow-webhook--> uvicorn (this app)
    --MCP/local--> mcp-proxy (dlpx-mcp-remote-server, already running on the same host)
    --stdio--> dxi-mcp-server --> Delphix DCT
```

This project is designed to run **on the same server as
[`dlpx-mcp-remote-server`](https://github.com/adelbs/dlpx-mcp-remote-server)**, reusing its already-running local
MCP endpoint (`127.0.0.1:8930`) instead of talking to the Delphix DCT REST API directly. It also has **no Nginx
vhost or TLS certificate of its own** — on a lab VM with no wildcard DNS there's no spare subdomain, so it adds a
`location /servicenow-webhook` route to `dlpx-mcp-remote-server`'s existing vhost/certificate instead. See
[docs/architecture.md](docs/architecture.md) and §3.7/§3.8 of the spec for the full reasoning and how the two
projects avoid colliding on ports, service users and directories.

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

The first time you choose **1) Install**, the menu asks for the essentials (SSH host/user, `dlpx-mcp-remote-server`'s
existing public hostname, ServiceNow credentials, Anthropic API key) and saves them to `deploy/deploy.conf`
(gitignored) so it won't ask again. From there the script connects to the CentOS server via SSH and does
everything else: installs prerequisites, uploads the application code, configures systemd, starts the service, and
patches `dlpx-mcp-remote-server`'s shared Nginx vhost with the `/servicenow-webhook` route.

At the end, it prints the URL to set as the `delphix.orchestrator_webhook_url` system property in ServiceNow.

You can also call an option directly without the interactive menu: `./orchestrator.sh 2` (view status).

## Running locally for development

```bash
uv sync --extra dev
cp .env.example .env   # fill in the values
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

- [`app/`](app/) — the FastAPI application: `main.py` (the `/servicenow-webhook` route), `incident_agent.py`
  (Claude call to extract the affected app + timestamp), `delphix_client.py` + `mcp_client.py` (MCP client talking
  to the local `dlpx-mcp-remote-server` endpoint), `servicenow_client.py` (Table API `PATCH` of `work_notes` and
  `state`).
- [`deploy/`](deploy/) — everything related to installing/operating the remote service: the scripts that run on
  this machine (`deploy/lib/`), the ones that run inside the server (`deploy/remote/`, including
  `patch_shared_nginx.sh`), and the systemd unit template (`deploy/templates/`).
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
