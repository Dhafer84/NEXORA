import json
import logging

import pytest
from app.ai.base import ProviderError, ProviderReply, ToolCall
from app.ai.engine import SIMULATION_NOTICE, AssistantEngine
from app.database import connect
from app.main import create_app
from conftest import KEY, auth
from fastapi.testclient import TestClient
from pydantic import BaseModel, ConfigDict

AI_KEY = "nvapi-" + "q4" * 30


class Scripted:
    """Test double replaying prepared replies; records what the backend sent."""

    name = "scripted"
    model = "script"
    real = True

    def __init__(self, *replies):
        self.replies = list(replies)
        self.requests = []

    def configured(self):
        return True

    def complete(self, messages, tools, timeout):
        self.requests.append({"messages": json.loads(json.dumps(messages)), "tools": tools})
        reply = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        if isinstance(reply, Exception):
            raise reply
        return reply


def call(name, arguments="{}", call_id="c1"):
    return ProviderReply(text="", tool_calls=[ToolCall(call_id, name, arguments)])


@pytest.fixture
def app_factory(db_settings):
    def build(provider=None, **overrides):
        settings = db_settings.model_copy(update=overrides)
        app = create_app(settings)
        if provider is not None:
            app.state.engine = AssistantEngine(settings, app.state.tools, provider)
        return TestClient(app)

    return build


def new_conversation(client):
    response = client.post("/api/v1/conversations", json={"title": "Essai"}, headers=auth())
    assert response.status_code == 201
    return response.json()["id"]


def send(client, conversation_id, content):
    return client.post(
        f"/api/v1/conversations/{conversation_id}/messages",
        json={"content": content},
        headers=auth(),
    )


def history(client, conversation_id):
    return client.get(f"/api/v1/conversations/{conversation_id}", headers=auth()).json()


def test_conversation_routes_require_key(app_factory):
    with app_factory() as client:
        assert client.post("/api/v1/conversations", json={}).status_code == 401
        assert client.get("/api/v1/conversations").status_code == 401


def test_without_provider_health_and_metrics_still_work(app_factory):
    with app_factory() as client:
        conversation = new_conversation(client)
        response = send(client, conversation, "Bonjour")
        assert response.status_code == 503
        assert response.json()["detail"]["code"] == "ai_not_configured"
        assert client.get("/health/live").status_code == 200
        assert client.get("/health/ready", headers=auth()).status_code == 200
        assert client.get("/api/v1/server/metrics", headers=auth()).status_code == 200
        status = client.get("/api/v1/ai/status", headers=auth()).json()
        assert status["configured"] is False and status["provider"] is None


def test_metrics_question_uses_tool_and_answers(app_factory):
    provider = Scripted(call("server_metrics"), ProviderReply("Le processeur est à 12 %."))
    with app_factory(provider) as client:
        conversation = new_conversation(client)
        response = send(client, conversation, "Quelle est la charge du serveur ?")
        assert response.status_code == 200
        body = response.json()
        assert body["status"] == "completed"
        assert body["provider"] == {"name": "scripted", "model": "script", "real": True}
        assert body["tool_executions"][0]["status"] == "succeeded"
        assert [m["role"] for m in body["messages"]] == ["user", "tool", "assistant"]
        assert body["messages"][-1]["content"] == "Le processeur est à 12 %."

    first, second = provider.requests
    assert first["messages"][0]["role"] == "system"
    assert first["messages"][-1] == {"role": "user", "content": "Quelle est la charge du serveur ?"}
    assert {t["function"]["name"] for t in first["tools"]} == {
        "server_metrics",
        "database_status",
        "test_action",
    }
    assert second["messages"][-1]["role"] == "tool"
    assert "cpu_percent" in second["messages"][-1]["content"]


def test_history_is_persisted_and_survives_restart(app_factory):
    provider = Scripted(ProviderReply("Bonjour !"))
    with app_factory(provider) as client:
        conversation = new_conversation(client)
        send(client, conversation, "Salut")
    with app_factory() as client:
        stored = history(client, conversation)
        assert [(m["role"], m["content"]) for m in stored["messages"]] == [
            ("user", "Salut"),
            ("assistant", "Bonjour !"),
        ]
        assert client.get("/api/v1/conversations", headers=auth()).json()[0]["id"] == conversation


def test_previous_turns_are_sent_as_context(app_factory):
    provider = Scripted(ProviderReply("Première réponse"))
    with app_factory(provider) as client:
        conversation = new_conversation(client)
        send(client, conversation, "Un")
        send(client, conversation, "Deux")
    contents = [m["content"] for m in provider.requests[-1]["messages"][1:]]
    assert contents == ["Un", "Première réponse", "Deux"]


