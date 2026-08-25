# Architecture

## Problem

ServiceNow needs a public HTTPS endpoint to notify this orchestrator of Incident state changes (via
`RESTMessageV2` Business Rules — see [servicenow_runbook_rebuild_from_scratch.md](servicenow_runbook_rebuild_from_scratch.md)).
Once notified, the orchestrator needs to read the incident text, decide which Delphix dataset/timestamp it refers
to, provision or destroy a VDB accordingly, and let ServiceNow know via the Table API. It talks to Delphix through
Delphix's own [`dxi-mcp-server`](https://github.com/delphix/dxi-mcp-server), and needs a public HTTPS endpoint of
its own for ServiceNow to reach.

## Decision: spawn dxi-mcp-server directly, as our own subprocess

An earlier version of this project ran alongside a separate, already-installed MCP wrapper
(`dlpx-mcp-remote-server`) on the same host and talked to its local `mcp-proxy` over SSE. That made this project
depend on another project's install succeeding first — in practice a real source of install-order failures (a
broken prerequisite on the *other* project silently left its service user uncreated, which cascaded into this
project's own install failing too, with no dependency the tooling could check for automatically).

This project now installs `dxi-mcp-server` as a normal project dependency (`pyproject.toml`, a `uv`/pip git
dependency — see "Decision: pin dxi-mcp-server via uv, not a server-side git clone" below) and
`app/mcp_client.py` spawns it directly as a stdio subprocess — the same way `dlpx-mcp-remote-server`'s own
`mcp-proxy` did internally, just without the extra project and extra hop. `dxi-mcp-server` only speaks stdio (no
built-in HTTP/SSE mode), which is exactly what `mcp.client.stdio.stdio_client` is for.

**One long-lived subprocess, not one per call.** `app/delphix_client.py`'s `poll_job()` calls the MCP session
every few seconds for up to `job_poll_timeout_seconds` (900s default) while waiting on a provision/delete job —
spawning a fresh `dxi-mcp-server` per call (each one reloads/caches the DCT OpenAPI spec on its own startup) would
mean dozens of process spawns per incident. Instead, `app/main.py`'s `lifespan` calls `mcp_client.start()` once at
boot (spawn + MCP handshake) and `mcp_client.stop()` at shutdown; `call_tool()` reuses that one session for every
tool call, guarded by an `asyncio.Lock` to serialize access to the single stdio pipe (this app's actual traffic is
low-volume and sequential per incident, so a lock is a simple way to sidestep any doubt about concurrent-call
safety, not something observed to be needed). A side benefit: since `DCT_API_KEY`/`DCT_BASE_URL` are validated at
`dxi-mcp-server`'s own startup, a bad credential now fails the whole app at boot instead of surfacing only on the
first incident webhook.

## Decision: pin dxi-mcp-server via uv, not a server-side git clone

`dxi-mcp-server`'s own `pyproject.toml` declares the console script `dct-mcp-server` (package name
`dct-mcp-server`). `pyproject.toml` here depends on it as a direct git reference
(`dct-mcp-server @ git+https://github.com/delphix/dxi-mcp-server.git`), which needs
`tool.hatch.metadata.allow-direct-references = true` since it isn't published to PyPI. `uv sync` (already run on
every install/update — see below) resolves and installs it into `.venv` like any other dependency, and
`uv.lock` pins the exact resolved commit — so, unlike a `git pull --ff-only` vendor checkout that always tracks
whatever is newest upstream, installs stay reproducible until this repo's `pyproject.toml`/`uv.lock` are
deliberately updated. `app/config.py`'s `_default_dct_mcp_command()` locates the installed console script via
`sys.executable`'s sibling directory rather than `$PATH`, since the systemd unit invokes uvicorn by absolute path
and never "activates" the virtualenv.

## Decision: no server-side git clone for this project's own code

This project's own application code is **uploaded via `scp`** from the developer's working tree on every
install/update — there's no independent git checkout living on the server. This keeps "update" simple (re-upload +
`uv sync` + restart).

## Decision: own Nginx vhost and Let's Encrypt certificate

