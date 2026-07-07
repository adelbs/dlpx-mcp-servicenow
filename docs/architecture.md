# Architecture

## Problem

ServiceNow needs a public HTTPS endpoint to notify this orchestrator of Incident state changes (via
`RESTMessageV2` Business Rules — see [servicenow_runbook_rebuild_from_scratch.md](servicenow_runbook_rebuild_from_scratch.md)).
Once notified, the orchestrator needs to read the incident
text, decide which Delphix dataset/timestamp it refers to, provision or destroy a VDB accordingly, and let
ServiceNow know via the Table API. It shares its host with `dlpx-mcp-remote-server`, an already-running MCP
wrapper around Delphix's own `dxi-mcp-server`.

## Decision: talk to Delphix through the local mcp-proxy, not the public OAuth gateway

`dlpx-mcp-remote-server` already exposes `dxi-mcp-server`'s tools in two ways: a public, OAuth-protected endpoint
(`dlpx-mcp-gateway`, for remote clients like Claude Web) and a private one, `mcp-proxy`, listening on
`127.0.0.1:8930` with no authentication of its own (loopback only). Since this orchestrator runs on the very same
host, it connects directly to the private one — no OAuth token to manage, no dependency on the gateway's public
domain/certificate being healthy, only on the `dlpx-dct-mcp-proxy` systemd unit being up.

## Decision: don't hard-couple systemd units across projects

The orchestrator's systemd unit declares `After=dlpx-dct-mcp-proxy.service` (ordering only), not `Requires=`. The
two projects are deployed, updated and uninstalled independently; a hard `Requires=` would mean
restarting/stopping `dlpx-mcp-remote-server` also stops this orchestrator, which isn't desired.

## Decision: no server-side git clone for this project's own code

Unlike `dxi-mcp-server` (an external upstream project, git-cloned untouched on the server), this project's own
application code is **uploaded via `scp`** from the developer's working tree on every install/update — there's no
independent git checkout living on the server. This keeps "update" simple (re-upload + `uv sync` + restart) and
matches how `dlpx-mcp-remote-server` itself treats its own custom `gateway/` code.

## Decision: no Nginx vhost/certificate of our own — patch the shared one instead

The original plan was for this project to get its own subdomain, Nginx vhost and Let's Encrypt certificate, same
as `dlpx-mcp-remote-server` does for its gateway. On the actual lab VM this turned out not to be possible: its
public hostname (`<something>.vm.cld.sr`) has **no wildcard DNS**, so there's no spare subdomain to point at this
server, and `dlpx-mcp-remote-server`'s vhost (`/etc/nginx/conf.d/dlpx-mcp.conf`) already claims the entire
hostname with its own certificate.

Instead, `deploy/remote/patch_shared_nginx.sh` idempotently inserts a `location /servicenow-webhook` block
directly into that existing file (anchored right after Certbot's `ssl_dhparam` line, which is always the last
directive Certbot appends), proxying to this app on `127.0.0.1:8940`. It removes and reinserts its own
marker-delimited block on every run, so re-running it is a no-op change.

**Trade-off accepted knowingly**: `dlpx-mcp-remote-server`'s own installer rewrites `dlpx-mcp.conf` from scratch on
every install (that's what makes *its* install idempotent across domain changes) — which wipes the block this
project adds. If `dlpx-mcp-remote-server` is ever reinstalled/updated on this host, re-run this orchestrator's
"Install" option (`./orchestrator.sh 1`) to reapply the route; `check_status.sh` also flags when the block is
missing. This project never touches Certbot, firewalld, or EPEL — those stay entirely owned by
`dlpx-mcp-remote-server`.

## Diagram

```
ServiceNow PDI (Business Rule, RESTMessageV2)
        │  HTTPS (443)
        ▼
   Nginx (dlpx-mcp-remote-server's shared vhost/certificate — server_name = its own hostname)
        │  location /servicenow-webhook → proxy_pass → 127.0.0.1:8940 (loopback)
        │  (location / still goes to dlpx-mcp-gateway on 127.0.0.1:8931, unaffected)
        ▼
┌───────────────────────────────────────────────────────────┐
│ dlpx-servicenow-orchestrator (Python — FastAPI/uvicorn)     │
│  - POST /servicenow-webhook                                  │
│  - incident_agent.py: Claude call (app name + timestamp)     │
│  - delphix_client.py: MCP tool calls (provision/tag/delete)  │
│  - servicenow_client.py: Table API PATCH (work_notes + state) │
└───────────────────────────────────────────────────────────┘
        │  MCP (Streamable HTTP/SSE), loopback, no auth  127.0.0.1:8930
        ▼
┌───────────────────────────────────────────────────────────┐
│ mcp-proxy (part of dlpx-mcp-remote-server, already running) │
│  spawns dxi-mcp-server as a subprocess via stdio             │
└───────────────────────────────────────────────────────────┘
        │  stdio (subprocess)
        ▼
dxi-mcp-server ──▶ Delphix DCT ──▶ Delphix Engine
```

## Server layout

```
/opt/dlpx-servicenow-orchestrator/
├── app/          # application source code (uploaded via scp on every install/update)
│   └── .venv/    # created by `uv sync`
└── bin/check_status.sh   # permanently installed for the "status" action

/etc/dlpx-servicenow-orchestrator/
└── orchestrator.env   # ANTHROPIC_API_KEY, SERVICENOW_*, MCP_LOCAL_URL, etc. (600, root:root)
```

systemd unit: `dlpx-servicenow-orchestrator` (uvicorn, port `127.0.0.1:8940`), running as the dedicated system
user `svcnow-orch` — distinct from `dlpx-mcp-remote-server`'s own `dlpxmcp` user, so file ownership never
overlaps. Nginx itself is not installed or owned by this project — it's `dlpx-mcp-remote-server`'s Nginx, patched
in place (see the decision above).

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
`session.list_tools()` on the local mcp-proxy) showed this was wrong — it exposes exactly two tools:

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