def test_simulated_provider_is_never_presented_as_real(app_factory):
    with app_factory(nexora_ai_provider="simulated") as client:
        status = client.get("/api/v1/ai/status", headers=auth()).json()
        assert status["provider"]["real"] is False
        assert "aucune connexion" in status["detail"]
        conversation = new_conversation(client)
        body = send(client, conversation, "Utilisation du disque ?").json()
        assert body["provider"]["real"] is False
        assert body["tool_executions"][0]["tool"] == "server_metrics"
        assert body["messages"][-1]["content"].startswith(SIMULATION_NOTICE)


def test_sensitive_action_waits_for_approval(app_factory, db_settings):
    provider = Scripted(call("test_action", '{"label": "essai", "value": 3}'))
    with app_factory(provider) as client:
        conversation = new_conversation(client)
        body = send(client, conversation, "Lance l’action de test").json()
        assert body["status"] == "pending_approval"
        execution = body["tool_executions"][0]
        assert execution["status"] == "pending_approval"
        approval = execution["approval"]
        assert approval["conversation_id"] == conversation
        assert "Validation requise" in body["messages"][-1]["content"]
        assert approval["id"] in body["messages"][-1]["content"]
        assert len(provider.requests) == 1  # The engine stops and waits.

        client.post(
            f"/api/v1/approvals/{approval['id']}/approve",
            json={"arguments_hash": approval["arguments_hash"]},
            headers=auth(),
        )
        done = client.post(
            f"/api/v1/approvals/{approval['id']}/execute",
            json={"arguments": {"label": "essai", "value": 3}},
            headers=auth(),
        )
        assert done.json()["status"] == "succeeded"
        messages = history(client, conversation)["messages"]
        assert messages[-1]["role"] == "tool"
        assert messages[-1]["tool_execution_id"] == execution["execution_id"]
        assert '"succeeded"' in messages[-1]["content"]


@pytest.mark.parametrize(
    ("reply", "status", "code"),
    [
        (call("run_shell", '{"cmd": "rm -rf /"}'), "denied", "unknown_tool"),
        (call("test_action", '{"label": "x", "value": -1}'), "invalid", "invalid_arguments"),
        (call("server_metrics", "not json"), "invalid", "invalid_arguments"),
    ],
)
def test_model_cannot_bypass_backend_controls(app_factory, db_settings, reply, status, code):
    provider = Scripted(reply, ProviderReply("Je ne peux pas faire cela."))
    with app_factory(provider) as client:
        body = send(client, new_conversation(client), "Fais quelque chose").json()
    assert body["status"] == "completed"
    assert body["tool_executions"][0]["status"] == status
    assert body["tool_executions"][0]["error_code"] == code
    assert code in provider.requests[1]["messages"][-1]["content"]
    with connect(db_settings) as connection:
        assert (
            connection.execute("SELECT count(*) AS n FROM approval_requests").fetchone()["n"] == 0
        )


def test_permissions_limit_exposed_tools(app_factory):
    provider = Scripted(call("database_status"), ProviderReply("Refusé."))
    with app_factory(provider, nexora_permissions="server:read") as client:
        body = send(client, new_conversation(client), "La base va bien ?").json()
    assert [t["function"]["name"] for t in provider.requests[0]["tools"]] == ["server_metrics"]
    assert body["tool_executions"][0]["error_code"] == "permission_denied"


def test_tool_call_limit_stops_loops(app_factory, db_settings):
    provider = Scripted(call("server_metrics"))  # Always asks for another tool call.
    with app_factory(provider, nexora_ai_max_tool_calls=3, nexora_ai_max_iterations=10) as client:
        body = send(client, new_conversation(client), "Boucle").json()
    assert body["status"] == "limit_reached"
    assert len(body["tool_executions"]) == 3
    assert "Limite de 3 appels" in body["messages"][-1]["content"]
    assert len(provider.requests) == 4


def test_iteration_limit_stops_loops(app_factory):
    provider = Scripted(call("server_metrics"))
    with app_factory(provider, nexora_ai_max_tool_calls=10, nexora_ai_max_iterations=2) as client:
        body = send(client, new_conversation(client), "Boucle").json()
    assert body["status"] == "limit_reached"
    assert len(provider.requests) == 2


