import httpx

from .config import settings

# Standard ServiceNow Incident state values (see the runbook's "Default
# Incident states" table). Not exposed as config: these are OOB platform
# constants for the `state` choice field, not something this deployment
# customizes independently of the ServiceNow instance itself.
STATE_IN_PROGRESS = "2"
STATE_CLOSED = "7"


async def patch_incident(sys_id: str, fields: dict) -> None:
    url = f"{settings.servicenow_instance_url}/api/now/table/incident/{sys_id}"
    async with httpx.AsyncClient(timeout=settings.request_timeout_seconds) as client:
        response = await client.patch(
            url,
            json=fields,
            auth=(settings.servicenow_user, settings.servicenow_password),
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        response.raise_for_status()
