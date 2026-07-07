import json
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app import delphix_client, servicenow_client
from app.main import app

FIXTURES = Path(__file__).parent


def _load(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


def test_provision_flow_calls_expected_sequence():
    payload = _load("sample_provision_payload.json")

    with (
        patch(
            "app.main.incident_agent.extract_incident_context",
            new=AsyncMock(return_value={"app_name": "CRM", "problem_timestamp": "2026-07-06 10:30:00"}),
        ),
        patch(
            "app.main.delphix_client.find_dsource_by_app_tag",
            new=AsyncMock(return_value={"id": "dsource-1", "name": "Suitecrm_master"}),
        ) as find_dsource,
        patch(
            "app.main.delphix_client.provision_vdb_by_timestamp",
            new=AsyncMock(return_value={"job": {"id": "job-1", "status": "STARTED"}, "vdb_id": "vdb-1"}),
        ) as provision,
        patch(
            "app.main.delphix_client.poll_job",
            new=AsyncMock(return_value={"target_id": "vdb-1", "status": "COMPLETED"}),
        ),
        patch(
            "app.main.delphix_client.get_vdb",
            new=AsyncMock(
                return_value={
                    "name": "VDB_INC0009009",
                    "jdbc_connection_string": "jdbc:sqlserver://vdb-host\\MSSQLSERVER:1433",
                    "database_name": "crmvdb",
                    "database_type": "MSSql",
                    "parent_timeflow_timestamp": "2026-07-06T15:00:00Z",
                }
            ),
        ),
        patch("app.main.delphix_client.tag_vdb", new=AsyncMock()) as tag_vdb,
        patch("app.main.servicenow_client.patch_incident", new=AsyncMock()) as patch_incident,
    ):
        client = TestClient(app)
        response = client.post("/servicenow-webhook", json=payload)

    assert response.status_code == 200
    find_dsource.assert_awaited_once_with("CRM")
    provision.assert_awaited_once()
    tag_vdb.assert_awaited_once_with("vdb-1", "incident", "INC0009009")
    patch_incident.assert_awaited_once()
    fields = patch_incident.await_args.args[1]
    assert "jdbc:sqlserver://vdb-host" in fields["work_notes"]
    assert "Suitecrm_master" in fields["work_notes"]
    assert "2026-07-06T15:00:00Z" in fields["work_notes"]
    assert fields["state"] == servicenow_client.STATE_IN_PROGRESS


def test_teardown_flow_without_vdb_still_updates_incident():
    payload = _load("sample_teardown_payload.json")

    with (
        patch("app.main.delphix_client.find_vdb_by_incident_tag", new=AsyncMock(return_value=None)),
        patch("app.main.servicenow_client.patch_incident", new=AsyncMock()) as patch_incident,
    ):
        client = TestClient(app)
        response = client.post("/servicenow-webhook", json=payload)

    assert response.status_code == 200
    patch_incident.assert_awaited_once()
    assert patch_incident.await_args.args[1]["state"] == servicenow_client.STATE_CLOSED


def test_teardown_flow_deletes_vdb_when_found():
    payload = _load("sample_teardown_payload.json")

    with (
        patch(
            "app.main.delphix_client.find_vdb_by_incident_tag",
            new=AsyncMock(return_value={"id": "vdb-1"}),
        ),
        patch(
            "app.main.delphix_client.delete_vdb", new=AsyncMock(return_value={"id": "job-2"})
        ) as delete_vdb,
        patch(
            "app.main.delphix_client.poll_job",
            new=AsyncMock(return_value={"status": "COMPLETED"}),
        ),
        patch("app.main.servicenow_client.patch_incident", new=AsyncMock()) as patch_incident,
    ):
        client = TestClient(app)
        response = client.post("/servicenow-webhook", json=payload)

    assert response.status_code == 200
    delete_vdb.assert_awaited_once_with("vdb-1")
    patch_incident.assert_awaited_once()
    assert patch_incident.await_args.args[1]["state"] == servicenow_client.STATE_CLOSED


def test_unknown_action_returns_400():
    payload = _load("sample_provision_payload.json") | {"action": "bogus"}
    client = TestClient(app)
    response = client.post("/servicenow-webhook", json=payload)
    assert response.status_code == 400


def test_provision_failure_leaves_a_work_note_without_changing_state():
    payload = _load("sample_provision_payload.json")

    with (
        patch(
            "app.main.incident_agent.extract_incident_context",
            new=AsyncMock(return_value={"app_name": "ERP, CRM", "problem_timestamp": "2026-07-06 10:30:00"}),
        ),
        patch(
            "app.main.delphix_client.find_dsource_by_app_tag",
            new=AsyncMock(side_effect=delphix_client.DelphixLookupError("No dSource tagged app='ERP, CRM' was found")),
        ),
        patch("app.main.servicenow_client.patch_incident", new=AsyncMock()) as patch_incident,
    ):
        client = TestClient(app)
        response = client.post("/servicenow-webhook", json=payload)

    assert response.status_code == 502
    patch_incident.assert_awaited_once()
    sys_id, fields = patch_incident.await_args.args
    assert sys_id == payload["sys_id"]
    assert "state" not in fields
    assert "provisioning failed" in fields["work_notes"]
    assert "No dSource tagged app='ERP, CRM' was found" in fields["work_notes"]


def test_notify_failure_does_not_raise_if_servicenow_patch_also_fails():
    payload = _load("sample_teardown_payload.json")

    with (
        patch(
            "app.main.delphix_client.find_vdb_by_incident_tag",
            new=AsyncMock(side_effect=RuntimeError("mcp-proxy unreachable")),
        ),
        patch(
            "app.main.servicenow_client.patch_incident",
            new=AsyncMock(side_effect=RuntimeError("ServiceNow also down")),
        ),
    ):
        client = TestClient(app)
        response = client.post("/servicenow-webhook", json=payload)

    assert response.status_code == 502