This project installs and owns its own Nginx, firewalld rules and TLS certificate — `deploy/remote/install_prereqs.sh`
installs `nginx`, `firewalld`, `epel-release`, `certbot` and `python3-certbot-nginx`, opens ports 80/443 in
firewalld, and `deploy/remote/setup_nginx.sh` renders `deploy/templates/nginx-dlpx-servicenow-orchestrator.conf.tmpl`
for `DOMAIN` and runs `certbot --nginx --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$DOMAIN" --redirect`.

This requires `DOMAIN` to already have a DNS A/AAAA record pointing at the server, and ports 80/443 reachable from
the internet for Certbot's HTTP-01 challenge (firewalld is opened by `install_prereqs.sh`; a cloud security group
in front of the host, if any, is outside this project's control and must allow them too).

**Idempotency pattern**: `setup_nginx.sh` re-renders the plain-HTTP vhost template from scratch on every run, then
lets `certbot --nginx` reinsert the SSL block, reusing/renewing the certificate already under
`/etc/letsencrypt/live/$DOMAIN` rather than issuing a new one every time. Re-running "Install" is safe at any
point, including after a domain change.

## Diagram

```
ServiceNow PDI (Business Rule, RESTMessageV2)
        │  HTTPS (443)
        ▼
   Nginx (this project's own vhost/certificate — server_name = DOMAIN)
        │  location /servicenow-webhook → proxy_pass → 127.0.0.1:8940 (loopback)
        ▼
┌───────────────────────────────────────────────────────────┐
│ dlpx-servicenow-orchestrator (Python — FastAPI/uvicorn)     │
│  - POST /servicenow-webhook                                  │
│  - incident_agent.py: Claude call (app name + timestamp)     │
│  - delphix_client.py: MCP tool calls (provision/tag/delete)  │
│  - servicenow_client.py: Table API PATCH (work_notes + state) │
│  - mcp_client.py: owns the long-lived dxi-mcp-server session │
└───────────────────────────────────────────────────────────┘
        │  stdio (subprocess, spawned by this app at startup)
        ▼
dxi-mcp-server ──▶ Delphix DCT ──▶ Delphix Engine
```

## Server layout

```
/opt/dlpx-servicenow-orchestrator/
├── app/          # application source code (uploaded via scp on every install/update)
│   └── .venv/    # created by `uv sync` — includes dxi-mcp-server's `dct-mcp-server` console script
└── bin/check_status.sh   # permanently installed for the "status" action

/etc/dlpx-servicenow-orchestrator/
└── orchestrator.env   # ANTHROPIC_API_KEY, DCT_BASE_URL, DCT_API_KEY, SERVICENOW_*, etc. (600, root:root)

/etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf   # this project's own vhost (see setup_nginx.sh)
/etc/letsencrypt/live/<DOMAIN>/                        # this project's own certificate
```

systemd unit: `dlpx-servicenow-orchestrator` (uvicorn, port `127.0.0.1:8940`), running as the dedicated system
user `svcnow-orch`.

## Decision: `LLM_PROVIDER` — Anthropic by default, local Ollama as a no-cost option

`app/incident_agent.py` makes exactly one LLM call per incident: extract `app_name` + `problem_timestamp` from the
incident text via forced tool-calling. Even at Anthropic's cheapest tier (`claude-haiku-4-5`, `max_tokens=300`,
a short prompt) this is a real per-call cost, so `settings.llm_provider` (`"anthropic"` | `"ollama"`) lets it run
against a fully local model instead — no external API call, no per-incident cost — while keeping Anthropic as the
default and as a fallback if the local model isn't reliable enough. `extract_incident_context()` stays the single
entry point `app/main.py` calls; it just dispatches to `_extract_via_anthropic()` (unchanged) or
`_extract_via_ollama()` based on that setting. Both Anthropic and Ollama clients are constructed lazily (not at
import time), so an Ollama-only deployment never needs `ANTHROPIC_API_KEY` set.

**Ollama also speaks tool-calling**, in an OpenAI-style shape: `{"type": "function", "function": {"name", "description",
"parameters"}}`, vs. Anthropic's `{"name", "description", "input_schema"}`. Since both use a plain JSON Schema
object for the arguments, `_OLLAMA_TOOL` reuses `_EXTRACT_TOOL["input_schema"]` directly as `parameters` rather
than keeping two copies of the schema in sync. The model must support tool calling — `llama3.2` and `qwen2.5` do;
not every model Ollama can run does.

