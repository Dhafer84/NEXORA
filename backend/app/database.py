import psycopg
from psycopg.rows import dict_row

from app.config import Settings


def connect(settings: Settings, *, read_only: bool = False) -> psycopg.Connection:
    # Short-lived autocommit connections; writes use explicit transactions.
    options = "-c statement_timeout=5000 -c lock_timeout=3000"
    if read_only:
        options += " -c default_transaction_read_only=on"
    return psycopg.connect(
        host=settings.postgres_host,
        port=settings.postgres_port,
        user=settings.postgres_user,
        password=settings.postgres_password.get_secret_value(),
        dbname=settings.postgres_db,
        connect_timeout=3,
        options=options,
        autocommit=True,
        row_factory=dict_row,
    )


def check_database(settings: Settings) -> None:
    with connect(settings, read_only=True) as connection:
        row = connection.execute("SELECT 1 AS ok").fetchone()
        if row != {"ok": 1}:
            raise psycopg.OperationalError("Database check failed")
