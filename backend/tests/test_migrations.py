import pytest
from app import migrate
from app.database import connect


def tables(settings):
    with connect(settings) as connection:
        rows = connection.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
        ).fetchall()
    return {row["tablename"] for row in rows}


def test_migrations_apply_once_and_roll_back(db_settings):
    expected = {"conversations", "messages", "tool_executions", "approval_requests"}
    assert expected <= tables(db_settings)
    assert migrate.current_version(db_settings) == 1
    assert migrate.upgrade(db_settings) == []
    assert migrate.downgrade(db_settings, 0) == [1]
    assert not expected & tables(db_settings)
    assert migrate.upgrade(db_settings) == [1]


def test_modified_applied_migration_is_detected(db_settings):
    with connect(db_settings) as connection:
        connection.execute("UPDATE schema_migrations SET checksum = repeat('0', 64)")
    with pytest.raises(RuntimeError, match="différente"):
        migrate.upgrade(db_settings)


def test_available_migrations_have_rollbacks():
    migrations = migrate.available()
    assert [m.version for m in migrations] == list(range(1, len(migrations) + 1))
    assert all("DROP TABLE" in m.down for m in migrations)
