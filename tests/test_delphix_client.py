from unittest.mock import AsyncMock, patch

import pytest

from app import mcp_client
from app.delphix_client import (
    DelphixJobError,
    _short_database_name,
    _to_iso8601,
    extract_job_id,
    provision_vdb_by_timestamp,
)


def test_to_iso8601_converts_space_separated_timestamp():
    assert _to_iso8601("2026-07-06 15:00:00") == "2026-07-06T15:00:00.000Z"


def test_to_iso8601_converts_naive_t_separated_timestamp():
    assert _to_iso8601("2026-07-06T15:00:00") == "2026-07-06T15:00:00.000Z"


def test_to_iso8601_passes_through_unparseable_value():
    assert _to_iso8601("2026-07-06T15:00:00.000Z") == "2026-07-06T15:00:00.000Z"


def test_extract_job_id_from_bare_job_object():
    assert extract_job_id({"id": "job-1", "status": "COMPLETED"}) == "job-1"


def test_extract_job_id_from_nested_job_envelope():
    # Real shape returned by POST /vdbs/provision_by_timestamp:
    # {"job": {"id": ..., "status": "STARTED", ...}, "vdb_id": "..."}
    response = {"job": {"id": "job-2", "status": "STARTED"}, "vdb_id": "1-MSSQL_DB_CONTAINER-647"}
    assert extract_job_id(response) == "job-2"


def test_extract_job_id_raises_when_missing():
    with pytest.raises(DelphixJobError):
        extract_job_id({"vdb_id": "1-MSSQL_DB_CONTAINER-647"})


def test_short_database_name_stays_within_oracle_limit():
    name = _short_database_name("VDB_INC0010005")
    assert name == "V0010005"
    assert len(name) <= 8


def test_short_database_name_falls_back_to_truncation_without_digits():
    assert _short_database_name("VDBNONUMBERS") == "VDBNONUM"


@pytest.mark.asyncio
async def test_provision_retries_from_latest_when_timestamp_not_provisionable():
    not_provisionable = mcp_client.DCTAPIError(
        "DCT API POST /vdbs/provision_by_timestamp failed: {'status': 'error', 'code': 'DCT_API_ERROR', "
        "'http_status': 400, 'message': 'HTTP 400: {\"error\":\"failed\",\"error_description\":"
        "\"Cannot find refresh/provisionable point 2026-07-07T17:54:09Z for source ORACLE_DB_CONTAINER-267\"}'}"
    )
    mock_execute = AsyncMock(side_effect=[not_provisionable, {"job": {"id": "job-1"}, "vdb_id": "vdb-1"}])

    with patch("app.delphix_client.mcp_client.dct_execute", new=mock_execute):
        result = await provision_vdb_by_timestamp("dsource-1", "2026-07-07 17:54:09", "VDB_INC1")

    assert result == {"job": {"id": "job-1"}, "vdb_id": "vdb-1"}
    assert mock_execute.await_count == 2
    first_call_body = mock_execute.await_args_list[0].kwargs["body"]
    second_call_body = mock_execute.await_args_list[1].kwargs["body"]
    assert "timestamp" in first_call_body
    assert "timestamp" not in second_call_body


@pytest.mark.asyncio
async def test_provision_does_not_retry_on_unrelated_error():
    other_error = mcp_client.DCTAPIError("DCT API POST /vdbs/provision_by_timestamp failed: some other error")
    mock_execute = AsyncMock(side_effect=other_error)

    with patch("app.delphix_client.mcp_client.dct_execute", new=mock_execute):
        with pytest.raises(mcp_client.DCTAPIError):
            await provision_vdb_by_timestamp("dsource-1", "2026-07-07 17:54:09", "VDB_INC1")

    assert mock_execute.await_count == 1