def test_provider_failure_is_reported_without_secrets(app_factory, caplog):
    error = ProviderError("unavailable", "Fournisseur IA temporairement indisponible")
    provider = Scripted(error)
    with app_factory(provider) as client, caplog.at_level(logging.DEBUG):
        conversation = new_conversation(client)
        response = send(client, conversation, "Bonjour")
        assert response.status_code == 503
        assert response.json()["detail"]["code"] == "ai_unavailable"
        stored = history(client, conversation)["messages"]
        assert [(m["role"], m["status"]) for m in stored] == [
            ("user", "ok"),
            ("assistant", "error"),
        ]
        assert client.get("/api/v1/server/metrics", headers=auth()).status_code == 200
    assert KEY not in response.text + caplog.text
    assert AI_KEY not in response.text + caplog.text


def test_real_provider_key_never_leaks(app_factory, tmp_path, caplog):
    import httpx
    from app.ai.openai_compatible import OpenAICompatibleProvider

    key_file = tmp_path / "key"
    key_file.write_text(AI_KEY)
    settings_update = {
        "nexora_ai_provider": "openai_compatible",
        "nexora_ai_api_key_file": str(key_file),
    }
    with app_factory(**settings_update) as client, caplog.at_level(logging.DEBUG):
        engine = client.app.state.engine
        engine.provider = OpenAICompatibleProvider(
            engine.settings,
            httpx.Client(
                transport=httpx.MockTransport(
                    lambda request: httpx.Response(401, text=f"invalid {AI_KEY}")
                )
            ),
        )
        conversation = new_conversation(client)
        response = send(client, conversation, "Bonjour")
        stored = json.dumps(history(client, conversation))
        status = client.get("/api/v1/ai/status", headers=auth()).text
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "ai_auth"
    assert AI_KEY not in response.text + stored + status + caplog.text


def test_message_size_limits(app_factory):
    with app_factory(Scripted(ProviderReply("ok")), nexora_ai_max_input_chars=100) as client:
        conversation = new_conversation(client)
        assert send(client, conversation, "x" * 101).status_code == 422
        assert send(client, conversation, "   ").status_code == 422
        huge = client.post(
            f"/api/v1/conversations/{conversation}/messages",
            content=json.dumps({"content": "x" * 40000}),
            headers=auth() | {"content-type": "application/json"},
        )
        assert huge.status_code == 413
        assert history(client, conversation)["messages"] == []


def test_concurrent_turn_on_same_conversation_is_refused(app_factory, db_settings):
    from uuid import UUID

    from app.ai.engine import turn_lock_key

    with app_factory(Scripted(ProviderReply("ok"))) as client:
        conversation = new_conversation(client)
        with connect(db_settings) as other:
            other.execute("SELECT pg_advisory_lock(%s)", (turn_lock_key(UUID(conversation)),))
            response = send(client, conversation, "Bonjour")
            assert response.status_code == 409
            assert response.json()["detail"]["code"] == "turn_in_progress"
        assert send(client, conversation, "Bonjour").status_code == 200


def test_unknown_conversation(app_factory):
    with app_factory(Scripted(ProviderReply("ok"))) as client:
        missing = "00000000-0000-0000-0000-000000000000"
        assert send(client, missing, "Bonjour").status_code == 404
        assert client.get(f"/api/v1/conversations/{missing}", headers=auth()).status_code == 404


def test_streamed_oversize_body_is_rejected(app_factory):
    def chunks():
        for _ in range(100):
            yield b"x" * 1000

    with app_factory() as client:
        response = client.post(
            "/api/v1/tools/server_metrics/invoke",
            content=chunks(),
            headers=auth() | {"content-type": "application/json"},
        )
    assert response.status_code == 413


# ----- Persisted actions in later turns ---------------------------------------


def start_action(client, provider):
    conversation = new_conversation(client)
    body = send(client, conversation, "Lance l’action de test").json()
    approval = body["tool_executions"][0]["approval"]
    provider.replies = [ProviderReply("Bilan.")]
    return conversation, approval


def system_context(provider):
    return provider.requests[-1]["messages"][0]["content"]


