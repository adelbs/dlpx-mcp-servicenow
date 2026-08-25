# Technical Specification — Delphix ↔ ServiceNow Orchestrator

Handoff document for implementation via Claude Code, running on the VM where the Delphix Engine/DCT is already
active. Covers what's already configured in ServiceNow, what still needs to be built, and the architecture
decisions already made.

**Note (post-implementation update)**: this project originally ran alongside a separate, already-installed MCP
wrapper (`dlpx-mcp-remote-server`) and talked to its local `mcp-proxy`, and piggybacked on its Nginx vhost. It has
since been made fully self-contained — it spawns `dxi-mcp-server` directly as its own subprocess and owns its own
Nginx vhost/Let's Encrypt certificate — see [architecture.md](architecture.md) for the current design and why. §3.5
through §3.8 below describe the original (superseded) design and are kept for history; treat
[architecture.md](architecture.md) as the source of truth for the current architecture.

## 1. Objective

Integration demo for incident management: when an analyst moves an incident to **Prioritized** in ServiceNow, the
orchestrator reads the incident text, identifies the affected database and the moment the problem occurred, and uses
Delphix to spin up a VDB (virtual clone) from the closest snapshot to that moment — ready for investigation. Once the
VDB is ready, the orchestrator itself hands the incident back to the analyst by moving it to **In Progress**. When
the analyst resolves the incident (**Resolved**), the VDB is automatically destroyed and the orchestrator closes the
incident (**Closed**). The orchestrator owns both ends of its own automation — the analyst only ever has to move an
incident to Prioritized or Resolved.

## 2. What's already in place in ServiceNow

PDI instance: `https://dev424996.service-now.com` (admin user available; dedicated service user below).

| Item | Detail |
|---|---|
| Kanban board | Visual Task Board "Incidents by State", Incident table, vertical lane = `state` field |
| Service user | `delphix.orchestrator`, role `itil`, flagged as "Internal Integration User". Password already set by the user (not in this document). |
| System property | `delphix.orchestrator_webhook_url` — currently points to a placeholder (`https://REPLACE-ME.example.com/servicenow-webhook`). **Must be updated with the orchestrator's real public URL once it's live.** |
| Custom Incident state | `Prioritized` — added as a new choice on `Incident.state` (value `15`), sitting between `New` and `In Progress` in the lifecycle. Triggers the provision flow; the orchestrator itself promotes the incident to `In Progress` once the VDB is ready. |
| Business Rule 1 | "Delphix - Provisionar VDB (Incident Prioritized)" — Incident table, `when: async`, fires when `state changes to Prioritized`. Does a `RESTMessageV2` POST to the system property above. |
| Business Rule 2 | "Delphix - Destruir VDB (Incident encerrado)" — same table, `when: async`, fires when `state changes to Resolved OR Canceled`. Same kind of POST. **Deliberately excludes `Closed`**: the orchestrator itself moves the incident to `Closed` after teardown, and including `Closed` here would make that transition re-trigger this same rule. |
| Default Incident states | New, Prioritized (custom), In Progress, On Hold, Resolved, Closed, Canceled |

Both Business Rules have already been tested: moving a real incident between states, the system log (`syslog`)
confirmed the trigger (`Delphix provision webhook status: 0` and `Delphix teardown webhook status: 0` — status 0 is
just the expected connection failure against the placeholder). The end-to-end flow (Prioritized → VDB created →
In Progress → Resolved → VDB destroyed → Closed) has since been confirmed working against the live orchestrator.

### 2.1 Payload sent by ServiceNow

Both rules send the same body format, only the `action` field changes:

```json
{
  "action": "provision",
  "sys_id": "<incident sys_id>",
  "number": "INC0009009",
  "short_description": "...",
  "description": "...",
  "opened_at": "2026-07-06 10:42:59"
}
```

On teardown, `action` is `"teardown"`.

## 3. What needs to be built: the orchestrator

### 3.1 Suggested stack

Python + FastAPI. Runs as a single process, spawning `dxi-mcp-server` as its own subprocess (see
[architecture.md](architecture.md)). Rationale: I/O-bound (webhook → Claude → Delphix → ServiceNow), lightweight,
easy to test with `curl`/`httpx`, easy to run as a systemd service.

### 3.2 Single endpoint

`POST /servicenow-webhook` — receives the payload above and dispatches to the `provision` or `teardown` flow based on
the `action` field.

### 3.3 "provision" flow