### Model/hardware sizing

Ollama runs models via llama.cpp on quantized (GGUF) weights. Rule of thumb for RAM: **~0.5-0.6 GB per billion
parameters** at Ollama's default quantization (Q4_K_M), plus a small, mostly-fixed amount for context/runtime
overhead (this task's prompt is a few hundred tokens at most, so KV-cache overhead is negligible next to the
weights themselves).

| Model (Ollama tag) | Download | RAM once loaded | Fit for this app |
|---|---|---|---|
| `llama3.2:3b` (default) | ~2.0 GB | ~3 GB | Recommended on modest hardware — supports tool calling, safe margin on a host with only ~4-8GB free |
| `qwen2.5:3b` | ~1.9 GB | ~3 GB | Equivalent alternative; Qwen models are often cited as reliable at structured output |
| `llama3.1:8b` | ~4.7 GB | ~6-7 GB | Only if the host genuinely has 8GB+ free after every other service — risky at the low end of a 4-8GB range |
| `qwen2.5:1.5b` | <1 GB | ~1-2 GB | Fits easily, but a higher risk of skipping the tool call on an already-simple-but-precision-sensitive task |

No GPU needed — CPU-only inference for a 3B Q4 model on a modern multi-core CPU runs roughly 10-30 tokens/s, i.e.
a few seconds per incident (the actual output is just two short fields via the tool call). That's fine here: the
ServiceNow Business Rules that trigger this webhook are `when: async`, and this app has no sub-second latency
requirement — it's a background automation step, not an interactive chat.

