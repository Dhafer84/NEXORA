import psycopg

from app.config import Settings


def check_database(settings: Settings) -> None:
    # A short-lived read-only check: no migrations or business tables in this lot.
    with psycopg.connect(
        host=settings.postgres_host,
        port=settings.postgres_port,
        user=settings.postgres_user,
        password=settings.postgres_password.get_secret_value(),
        dbname=settings.postgres_db,
        connect_timeout=3,
        options="-c statement_timeout=3000 -c default_transaction_read_only=on",
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            if cursor.fetchone() != (1,):
                raise psycopg.OperationalError("Database check failed")
