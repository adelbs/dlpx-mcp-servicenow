"""
Delphix access, via the DCT REST API dispatched through dxi-mcp-server's
generic `discovery`/`execute` tools (see app/mcp_client.py), spawned directly
as a stdio subprocess of this app (see docs/architecture.md).

dxi-mcp-server (the official Delphix DCT MCP server) does NOT expose
per-resource tools like "data_tool"/"job_tool" — earlier drafts of this
module assumed that shape based on a different MCP wrapper used during
design, which turned out to be wrong. The real surface is exactly two tools:
`discovery` (browse the cached OpenAPI spec) and `execute` (dispatch one DCT
API call: path + method + path_params/query_params/body). Every path,
operationId and field name below was confirmed live against the DCT REST API
behind dxi-mcp-server on the demo VM (via `discovery`'s get_operation_schema,
plus real GET calls against the demo dSources/VDBs), not just assumed.

Neither /dsources (list) nor /vdbs (list) support a server-side filter/tag
query in this DCT version, so tag lookups list everything and filter
client-side. dSource list responses embed `tags` inline; VDB list responses
do NOT, so find_vdb_by_incident_tag has to fetch each VDB's tags via a
separate call — fine for a demo-sized environment, not for a large one.
"""

import asyncio
import logging
import time
from datetime import datetime, timezone

from . import mcp_client

logger = logging.getLogger("orchestrator.delphix")

_TERMINAL_FAILURE_STATUSES = {"FAILED", "CANCELED", "ABANDONED"}
_NAIVE_TIMESTAMP_FORMATS = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S")


def _to_iso8601(timestamp: str) -> str:
    # DCT's "timestamp" fields are OpenAPI format=date-time (RFC3339) — a
    # plain "YYYY-MM-DD HH:MM:SS" string (the shape incident_agent.py asks
    # Claude for) gets rejected with a generic 422 "Input is not readable".
    # Reformat here rather than trust the LLM to emit an exact wire format.
    # Timezone is assumed UTC, since neither ServiceNow's nor the Delphix
    # engine's configured timezone is known to this code — acceptable for a
    # demo, not for precise point-in-time recovery across timezones.
    candidate = timestamp.strip()
    for fmt in _NAIVE_TIMESTAMP_FORMATS:
        try:
            dt = datetime.strptime(candidate, fmt)
        except ValueError:
            continue
        return dt.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return candidate


class DelphixLookupError(RuntimeError):
    pass


class DelphixJobError(RuntimeError):
    pass


def _has_tag(resource: dict, key: str, value: str) -> bool:
    return any(t.get("key") == key and t.get("value") == value for t in (resource.get("tags") or []))


def extract_job_id(response: dict) -> str:
    # Some write operations (e.g. provision_by_timestamp) return
    # {"job": {"id": ..., ...}, "vdb_id": ...} rather than a bare job
    # object — confirmed live: {'job': {'id': '...', 'status': 'STARTED',
    # ...}, 'vdb_id': '1-MSSQL_DB_CONTAINER-647'}.
    job_id = response.get("job_id") or response.get("id")
    if not job_id and isinstance(response.get("job"), dict):
        job_id = response["job"].get("id")
    if not job_id:
        raise DelphixJobError(f"Could not find a job id in response: {response}")
    return job_id


def extract_connection_info(vdb: dict) -> dict:
    # jdbc_connection_string and parent_timeflow_timestamp (the actual
    # snapshot/point-in-time Delphix provisioned from — may differ slightly
    # from the requested timestamp if there was no exact match) were
    # confirmed live on a real MSSQL VDB. Not every database_type is
    # guaranteed to populate jdbc_connection_string, so fqdn/ip_address is
    # kept as a fallback rather than showing nothing.
    jdbc = vdb.get("jdbc_connection_string")
    if not jdbc:
        host = vdb.get("fqdn") or vdb.get("ip_address") or "unknown"
        jdbc = f"(no JDBC string returned by Delphix for this database type — host: {host})"
    return {
        "name": vdb.get("name") or "unknown",
        "jdbc_connection_string": jdbc,
        "database_name": vdb.get("database_name") or vdb.get("name") or "unknown",
        "database_type": vdb.get("database_type") or "unknown",
        "snapshot_timestamp": vdb.get("parent_timeflow_timestamp") or "unknown",
    }