`deploy/remote/install_prereqs.sh` installs Ollama unconditionally (its own idle footprint is negligible — just
the server process, no model loaded until a request comes in), so switching `LLM_PROVIDER` later doesn't need a
reinstall; `deploy/remote/configure_and_start.sh` only runs `ollama pull "$OLLAMA_MODEL"` when
`LLM_PROVIDER=ollama`, to avoid an unnecessary multi-GB download otherwise. Given the modest RAM budget,
`install_prereqs.sh` also drops in `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_NUM_PARALLEL=1` (this app only ever
issues one sequential call per incident — no concurrency to gain from Ollama's defaults) and
`OLLAMA_KEEP_ALIVE=5m` (frees the loaded model's RAM between incidents, trading a few seconds of reload latency
on the next cold call).

**Trade-off accepted knowingly**: a 3B model is meaningfully less reliable than Claude Haiku at following the
tool-calling contract on free-form incident text. `_extract_via_ollama()` raises `IncidentAgentError` (same error
surface `_extract_via_anthropic()` already has) when the model doesn't return a tool call — `main.py`'s existing
top-level handler catches that and leaves a `work_notes` comment on the incident rather than failing silently, so
a bad extraction is visible to the analyst either way. Before switching the default, compare extraction quality
against both providers on real incident text (see the plan's verification steps).

## Decision: the orchestrator owns both ends of the incident lifecycle

Initially, ServiceNow's Business Rules fired on `In Progress` (provision) and `Resolved`/`Closed`/`Canceled`
(teardown) — i.e. the analyst drove every transition. This was revised after the first few end-to-end tests: the
analyst now only ever moves an incident to two states, both meaning "I want the orchestrator to act":

- **`Prioritized`** (a custom `Incident.state` choice, value `15`) → triggers provisioning. Once the VDB is ready,
  the orchestrator itself promotes the incident to **`In Progress`** — so that state now specifically means "the
  environment is ready, investigation under way," instead of just "someone clicked a button."
- **`Resolved`** → triggers teardown. Once the VDB is destroyed (or confirmed absent), the orchestrator itself
  moves the incident to **`Closed`**.

This is why Business Rule 2's filter condition is `Resolved OR Canceled` — deliberately **not** `Closed` anymore.
`Closed` is now purely a byproduct of the orchestrator's own teardown flow; if the Business Rule still listened
for it, the orchestrator setting `state=Closed` via the Table API would re-trigger the same rule, sending a second
`teardown` webhook call for an incident whose VDB was already deleted (harmless — `find_vdb_by_incident_tag`
returns nothing and the code just logs a warning and closes again — but it leaves a redundant "nothing to
destroy" `work_notes` entry). `Canceled` stays in the condition since an analyst can reach it directly without
going through `Resolved`, and that path still needs cleanup.

## Decision: report failures back to the incident, without touching `state`

Early testing showed a bad failure mode: an incident moved to `Prioritized`, the webhook fired, something failed
downstream (bad tag, unprovisionable timestamp, whatever), and the incident just... sat there with no visible
change — the analyst had no way to tell the automation had even run, let alone why it failed, short of asking
someone to check `journalctl`. `main.py`'s top-level exception handler now catches any failure from either flow
and best-effort PATCHes `work_notes` with `"Delphix VDB <provisioning|teardown> failed."` plus a truncated
rendering of the error — enough for the analyst to know something is wrong and have a rough idea what, without
needing server access. This second PATCH is itself wrapped in `try/except`: if ServiceNow is unreachable too, that
failure is logged but doesn't mask the original `502`.

`state` is deliberately left untouched on failure. Setting it to `In Progress`/`Closed` anyway would make a
failed run look identical to a successful one on the Kanban board — exactly the ambiguity this whole
Prioritized/In Progress split was introduced to avoid.

## Tag-based incident ↔ VDB linkage

The provisioned VDB is tagged `incident:<number>` right after creation. Teardown looks the VDB up by that tag
instead of asking Claude again — deterministic, and it survives an orchestrator restart between provision and
teardown.

## dxi-mcp-server's real tool surface: `discovery` + `execute`, not per-resource tools

Earlier design work (done against a different MCP wrapper) assumed dxi-mcp-server exposed fixed per-resource
tools like `data_tool`/`job_tool` with actions such as `provision_by_timestamp`. Running the real, official
[dxi-mcp-server](https://github.com/delphix/dxi-mcp-server) live against the demo VM's dSources (via
`session.list_tools()`, at the time reached through an intermediate MCP proxy this project no longer depends on —
see "Decision: spawn dxi-mcp-server directly" above) showed this was wrong — it exposes exactly two tools:

- `discovery` — browse a cached OpenAPI spec of the full DCT REST API (`list_tags`, `list_operations`,
  `get_operation_schema`).
- `execute` — dispatch one DCT API call (`path` + `method` + `path_params`/`query_params`/`body`), wrapped in an
  envelope: `{"status": "success"|"error"|"confirmation_required", "response": {...}}`.

`app/mcp_client.py`'s `dct_execute()` calls `execute` and unwraps that envelope, including transparently
resubmitting with `confirmation_token` when a destructive operation (e.g. delete) comes back as
`confirmation_required` — the gate exists for interactive clients to get human sign-off before something
destructive happens; here that sign-off already happened when the ServiceNow analyst moved the incident, so
auto-confirming (logged at WARNING for auditability) is the correct behavior for this headless flow.

**Deliberate choice, confirmed with the project owner**: the tool's own `confirmation_required` response embeds an
explicit instruction ("STOP. Display the message to the user and obtain their EXPLICIT approval before
proceeding — do NOT approve on their behalf.") and uses stricter wording for `confirmation_level: "manual"`
(seen on `delete_vdb`) than `"elevated"` (seen on `provision_by_timestamp`) — suggesting `manual` is meant to
always require a live human. This orchestrator auto-confirms both levels anyway: the whole point of the project
is zero-touch automation triggered by the ServiceNow incident transition, and gating teardown on a human clicking
"yes" somewhere would defeat that. If this code is ever reused in a context without that ServiceNow-transition
stand-in for approval, revisit this.

`app/delphix_client.py`'s actual paths/fields (`POST /vdbs/provision_by_timestamp` with `source_data_id` +
`auto_select_repository: true`, `POST /vdbs/{vdbId}/delete`, `GET /jobs/{jobId}` returning `target_id` on a
completed job, tags as `{"key", "value"}` objects) were all confirmed this way — either via
`get_operation_schema`, or by making real, read-only GET calls against the demo environment's actual tagged
dSources (`Suitecrm_master` → `app:CRM`, matching what Claude extracted from a real test incident).

Neither `/dsources` nor `/vdbs` support server-side filtering by tag in this DCT version — `find_dsource_by_app_tag`
and `find_vdb_by_incident_tag` list everything and filter client-side (VDBs additionally require one
`GET .../tags` call per VDB, since — unlike dSources — the list response doesn't embed tags inline). Fine for a
demo-sized environment; would need real pagination/filtering for a large one.

## Decision: fall back to the latest snapshot when the requested timestamp isn't provisionable

`incident_agent.py` falls back to the incident's `opened_at` when the text doesn't mention a clear time — which,
for a freshly-opened or genuinely time-less incident ("intermittent error"), is effectively "now." DCT rejects
provisioning from a point that far ahead of what's actually synced with a `400` whose `error_description` starts
with `"Cannot find refresh/provisionable point ..."` (confirmed live, real Oracle dSource). Rather than failing
the whole incident over this, `provision_vdb_by_timestamp()` (`app/delphix_client.py`) catches that specific
error (matched on the `"provisionable point"` substring — narrow on purpose, so unrelated 400s still propagate)
and retries once with `timestamp` omitted entirely, which per the DCT API means "the latest available point."
Logged at WARNING so it's visible which incidents actually got the latest snapshot instead of their requested
time. Confirmed with the project owner as the desired behavior over hard-failing.

**Known, accepted limitation** (not addressed by the above): one incident maps to exactly one VDB
(`VDB_<number>`, tagged `incident:<number>`). If the incident text mentions more than one application (e.g. "ERP
and CRM both down"), Claude may return a combined `app_name` that matches no dSource tag, and the flow fails with
a `DelphixLookupError` (502, logged). Confirmed with the project owner as acceptable — not a scenario this demo
needs to support.

## Decision: always send a short, explicit `database_name`

Provisioning against a real Oracle dSource (`Oracle_master`, tagged `app:ERP`) failed with a DCT 500:
`"databaseName":{"details":"The string must not be more than 8 characters long."}`. DCT defaults `database_name`
to the `name` field when it isn't set explicitly, and `name` is `VDB_<incident number>` (e.g.
`"VDB_INC0010005"`, 14 characters) — fine against MSSQL (no such limit, confirmed working earlier), but Oracle
enforces a hard 8-character `database_name`/SID limit.

Rather than branching on `database_type` (which would need an extra lookup, and more special cases as more
database types get added to the demo), `provision_vdb_by_timestamp()` always sends an explicit, short
`database_name` — `_short_database_name()` derives it deterministically from the incident number's digits (e.g.
`"VDB_INC0010005"` → `"V0010005"`, 8 chars). `name` (the descriptive DCT-level label surfaced in `work_notes`) is
untouched. This is a visible behavior change for the database types that worked fine before (MSSQL VDBs now get
the short internal name too) — accepted as a reasonable, uniform trade-off rather than adding per-type branches
for a single constraint.

## work_notes: JDBC string and snapshot info, not host/port

`extract_connection_info()` (`app/delphix_client.py`) reports the VDB's `jdbc_connection_string` field directly —
DCT returns a ready-to-use JDBC URL on the VDB object itself (confirmed live on a real MSSQL VDB:
`jdbc:sqlserver://10.160.1.62\MSSQLSERVER:1433`), so there's no need to assemble one from separate host/port
fields (which, as originally implemented, were genuinely database-type-specific and error-prone — e.g. nested
under `appdata_source_params.postgresPort` for Postgres, unconfirmed for MSSQL/Oracle). If a database type doesn't
populate `jdbc_connection_string`, the code falls back to reporting `fqdn`/`ip_address` with a note, rather than
guessing a port.

`work_notes` also reports the source dSource's name (already known — it's the same object
`find_dsource_by_app_tag` resolved before provisioning, no extra lookup needed) and
`parent_timeflow_timestamp` from the VDB object — the actual point-in-time Delphix used, which may differ
slightly from the requested timestamp if there was no exact snapshot match.

## Remaining open assumption

None outstanding at the moment — the tool surface, tag conventions, Nginx routing, JDBC string field, and
confirmation-gate handling have all been confirmed against the live VM. Revisit this section if the DCT version
or dxi-mcp-server changes.
