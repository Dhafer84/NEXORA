import logging

import pytest
from app.ai.base import ProviderError, ProviderReply
from app.ai.engine import SIMULATION_NOTICE, AssistantEngine
from app.ai.simulated import SimulatedProvider
from app.analysis import MAX_SUMMARY_CHARS, SYSTEM_PROMPT
from app.database import connect
from app.main import create_app
from conftest import auth
from fastapi.testclient import TestClient
from test_conversations import Scripted

# Synthetic summary: no real health data in tests.
SUMMARY = (
    "Période : du 1 au 7 novembre 2026 (fuseau Europe/Paris).\n"
    "Pas : moyenne 8 123 pas par jour sur 6 jours complets, 1 jour sans donnée."
)


@pytest.fixture
def app_factory(db_settings):
    def build(provider=None, **overrides):
        settings = db_settings.model_copy(update=overrides)
        app = create_app(settings)
        if provider is not None:
            app.state.engine = AssistantEngine(settings, app.state.tools, provider)
        return TestClient(app)

    return build


def analyse(client, summary=SUMMARY, name="scripted", model="script"):
    return client.post(
        "/api/v1/analysis/activity",
        json={"summary": summary, "recipient": {"name": name, "model": model}},
        headers=auth(),
    )


def stored_rows(settings):
    with connect(settings) as connection:
        return [
            connection.execute(f"SELECT count(*) AS n FROM {table}").fetchone()["n"]
            for table in ("conversations", "messages")
        ]


def test_routes_require_key(app_factory):
    with app_factory(Scripted(ProviderReply(text="ok"))) as client:
        assert client.get("/api/v1/analysis/recipient").status_code == 401
        response = client.post(
            "/api/v1/analysis/activity",
            json={"summary": SUMMARY, "recipient": {"name": "scripted", "model": "script"}},
        )
        assert response.status_code == 401


def test_recipient_is_described_without_contacting_it(app_factory):
    provider = Scripted(ProviderReply(text="ok"))
    with app_factory(provider) as client:
        body = client.get("/api/v1/analysis/recipient", headers=auth()).json()
    assert body["provider"] == {"name": "scripted", "model": "script", "real": True}
    assert body["configured"] is True
    assert body["stored"] is False
    assert provider.requests == []


def test_recipient_without_provider(app_factory):
    with app_factory() as client:
        body = client.get("/api/v1/analysis/recipient", headers=auth()).json()
        assert body["provider"] is None
        assert body["label"] == "Aucun fournisseur IA configuré"
        assert analyse(client).status_code == 503


def test_only_the_summary_is_sent_without_tools_nor_history(app_factory, db_settings):
    provider = Scripted(ProviderReply(text="Tendance stable sur la période."))
    with app_factory(provider) as client:
        # An existing conversation must not leak into the analysis.
        conversation = client.post(
            "/api/v1/conversations", json={"title": "Autre"}, headers=auth()
        ).json()["id"]
        client.post(
            f"/api/v1/conversations/{conversation}/messages",
            json={"content": "Message privé d’une autre discussion"},
            headers=auth(),
        )
        before = stored_rows(db_settings)
        provider.requests.clear()
        response = analyse(client)
    assert response.status_code == 200
    assert response.json()["text"] == "Tendance stable sur la période."
    assert response.json()["simulated"] is False
    (sent,) = provider.requests
    assert sent["tools"] == []
    assert sent["messages"] == [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": SUMMARY},
    ]
    # Nothing stored: no conversation, no message.
    assert stored_rows(db_settings) == before


def test_changed_recipient_needs_a_new_confirmation(app_factory):
    provider = Scripted(ProviderReply(text="ok"))
    with app_factory(provider) as client:
        response = analyse(client, model="un-autre-modele")
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "recipient_changed"
    assert provider.requests == []


def test_summary_limits(app_factory):
    provider = Scripted(ProviderReply(text="ok"))
    with app_factory(provider) as client:
        assert analyse(client, summary="").status_code == 422
        assert analyse(client, summary="x" * (MAX_SUMMARY_CHARS + 1)).status_code == 422
        extra = client.post(
            "/api/v1/analysis/activity",
            json={
                "summary": SUMMARY,
                "recipient": {"name": "scripted", "model": "script"},
                "conversation_id": "x",
            },
            headers=auth(),
        )
        assert extra.status_code == 422
    assert provider.requests == []


def test_provider_failure_keeps_content_out_of_logs(app_factory, caplog):
    provider = Scripted(ProviderError("unavailable", "Fournisseur IA injoignable"))
    with app_factory(provider) as client, caplog.at_level(logging.DEBUG):
        response = analyse(client)
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "ai_unavailable"
    assert "8 123" not in caplog.text and "novembre" not in caplog.text


def test_success_logs_sizes_only(app_factory, caplog):
    provider = Scripted(ProviderReply(text="Réponse avec 8 123 pas"))
    with app_factory(provider) as client, caplog.at_level(logging.DEBUG):
        assert analyse(client).status_code == 200
    assert "activity_analysis status=ok" in caplog.text
    assert "8 123" not in caplog.text


def test_simulated_provider_is_labelled(app_factory):
    with app_factory(SimulatedProvider()) as client:
        recipient = client.get("/api/v1/analysis/recipient", headers=auth()).json()
        assert recipient["label"].startswith("Fournisseur simulé")
        response = analyse(client, name="simulated", model="keyword-rules")
    assert response.status_code == 200
    body = response.json()
    assert body["simulated"] is True
    assert body["text"].startswith(SIMULATION_NOTICE)
    assert "Aucune IA réelle" in body["text"]
