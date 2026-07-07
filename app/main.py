import logging

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import delphix_client, incident_agent, servicenow_client
from .config import settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("orchestrator")

app = FastAPI(title="Delphix <-> ServiceNow Orchestrator")

_MAX_ERROR_LENGTH = 500


class IncidentWebhookPayload(BaseModel):
    action: str
    sys_id: str
    number: str
    short_description: str = ""
    description: str = ""
    opened_at: str = ""


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/servicenow-webhook")
async def servicenow_webhook(payload: IncidentWebhookPayload) -> dict:
    try:
        if payload.action == "provision":
            await _handle_provision(payload)
        elif payload.action == "teardown":
            await _handle_teardown(payload)
        else:
            raise HTTPException(status_code=400, detail=f"Unknown action '{payload.action}'")
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Failed to process incident %s (action=%s)", payload.number, payload.action)
        await _notify_failure(payload, exc)
        raise HTTPException(
            status_code=502,
            detail=f"Failed to process incident {payload.number}: {exc}",
        ) from exc

    return {"status": "ok"}


async def _notify_failure(payload: IncidentWebhookPayload, exc: Exception) -> None:
    # Best-effort: an incident whose provisioning/teardown blew up should
    # never look untouched to the analyst — leave a comment even though we
    # don't have a full success message to give them. Deliberately doesn't
    # touch `state`: the incident stays at Prioritized/Resolved (not
    # In Progress/Closed), since the automation didn't actually finish.
    action_label = "provisioning" if payload.action == "provision" else "teardown"
    error_text = str(exc)
    if len(error_text) > _MAX_ERROR_LENGTH:
        error_text = error_text[:_MAX_ERROR_LENGTH] + "... (truncated — see orchestrator logs for the full error)"
    work_notes = (
        f"Delphix VDB {action_label} failed. The incident was left as-is — please retry or check with the "
        f"Delphix team.\n\n"
        f"Error: {error_text}"
    )
    try:
        await servicenow_client.patch_incident(payload.sys_id, {"work_notes": work_notes})
    except Exception:
        logger.exception("Also failed to write the failure notice to incident %s's work_notes", payload.number)


async def _handle_provision(payload: IncidentWebhookPayload) -> None:
    context = await incident_agent.extract_incident_context(
        payload.short_description, payload.description, payload.opened_at
    )
    app_name = context["app_name"]
    timestamp = context.get("problem_timestamp") or payload.opened_at

    dsource = await delphix_client.find_dsource_by_app_tag(app_name)
    vdb_name = f"VDB_{payload.number}"

    provision_response = await delphix_client.provision_vdb_by_timestamp(
        dataset_id=dsource["id"], timestamp=timestamp, vdb_name=vdb_name
    )
    job = await delphix_client.poll_job(
        delphix_client.extract_job_id(provision_response),
        timeout=settings.job_poll_timeout_seconds,
        interval=settings.job_poll_interval_seconds,
    )

    # provision_by_timestamp's own response already includes vdb_id
    # directly; target_id on the completed job is the confirmed fallback.
    vdb_id = provision_response.get("vdb_id") or job["target_id"]
    vdb = await delphix_client.get_vdb(vdb_id)
    await delphix_client.tag_vdb(vdb_id, "incident", payload.number)

    connection_info = delphix_client.extract_connection_info(vdb)
    work_notes = (
        f"VDB {connection_info['name']} provisioned and ready for investigation.\n\n"
        f"Source dSource: {dsource.get('name', dsource['id'])}\n"
        f"Snapshot timestamp: {connection_info['snapshot_timestamp']}\n"
        f"Database: {connection_info['database_name']} ({connection_info['database_type']})\n\n"
        f"JDBC connection string:\n{connection_info['jdbc_connection_string']}"
    )
    # The incident enters this flow at "Prioritized" (the Business Rule's
    # trigger state) — once the VDB is ready, hand it back to the analyst
    # at "In Progress" so that state now specifically means "environment
    # ready, investigation under way".
    await servicenow_client.patch_incident(
        payload.sys_id,
        {"work_notes": work_notes, "state": servicenow_client.STATE_IN_PROGRESS},
    )


async def _handle_teardown(payload: IncidentWebhookPayload) -> None:
    vdb = await delphix_client.find_vdb_by_incident_tag(payload.number)
    if vdb is None:
        logger.warning("No VDB tagged incident:%s found — nothing to tear down", payload.number)
        await servicenow_client.patch_incident(
            payload.sys_id,
            {
                "work_notes": "No VDB associated with this incident was found; nothing to destroy.",
                "state": servicenow_client.STATE_CLOSED,
            },
        )
        return

    delete_response = await delphix_client.delete_vdb(vdb["id"])
    await delphix_client.poll_job(
        delphix_client.extract_job_id(delete_response),
        timeout=settings.job_poll_timeout_seconds,
        interval=settings.job_poll_interval_seconds,
    )
    # Closing here (rather than leaving it at Resolved) is what the
    # "Prioritized -> In Progress" / "Resolved -> Closed" lifecycle is
    # for — the orchestrator owns both ends of its own automation.
    await servicenow_client.patch_incident(
        payload.sys_id,
        {
            "work_notes": "VDB destroyed after incident resolution.",
            "state": servicenow_client.STATE_CLOSED,
        },
    )