def test_approved_result_reaches_next_turn_without_rerun(app_factory, db_settings):
    provider = Scripted(call("test_action", '{"label": "bilan", "value": 4}'))
    with app_factory(provider) as client:
        conversation, approval = start_action(client, provider)
        prefix = f"/api/v1/approvals/{approval['id']}"
        client.post(
            prefix + "/approve", json={"arguments_hash": approval["arguments_hash"]}, headers=auth()
        )
        done = client.post(
            prefix + "/execute", json={"arguments": approval["arguments"]}, headers=auth()
        )
        executed_at = done.json()["result"]["executed_at"]
        body = send(client, conversation, "Quel est le résultat de cette action ?").json()
    assert body["status"] == "completed" and body["tool_executions"] == []
    context = system_context(provider)
    assert '"execution": "succeeded"' in context
    assert '"approval": "consumed"' in context
    assert executed_at[:19] in context and '"label": "bilan"' in context
    notice = next(
        m
        for m in provider.requests[-1]["messages"]
        if m["role"] == "assistant" and "Validation requise" in m["content"]
    )
    assert "désormais « consumed »" in notice["content"]
    with connect(db_settings) as connection:
        runs = connection.execute(
            "SELECT count(*) AS n FROM tool_executions WHERE status = 'succeeded'"
        ).fetchone()["n"]
    assert runs == 1


def test_rejected_action_is_reported_in_next_turn(app_factory):
    provider = Scripted(call("test_action", '{"label": "refus", "value": 1}'))
    with app_factory(provider) as client:
        conversation, approval = start_action(client, provider)
        client.post(f"/api/v1/approvals/{approval['id']}/reject", json={}, headers=auth())
        send(client, conversation, "Où en est l’action ?")
    context = system_context(provider)
    assert '"approval": "rejected"' in context
    assert '"error": "approval_rejected"' in context
    assert '"execution": "denied"' in context


def test_expired_action_is_reported_in_next_turn(app_factory, db_settings):
    provider = Scripted(call("test_action", '{"label": "delai", "value": 2}'))
    with app_factory(provider) as client:
        conversation, approval = start_action(client, provider)
        with connect(db_settings) as connection:
            connection.execute(
                "UPDATE approval_requests SET expires_at = now() - interval '1 s' WHERE id = %s",
                (approval["id"],),
            )
        send(client, conversation, "Et l’action ?")
    context = system_context(provider)
    assert '"approval": "expired"' in context
    assert '"error": "approval_expired"' in context


def test_no_actions_means_no_action_context(app_factory):
    provider = Scripted(ProviderReply("ok"))
    with app_factory(provider) as client:
        send(client, new_conversation(client), "Bonjour")
    assert "État actuel des actions" not in system_context(provider)


# ----- Global time budget ----------------------------------------------------------


class SlowParams(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SlowResult(BaseModel):
    ok: bool


def slow_tool_app(app_factory, provider_delay, tool_delay, budget, starts):
    import time

    from app.tools.registry import ToolSpec

    origin = []

    def slow_read(context, params):
        starts.append(time.monotonic() - origin[0])
        time.sleep(tool_delay)
        return SlowResult(ok=True)

    class SlowProvider(Scripted):
        def complete(self, messages, tools, timeout):
            self.requests.append(timeout)
            time.sleep(provider_delay)
            return ProviderReply(
                "", [ToolCall("c1", "slow_read", "{}"), ToolCall("c2", "slow_read", "{}")]
            )

    provider = SlowProvider(ProviderReply(""))
    client = app_factory(provider, nexora_ai_turn_deadline_seconds=budget)
    client.app.state.tools.registry.register(
        ToolSpec(
            "slow_read",
            "Lecture lente de test",
            SlowParams,
            SlowResult,
            frozenset({"server:read"}),
            "low",
            False,
            5,
            slow_read,
            lambda p: "Lecture",
        )
    )
    return client, origin


def test_no_tool_starts_after_the_turn_deadline(app_factory):
    import time

    starts = []
    client, origin = slow_tool_app(app_factory, 1.05, 0.4, 1.3, starts)
    with client:
        conversation = new_conversation(client)
        origin.append(time.monotonic())
        body = send(client, conversation, "Vérifie").json()
        elapsed = time.monotonic() - origin[0]
    assert body["status"] == "limit_reached"
    # The first tool starts in budget but only gets the remaining time; the second never starts.
    assert len(starts) == 1 and starts[0] < 1.3
    assert [e["status"] for e in body["tool_executions"]] == ["timed_out"]
    assert elapsed < 1.6


def test_tool_wait_is_capped_by_remaining_budget(app_factory):
    import time

    starts = []
    client, origin = slow_tool_app(app_factory, 1.0, 2.0, 1.3, starts)
    with client:
        conversation = new_conversation(client)
        origin.append(time.monotonic())
        body = send(client, conversation, "Vérifie").json()
        elapsed = time.monotonic() - origin[0]
    assert body["status"] == "limit_reached"
    assert body["tool_executions"][0]["status"] == "timed_out"
    assert len(body["tool_executions"]) == 1
    assert elapsed < 1.6
