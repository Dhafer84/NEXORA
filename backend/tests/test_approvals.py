import logging
import threading
import time
from datetime import datetime, timezone

import psycopg
import pytest
from app.database import connect
from app.main import create_app
from app.tools.builtin import ActionTestParameters, NoParameters, build_registry
from app.tools.permissions import Principal
from app.tools.registry import ToolRegistry, ToolSpec
from app.tools.service import ToolError, ToolService, arguments_hash
from conftest import KEY, auth
from fastapi.testclient import TestClient
from pydantic import BaseModel

ARGS = {"label": "demo", "value": 7}


@pytest.fixture
def client(db_settings):
    with TestClient(create_app(db_settings)) as client:
        yield client


def request_action(client, arguments=ARGS):
    response = client.post(
        "/api/v1/tools/test_action/invoke", json={"arguments": arguments}, headers=auth()
    )
    assert response.status_code == 202
    return response.json()["approval"]


def approve(client, approval):
    return client.post(
        f"/api/v1/approvals/{approval['id']}/approve",
        json={"arguments_hash": approval["arguments_hash"]},
        headers=auth(),
    )


def execute(client, approval_id, arguments=ARGS):
    return client.post(
        f"/api/v1/approvals/{approval_id}/execute", json={"arguments": arguments}, headers=auth()
    )


def count(settings, sql, *params):
    with connect(settings) as connection:
        return connection.execute(sql, params).fetchone()["n"]


# ----- Direct tool calls ---------------------------------------------------------