async def find_dsource_by_app_tag(app_name: str) -> dict:
    result = await mcp_client.dct_execute("/dsources", "GET", query_params={"limit": 1000})
    for item in result.get("items", []):
        if _has_tag(item, "app", app_name):
            return item
    raise DelphixLookupError(f"No dSource tagged app={app_name!r} was found")


def _short_database_name(name: str) -> str:
    # Oracle enforces a hard 8-character limit on database_name/SID —
    # confirmed live ("The string must not be more than 8 characters
    # long.") when DCT defaulted database_name to the full "VDB_<incident
    # number>" name (e.g. "VDB_INC0010005", 14 chars) provisioning from an
    # Oracle dSource; the same name worked fine against MSSQL, which has no
    # such limit. Deriving a short, deterministic name from the incident's
    # digits keeps database_name safe for every source type — "name" (the
    # descriptive DCT-level label shown in work_notes) is untouched.
    digits = "".join(ch for ch in name if ch.isdigit())
    return f"V{digits[-7:]}" if digits else name[:8]


async def provision_vdb_by_timestamp(dataset_id: str, timestamp: str, vdb_name: str) -> dict:
    body = {
        "source_data_id": dataset_id,
        "timestamp": _to_iso8601(timestamp),
        "name": vdb_name,
        "database_name": _short_database_name(vdb_name),
        "auto_select_repository": True,
    }
    try:
        return await mcp_client.dct_execute("/vdbs/provision_by_timestamp", "POST", body=body)
    except mcp_client.DCTAPIError as exc:
        # DCT rejects timestamps outside the dSource's synced timeflow range
        # (e.g. an incident with no clear time, where the fallback is
        # opened_at — effectively "now", which is usually beyond what's
        # synced yet) with a "Cannot find refresh/provisionable point ..."
        # 400. Retry once provisioning from the latest available point
        # (omitting "timestamp" — per the DCT API, that means "latest")
        # rather than hard-failing the whole incident over it.
        if "provisionable point" not in str(exc):
            raise
        logger.warning(
            "Requested timestamp %s isn't provisionable for dataset %s — retrying from the latest "
            "available point instead.",
            body["timestamp"],
            dataset_id,
        )
        retry_body = {k: v for k, v in body.items() if k != "timestamp"}
        return await mcp_client.dct_execute("/vdbs/provision_by_timestamp", "POST", body=retry_body)


async def get_vdb(vdb_id: str) -> dict:
    return await mcp_client.dct_execute("/vdbs/{vdbId}", "GET", path_params={"vdbId": vdb_id})


async def tag_vdb(vdb_id: str, key: str, value: str) -> None:
    await mcp_client.dct_execute(
        "/vdbs/{vdbId}/tags",
        "POST",
        path_params={"vdbId": vdb_id},
        body={"tags": [{"key": key, "value": value}]},
    )


async def find_vdb_by_incident_tag(incident_number: str) -> dict | None:
    result = await mcp_client.dct_execute("/vdbs", "GET", query_params={"limit": 1000})
    for item in result.get("items", []):
        tags_result = await mcp_client.dct_execute(
            "/vdbs/{vdbId}/tags", "GET", path_params={"vdbId": item["id"]}
        )
        if any(t.get("key") == "incident" and t.get("value") == incident_number for t in tags_result.get("tags", [])):
            return item
    return None


async def delete_vdb(vdb_id: str) -> dict:
    return await mcp_client.dct_execute(
        "/vdbs/{vdbId}/delete", "POST", path_params={"vdbId": vdb_id}, body={}
    )


async def poll_job(job_id: str, timeout: float, interval: float) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        job = await mcp_client.dct_execute("/jobs/{jobId}", "GET", path_params={"jobId": job_id})
        status = str(job.get("status") or "").upper()
        if status == "COMPLETED":
            return job
        if status in _TERMINAL_FAILURE_STATUSES:
            raise DelphixJobError(f"Job {job_id} ended with status {status}: {job.get('error_details')}")
        if time.monotonic() > deadline:
            raise DelphixJobError(f"Timed out waiting for job {job_id} to complete (last status={status})")
        logger.info("Job %s still %s, polling again in %ss", job_id, status, interval)
        await asyncio.sleep(interval)
