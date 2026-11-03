import os

import psycopg
import pytest
from app import migrate
from app.config import Settings
from app.database import connect

# Tests drive the scheduler explicitly (run_due with a fake clock).
os.environ.setdefault("NEXORA_SCHEDULER_ENABLED", "false")

KEY = "a7" * 32
PASSWORD = "b8" * 32


def database_settings(**overrides) -> Settings:
    """Settings for a real PostgreSQL test database (NEXORA_TEST_POSTGRES_* variables)."""
    password = os.environ.get("NEXORA_TEST_POSTGRES_PASSWORD")
    if not password:
        if os.environ.get("NEXORA_REQUIRE_DB_TESTS") == "1":
            pytest.fail("NEXORA_TEST_POSTGRES_PASSWORD requis pour les tests PostgreSQL")
        pytest.skip("PostgreSQL de test non configuré")
    values = {
        "nexora_api_key": KEY,
        "postgres_password": password,
        "postgres_host": os.environ.get("NEXORA_TEST_POSTGRES_HOST", "127.0.0.1"),
        "postgres_port": int(os.environ.get("NEXORA_TEST_POSTGRES_PORT", "5432")),
        "postgres_user": os.environ.get("NEXORA_TEST_POSTGRES_USER", "nexora"),
        "postgres_db": os.environ.get("NEXORA_TEST_POSTGRES_DB", "nexora"),
    }
    values.update(overrides)
    return Settings(**values)


@pytest.fixture
def db_settings():
    """Fresh schema for each test, then every migration."""
    settings = database_settings()
    try:
        with connect(settings) as connection:
            connection.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public")
        migrate.upgrade(settings)
    except psycopg.OperationalError:
        pytest.fail("PostgreSQL de test injoignable")
    return settings


def auth():
    return {"Authorization": f"Bearer {KEY}"}