1. Call the Claude API (Messages API, function calling) passing `short_description`, `description`, and `opened_at`.
   The model's role here is text interpretation only: extract (a) the service/application name mentioned in the
   incident (e.g. "CRM") and (b) the most likely timestamp of the problem (fall back to `opened_at` if the text
   doesn't mention a different time). Ask for structured JSON output, not free text.
2. Resolve the Delphix dataset: find the dSource whose tag matches the identified service (tag convention:
   `app:<name>`, e.g. `app:CRM` on dataset `Oracle_xpto`). This lookup is deterministic (by tag), it doesn't depend on
   the LLM guessing the dataset.
3. Provision the VDB: call the `provision_by_timestamp` action (DCT `data_tool`, via the local MCP connection — see
   §3.5) passing the resolved dataset and the timestamp — Delphix resolves the closest snapshot on its own, no manual
   selection needed. If that specific timestamp isn't provisionable (DCT's `"Cannot find refresh/provisionable
   point..."` error — happens when the incident has no clear time and falls back to `opened_at`, which can be
   beyond what's synced yet), retry once provisioning from the latest available point instead of failing the
   incident outright. Always sends an explicit, short `database_name` (derived from the incident number's digits,
   e.g. `"VDB_INC0010005"` → `"V0010005"`) rather than letting DCT default it to the full VDB name — Oracle
   enforces a hard 8-character limit there, confirmed live against a real Oracle dSource.
4. Poll the async provisioning job until `COMPLETED`.
5. Fetch the created VDB's connection details (`get_vdb`: host, port, service name).
6. **Tag the VDB with `incident:<number>`** (e.g. `incident:INC0009009`). This is the reliable link between incident
   and VDB — avoids having to ask the LLM again at teardown time.
7. Update the incident in ServiceNow via the Table API (`PATCH /api/now/table/incident/{sys_id}`, authenticating as
   `delphix.orchestrator`), in a single call setting both:
   - `work_notes`, multi-line, including the source dSource name, the snapshot timestamp Delphix actually used, the
     database type/name, and the VDB's JDBC connection string (`jdbc_connection_string`, returned directly by DCT on
     the VDB object — no host/port assembly needed).
   - `state` → `In Progress` (`2`). The incident enters this flow at `Prioritized`; the orchestrator promotes it to
     `In Progress` once the environment is actually ready, so that state now specifically means "ready, investigation
     under way."

### 3.4 "teardown" flow

1. Find the VDB tagged `incident:<number>` (direct lookup in Delphix, no LLM call). If none is found, still close the
   incident (see step 4) — there's nothing left to do either way.
2. Call `delete_vdb`.
3. Poll the job until `COMPLETED`.
4. PATCH ServiceNow, in a single call setting both `work_notes` (`"VDB destroyed after incident resolution."`, or the
   no-VDB-found message) and `state` → `Closed` (`7`).

### 3.4.1 On failure (either flow)

If any step raises (Claude call, Delphix lookup/provision/delete, job polling), the webhook handler catches it,
logs the full traceback, and — best-effort — PATCHes the incident with a `work_notes` comment: `"Delphix VDB
<provisioning|teardown> failed."` plus a truncated (500 char) rendering of the error, so the analyst isn't left
staring at an incident that silently never updated. `state` is deliberately **not** touched on failure — the
incident stays at `Prioritized`/`Resolved` rather than jumping to `In Progress`/`Closed`, since the automation
didn't actually finish. If the failure notice itself can't be written (e.g. ServiceNow is also down), that
secondary failure is logged but doesn't change the `502` already being returned for the original error.

### 3.5 Delphix access (decided)

The orchestrator talks to Delphix **as an MCP client of the local `mcp-proxy`** exposed by
`dlpx-mcp-remote-server`, connecting directly to `http://127.0.0.1:8930` (Streamable HTTP/SSE), **bypassing the
OAuth 2.1 gateway** (`dlpx-mcp-gateway`, port 8931) entirely. Rationale: both processes run on the same trusted host,
so there's no need to go through the public OAuth hop that exists specifically for remote/untrusted clients like
Claude Web. This also means the orchestrator has no dependency on the gateway's public domain/certificate being
healthy — only on the `dlpx-dct-mcp-proxy` systemd service being up.

**Revised after testing live against the VM**: the real, official `dxi-mcp-server` does not expose fixed
per-resource tools (an earlier draft of this doc assumed `cdb_dsource_tool`/`data_tool`/`job_tool`/
`snapshot_bookmark_tool`, based on a different MCP wrapper used during design — confirmed wrong by calling
`session.list_tools()` against the real local mcp-proxy). It exposes exactly two tools:

- `discovery` — browse a cached OpenAPI spec of the full DCT REST API (list tags, list operations, get an
  operation's resolved schema).
- `execute` — dispatch one DCT API call (`path` + `method` + `path_params`/`query_params`/`body`), with a
  confirmation-token gate on destructive operations.

`app/delphix_client.py` and `app/mcp_client.py` were rewritten around this real contract — see
[architecture.md](architecture.md)'s "dxi-mcp-server's real tool surface" section for the full
reasoning, including how the confirmation gate is handled and which DCT REST paths/fields were confirmed live
(`POST /vdbs/provision_by_timestamp`, `POST /vdbs/{vdbId}/delete`, `GET /jobs/{jobId}`, tags as
`{"key", "value"}` objects on dSources/VDBs).

If `dlpx-mcp-remote-server` is ever unavailable on the shared host, the fallback is calling the DCT REST API
directly (`DCT_BASE_URL`/`DCT_API_KEY`) — same credentials the MCP wrapper itself uses — but this is not the primary
path.

### 3.6 Configuration / environment variables

Current (see [architecture.md](architecture.md)):

```
ANTHROPIC_API_KEY=
DCT_BASE_URL=https://<dct-instance>          # dxi-mcp-server, spawned directly by this app, uses these to call DCT
DCT_API_KEY=
SERVICENOW_INSTANCE_URL=https://dev424996.service-now.com
SERVICENOW_USER=delphix.orchestrator
SERVICENOW_PASSWORD=
```

### 3.7 Network / public exposure (revised after testing against the real VM)

The PDI is SaaS and needs to reach the orchestrator over the internet. The original plan assumed a spare
subdomain would be available for the orchestrator's own Nginx vhost + Let's Encrypt certificate, mirroring
`dlpx-mcp-remote-server`. Testing against the actual lab VM (`uvo15o1hbasqfd8g57d.vm.cld.sr`) showed this
assumption was wrong: that hostname has **no wildcard DNS** (`servicenow-orch.<that-hostname>` doesn't resolve),
and `dlpx-mcp-remote-server`'s vhost already claims the entire hostname with its own certificate. There is no
spare public name to give this project its own vhost.

**Revised decision**: the orchestrator has no Nginx vhost or certificate of its own. Instead,
`deploy/remote/patch_shared_nginx.sh` idempotently adds a `location /servicenow-webhook` block directly into
`dlpx-mcp-remote-server`'s existing `/etc/nginx/conf.d/dlpx-mcp.conf`, proxying to this app's loopback port
(`127.0.0.1:8940`). This reuses that project's hostname and certificate; no Certbot, firewalld, or EPEL changes are
needed for this project at all. See [architecture.md](architecture.md) for the full trade-off (this
couples the two projects: a `dlpx-mcp-remote-server` reinstall wipes the block, requiring this project's
"Install" to be rerun).

Once installed, update the `delphix.orchestrator_webhook_url` system property in ServiceNow with
`https://<shared-hostname>/servicenow-webhook`.

### 3.8 Coexistence with `dlpx-mcp-remote-server` on the same host

Both projects are deployed independently (separate git repos, separate install scripts) onto the same CentOS
server. To avoid any collision in service users, directories, ports, or systemd unit names, the orchestrator uses
entirely distinct values — except the Nginx vhost, which is intentionally shared (see §3.7):

| Resource | `dlpx-mcp-remote-server` (existing) | `dlpx-servicenow-orchestrator` (new) |
|---|---|---|
| Service user | `dlpxmcp` | `svcnow-orch` |
| Home / install dir | `/opt/dlpx-mcp` | `/opt/dlpx-servicenow-orchestrator` |
| Config dir | `/etc/dlpx-mcp` | `/etc/dlpx-servicenow-orchestrator` |
| App port (loopback) | `127.0.0.1:8930` (mcp-proxy), `127.0.0.1:8931` (gateway) | `127.0.0.1:8940` (FastAPI/uvicorn) |
| systemd units | `dlpx-dct-mcp-proxy.service`, `dlpx-mcp-gateway.service` | `dlpx-servicenow-orchestrator.service` |
| Nginx vhost file | `/etc/nginx/conf.d/dlpx-mcp.conf` (owns it) | same file, patched in place (`location /servicenow-webhook` only) |
| Public hostname/certificate | its own | reused — no hostname/cert of its own |
| SSH ControlMaster socket (installer) | `/tmp/dlpx-mcp-ssh-%C` | `/tmp/dlpx-svcnow-orch-ssh-%C` |

Shared, unavoidably: `nginx` (already installed and running; this project never installs it), `uv` (if reused for
Python dependency management). Unlike the original plan, this project does **not** install or touch `certbot`,
`firewalld`, or `EPEL` — those stay fully owned by `dlpx-mcp-remote-server`. The orchestrator's `install_prereqs.sh`
checks for these before installing, same idempotent approach as the reference project.

### 3.9 Installer

Same pattern as `dlpx-mcp-remote-server`: a single entry-point shell script, run from a development machine (nothing
to install locally beyond bash + ssh/scp), that connects via SSH to the server (CentOS/RHEL or Ubuntu/Debian —
see `deploy/remote/install_prereqs.sh`) and does the install
end-to-end. **All menu text and prompts in English.**

```bash
./orchestrator.sh
```

Menu:

```
1) Install / reconfigure the server (from scratch)
2) View service status
3) Start services
4) Stop services
5) Update orchestrator (git pull + restart)
6) Uninstall (remove everything from the server)
0) Exit
```

First run of **1) Install** asks for the essentials (SSH host/user, public subdomain, ServiceNow credentials,
Anthropic API key) and saves them to `deploy/deploy.conf` (gitignored). Same SSH ControlMaster-based multiplexing as
the reference project (password/key prompted once, connection kept alive via `ControlPersist`), same
`deploy/lib/` (local orchestration: `common.sh`, `ssh.sh`, `action_*.sh`) / `deploy/remote/` (scripts that run on the
server) / `deploy/templates/` (systemd + Nginx templates) split.

### 3.10 Suggested repository structure

```
dlpx-servicenow-orchestrator/
├── README.md
├── orchestrator.sh              # single entry point (interactive menu)
├── app/
│   ├── main.py                  # FastAPI app, /servicenow-webhook route
│   ├── servicenow_client.py     # PATCH work_notes + state via Table API
│   ├── delphix_client.py        # find_dsource_by_tag, provision_vdb, poll_job,
│   │                            # get_vdb_connection_info, tag_vdb, find_vdb_by_tag, delete_vdb
│   ├── mcp_client.py            # spawns dxi-mcp-server directly (stdio), owns the long-lived MCP session
│   └── incident_agent.py        # Claude API call to extract app + timestamp
├── deploy/
│   ├── deploy.conf.example
│   ├── lib/                     # common.sh, ssh.sh, action_install.sh, action_status.sh,
│   │                            # action_start_stop.sh, action_update.sh, action_uninstall.sh
│   ├── remote/                  # install_prereqs.sh, configure_and_start.sh, setup_nginx.sh,
│   │                            # check_status.sh, uninstall.sh
│   └── templates/                # dlpx-servicenow-orchestrator.service.tmpl,
│                                  # nginx-dlpx-servicenow-orchestrator.conf.tmpl
├── docs/
│   ├── architecture.md
│   ├── delphix_servicenow_orchestrator_spec.md   # this document
│   └── servicenow_runbook_rebuild_from_scratch.md
└── tests/
    ├── sample_provision_payload.json
    └── sample_teardown_payload.json
```

### 3.11 How to test

1. Run FastAPI locally and test both flows with `curl` using the sample payloads, before exposing publicly.
2. Run the installer's **1) Install**, confirm this project's own Nginx vhost/certificate is up
   (`check_status.sh` reports it), and update the `delphix.orchestrator_webhook_url` system property in
   ServiceNow with `https://<DOMAIN>/servicenow-webhook`.
3. Real end-to-end test: move a test incident (with a `short_description` mentioning a known app, e.g. "CRM issue")
   from New → Prioritized, check the filled-in `work_notes`, the created VDB in Delphix, and that the incident moved
   itself to In Progress; then move it to Resolved and confirm the VDB is destroyed and the incident moves itself to
   Closed.

## 4. Open points to resolve during implementation

- ~~Confirm the exact tool/argument names exposed by `dxi-mcp-server`~~ — resolved: it's `discovery`/`execute`,
  not per-resource tools; confirmed live against the VM (see §3.5, architecture.md).
- ~~Define the final tag convention on dSources (`app:<name>`)~~ — resolved: `{"key": "app", "value": "<name>"}`,
  already applied to the demo datasets (`Suitecrm_master` → `app:CRM`, etc.) and confirmed working end-to-end
  through the app tag lookup.
- Define retry/timeout policy for Delphix jobs and for ServiceNow calls.
- ~~Decide whether `work_notes` should include the full connection string~~ — resolved: it includes the VDB's
  `jdbc_connection_string` (returned directly by DCT), the source dSource name, the snapshot timestamp, and the
  database type/name — confirmed live on a real MSSQL VDB.
- ~~Pick the actual subdomain to request/register for the orchestrator's public endpoint~~ — resolved: the
  orchestrator now owns its own Nginx vhost and Let's Encrypt certificate for `DOMAIN` (see
  [architecture.md](architecture.md)), superseding the path-based shared-vhost approach described in §3.7.
- **Known, accepted limitation**: one incident maps to exactly one VDB (`VDB_<number>`, tagged
  `incident:<number>`). If the incident text mentions more than one application (e.g. "ERP and CRM both down"),
  Claude may return a combined `app_name` that matches no dSource tag, and the flow fails with a clear
  `DelphixLookupError` (502, logged) rather than guessing or provisioning multiple VDBs. Confirmed with the
  project owner as acceptable for now — not a scenario this demo needs to support.
