import logging

import psycopg
import pytest
from app.config import Settings
from app.main import create_app
from fastapi.testclient import TestClient
from pydantic import ValidationError

KEY = "a7" * 32
PASSWORD = "b8" * 32


@pytest.fixture
def settings():
    return Settings(nexora_api_key=KEY, postgres_password=PASSWORD)


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as client:
        yield client


def auth():
    return {"Authorization": f"Bearer {KEY}"}


def test_liveness_is_minimal_and_does_not_require_database(client, monkeypatch):
    def fail(_):
        pytest.fail("Liveness must not access the database")

    monkeypatch.setattr("app.main.check_database", fail)
    response = client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("path", ["/health/ready", "/api/v1/auth/check", "/api/v1/server/metrics"])
@pytest.mark.parametrize(
    "headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": "Basic invalid"}]
)
def test_private_routes_reject_missing_or_wrong_credentials(client, path, headers, monkeypatch):
    def fail(_):
        pytest.fail("Unauthenticated requests must not reach protected operations")

    monkeypatch.setattr("app.main.check_database", fail)
    monkeypatch.setattr("app.main.collect_metrics", fail)
    response = client.get(path, headers=headers)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_valid_key(client):
    assert client.get("/api/v1/auth/check", headers=auth()).json() == {"status": "authenticated"}


def test_database_readiness(client, monkeypatch):
    monkeypatch.setattr("app.main.check_database", lambda _: None)
    response = client.get("/health/ready", headers=auth())
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_database_failure_does_not_expose_secrets(client, monkeypatch, caplog):
    def fail(_):
        raise psycopg.OperationalError("internal database password=" + PASSWORD)

    monkeypatch.setattr("app.main.check_database", fail)
    with caplog.at_level(logging.WARNING):
        response = client.get("/health/ready", headers=auth())
    assert response.status_code == 503
    assert PASSWORD not in response.text + caplog.text
    assert KEY not in response.text + caplog.text
    assert "database_check_failed" in caplog.text


def test_real_metrics_have_units_scope_and_timestamp(client):
    response = client.get("/api/v1/server/metrics", headers=auth())
    assert response.status_code == 200
    data = response.json()
    assert data["scope"] == "runtime"
    assert data["observed_at"].endswith(("Z", "+00:00"))
    assert 0 <= data["cpu_percent"] <= 100
    for category in ("memory", "disk"):
        capacity = data[category]
        assert capacity["total_bytes"] > 0
        assert 0 <= capacity["available_bytes"] <= capacity["total_bytes"]
        assert 0 <= capacity["used_percent"] <= 100


def test_metrics_failure_is_explicit(client, monkeypatch):
    def fail(_):
        raise PermissionError("private path details")

    monkeypatch.setattr("app.main.collect_metrics", fail)
    response = client.get("/api/v1/server/metrics", headers=auth())
    assert response.status_code == 503
    assert "private path" not in response.text


@pytest.mark.parametrize("secret", ["", "short", "CHANGE_ME_GENERATE_A_RANDOM_SECRET", " " * 64])
def test_weak_config_rejected_without_leaking_input(secret):
    with pytest.raises(ValidationError) as error:
        Settings(nexora_api_key=secret, postgres_password=PASSWORD)
    assert "input_value=" not in str(error.value)


def test_host_mode_requires_real_sources(settings, monkeypatch, tmp_path):
    monkeypatch.setattr("app.main.platform.system", lambda: "Linux")
    settings.nexora_metrics_scope = "host"
    settings.nexora_procfs_path = str(tmp_path)
    with pytest.raises(RuntimeError, match="sources"):
        create_app(settings)


def test_no_public_interactive_api_schema(client):
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404