def test_read_tool_runs_and_is_traced(client, db_settings):
    response = client.post("/api/v1/tools/server_metrics/invoke", json={}, headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "succeeded"
    assert 0 <= body["result"]["cpu_percent"] <= 100
    assert (
        count(db_settings, "SELECT count(*) AS n FROM tool_executions WHERE status = 'succeeded'")
        == 1
    )


def test_database_tool_reports_schema_version(client):
    response = client.post("/api/v1/tools/database_status/invoke", json={}, headers=auth())
    assert response.json()["result"]["available"] is True
    assert response.json()["result"]["schema_version"] == 1


def test_tool_catalogue_requires_key(client):
    assert client.get("/api/v1/tools").status_code == 401
    tools = client.get("/api/v1/tools", headers=auth()).json()
    assert {tool["name"] for tool in tools} == {"server_metrics", "database_status", "test_action"}
    assert all(tool["allowed"] for tool in tools)


def test_unknown_tool_is_refused_explicitly(client, db_settings):
    response = client.post("/api/v1/tools/run_shell/invoke", json={}, headers=auth())
    assert response.status_code == 404
    assert response.json()["detail"]["code"] == "unknown_tool"
    assert (
        count(db_settings, "SELECT count(*) AS n FROM tool_executions WHERE status = 'denied'") == 1
    )


def test_missing_permission_is_refused(db_settings):
    settings = db_settings.model_copy(update={"nexora_permissions": "server:read"})
    with TestClient(create_app(settings)) as client:
        response = client.post("/api/v1/tools/database_status/invoke", json={}, headers=auth())
        assert response.status_code == 403
        assert "database:read" in response.json()["detail"]["message"]
        tools = {
            t["name"]: t["allowed"] for t in client.get("/api/v1/tools", headers=auth()).json()
        }
        assert tools == {"server_metrics": True, "database_status": False, "test_action": False}


@pytest.mark.parametrize(
    ("tool", "arguments"),
    [
        ("server_metrics", {"path": "/etc"}),
        ("test_action", {"label": "demo", "value": 5000}),
        ("test_action", {"label": "$(reboot)", "value": 1}),
        ("test_action", {"label": "demo"}),
        ("test_action", {"label": "x" * 5000, "value": 1}),
    ],
)
def test_invalid_parameters_are_refused_without_echo(client, db_settings, tool, arguments):
    response = client.post(
        f"/api/v1/tools/{tool}/invoke", json={"arguments": arguments}, headers=auth()
    )
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "invalid_arguments"
    assert "reboot" not in response.text and "/etc" not in response.text
    assert count(db_settings, "SELECT count(*) AS n FROM approval_requests") == 0


def test_non_object_arguments_are_rejected(client):
    response = client.post(
        "/api/v1/tools/server_metrics/invoke", json={"arguments": [1, 2]}, headers=auth()
    )
    assert response.status_code == 422


# ----- Approval life cycle ----------------------------------------------------


def test_full_approval_cycle_and_replay(client, db_settings):
    approval = request_action(client)
    assert approval["status"] == "pending"
    assert "demo" in approval["summary"] and approval["risk"] == "medium"
    assert approval["arguments_hash"] == arguments_hash("test_action", ARGS)
    listed = client.get("/api/v1/approvals?status=pending", headers=auth()).json()
    assert [item["id"] for item in listed] == [approval["id"]]

    early = execute(client, approval["id"])
    assert early.status_code == 409
    assert early.json()["detail"]["code"] == "approval_pending"

    assert approve(client, approval).json()["status"] == "approved"
    assert approve(client, approval).status_code == 200  # idempotent

    first = execute(client, approval["id"])
    assert first.status_code == 200
    assert first.json()["status"] == "succeeded"
    assert first.json()["result"]["label"] == "demo"
    assert first.json()["replayed"] is False

    retry = execute(client, approval["id"])
    assert retry.status_code == 200
    assert retry.json()["replayed"] is True
    assert retry.json()["execution_id"] == first.json()["execution_id"]
    assert (
        count(db_settings, "SELECT count(*) AS n FROM tool_executions WHERE status = 'succeeded'")
        == 1
    )
    assert (
        client.get(f"/api/v1/approvals/{approval['id']}", headers=auth()).json()["status"]
        == "consumed"
    )


def test_approval_requires_hash_of_presented_parameters(client):
    approval = request_action(client)
    response = client.post(
        f"/api/v1/approvals/{approval['id']}/approve",
        json={"arguments_hash": arguments_hash("test_action", {"label": "demo", "value": 8})},
        headers=auth(),
    )
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "approval_arguments_mismatch"


def test_modified_parameters_require_new_approval(client, db_settings):
    approval = request_action(client)
    approve(client, approval)
    changed = execute(client, approval["id"], {"label": "demo", "value": 8})
    assert changed.status_code == 409
    assert changed.json()["detail"]["code"] == "approval_arguments_mismatch"
    assert (
        count(db_settings, "SELECT count(*) AS n FROM tool_executions WHERE status = 'succeeded'")
        == 0
    )
    # The original approval remains usable for the exact parameters.
    assert execute(client, approval["id"]).json()["status"] == "succeeded"


def test_rejected_approval_cannot_run(client, db_settings):
    approval = request_action(client)
    response = client.post(
        f"/api/v1/approvals/{approval['id']}/reject",
        json={"reason": "Pas maintenant"},
        headers=auth(),
    )
    assert response.json()["status"] == "rejected"
    assert approve(client, approval).status_code == 409
    refused = execute(client, approval["id"])
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "approval_rejected"
    assert (
        count(
            db_settings,
            "SELECT count(*) AS n FROM tool_executions WHERE error_code = 'approval_rejected'",
        )
        == 1
    )


def test_approved_action_can_still_be_revoked(client):
    approval = request_action(client)
    approve(client, approval)
    client.post(f"/api/v1/approvals/{approval['id']}/reject", json={}, headers=auth())
    assert execute(client, approval["id"]).status_code == 409


def test_expired_approval_cannot_be_approved_or_run(client, db_settings):
    approval = request_action(client)
    approve(client, approval)
    with connect(db_settings) as connection:
        connection.execute(
            "UPDATE approval_requests SET expires_at = now() - interval '1 second' WHERE id = %s",
            (approval["id"],),
        )
    response = execute(client, approval["id"])
    assert response.status_code == 410
    assert response.json()["detail"]["code"] == "approval_expired"
    assert (
        client.get(f"/api/v1/approvals/{approval['id']}", headers=auth()).json()["status"]
        == "expired"
    )
    assert approve(client, approval).status_code == 409
    assert (
        count(db_settings, "SELECT count(*) AS n FROM tool_executions WHERE status = 'succeeded'")
        == 0
    )


def test_pending_approval_expires_when_listed(client, db_settings):
    approval = request_action(client)
    with connect(db_settings) as connection:
        connection.execute("UPDATE approval_requests SET expires_at = now() - interval '1 s'")
    statuses = client.get("/api/v1/approvals", headers=auth()).json()
    assert statuses[0]["status"] == "expired"
    assert approve(client, approval).status_code == 409
    assert (
        count(
            db_settings,
            "SELECT count(*) AS n FROM tool_executions WHERE error_code = 'approval_expired'",
        )
        == 1
    )


def test_unknown_approval(client):
    response = client.get("/api/v1/approvals/00000000-0000-0000-0000-000000000000", headers=auth())
    assert response.status_code == 404
    assert client.get("/api/v1/approvals/not-a-uuid", headers=auth()).status_code == 422


def test_approvals_survive_restart(db_settings):
    with TestClient(create_app(db_settings)) as first:
        approval = request_action(first)
        approve(first, approval)
    with TestClient(create_app(db_settings)) as second:
        stored = second.get(f"/api/v1/approvals/{approval['id']}", headers=auth()).json()
        assert stored["status"] == "approved"
        assert stored["arguments"] == ARGS
        assert execute(second, approval["id"]).json()["status"] == "succeeded"
    with TestClient(create_app(db_settings)) as third:
        assert execute(third, approval["id"]).json()["replayed"] is True


# ----- Concurrency and execution limits ------------------------------------------


class Counted(BaseModel):
    calls: int


def counting_registry(calls, delay=0.3, timeout=5):
    lock = threading.Lock()

    def handler(context, params):
        with lock:
            calls.append(params.label)
        time.sleep(delay)
        return Counted(calls=len(calls))

    registry = ToolRegistry()
    registry.register(
        ToolSpec(
            name="test_action",
            description="Compteur",
            parameters=ActionTestParameters,
            result=Counted,
            permissions=frozenset({"test:execute"}),
            risk="medium",
            requires_approval=True,
            timeout_seconds=timeout,
            handler=handler,
            summarize=lambda p: "Compteur",
        )
    )
    return registry


def test_concurrent_executions_run_the_action_once(db_settings):
    calls = []
    service = ToolService(db_settings, counting_registry(calls))
    principal = Principal("personal", frozenset({"test:execute"}))
    with connect(db_settings) as connection:
        created = service.request(connection, principal, "test_action", ARGS, source="api")
        service.approve(connection, created.approval.id, created.approval.arguments_hash)

    results, errors = [], []
    barrier = threading.Barrier(8)

    def worker():
        try:
            with connect(db_settings) as connection:
                barrier.wait()
                results.append(
                    service.execute_approved(connection, principal, created.approval.id, ARGS)
                )
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == []
    assert calls == ["demo"]
    assert [r.replayed for r in results].count(False) == 1
    assert {r.execution_id for r in results} == {created.execution_id}
    assert count(db_settings, "SELECT count(*) AS n FROM tool_executions") == 1


def test_database_refuses_a_second_run_for_one_approval(db_settings):
    service = ToolService(db_settings, build_registry())
    principal = Principal("personal", frozenset({"test:execute"}))
    with connect(db_settings) as connection:
        created = service.request(connection, principal, "test_action", ARGS, source="api")
        with pytest.raises(psycopg.errors.UniqueViolation):
            for _ in range(2):
                connection.execute(
                    """INSERT INTO tool_executions (approval_request_id, tool_name, source, status)
                       VALUES (%s, 'test_action', 'api', 'running')""",
                    (created.approval.id,),
                )


def test_tool_timeout_is_recorded(db_settings):
    service = ToolService(db_settings, counting_registry([], delay=1.5, timeout=0.2))
    principal = Principal("personal", frozenset({"test:execute"}))
    with connect(db_settings) as connection:
        created = service.request(connection, principal, "test_action", ARGS, source="api")
        service.approve(connection, created.approval.id, created.approval.arguments_hash)
        started = time.monotonic()
        result = service.execute_approved(connection, principal, created.approval.id, ARGS)
    assert time.monotonic() - started < 1.2
    assert result.status == "timed_out"
    assert result.error_code == "timeout"


def test_tool_failure_hides_internal_details(db_settings, caplog):
    def broken(context, params):
        raise RuntimeError(f"password={KEY}")

    registry = ToolRegistry()
    registry.register(
        ToolSpec(
            name="broken_tool",
            description="Échec",
            parameters=NoParameters,
            result=NoParameters,
            permissions=frozenset({"server:read"}),
            risk="low",
            requires_approval=False,
            timeout_seconds=1,
            handler=broken,
            summarize=lambda p: "Échec",
        )
    )
    service = ToolService(db_settings, registry)
    with connect(db_settings) as connection, caplog.at_level(logging.DEBUG):
        result = service.request(
            connection,
            Principal("p", frozenset({"server:read"})),
            "broken_tool",
            {},
            source="api",
        )
        stored = connection.execute("SELECT * FROM tool_executions").fetchone()
    assert result.status == "failed"
    assert KEY not in caplog.text + str(stored) + result.model_dump_json()
    assert "RuntimeError" in caplog.text


def test_revoked_permission_blocks_approved_execution(db_settings):
    service = ToolService(db_settings, build_registry())
    with connect(db_settings) as connection:
        created = service.request(
            connection,
            Principal("p", frozenset({"test:execute"})),
            "test_action",
            ARGS,
            source="api",
        )
        service.approve(connection, created.approval.id, created.approval.arguments_hash)
        with pytest.raises(ToolError) as error:
            service.execute_approved(
                connection, Principal("p", frozenset()), created.approval.id, ARGS
            )
    assert error.value.code == "permission_denied"


def test_expiry_is_in_the_future(client):
    approval = request_action(client)
    expires = datetime.fromisoformat(approval["expires_at"])
    assert 500 < (expires - datetime.now(timezone.utc)).total_seconds() <= 600
