"""Versioned SQL migrations.

Usage: python -m app.migrate status | up | down TARGET_VERSION
Each NNNN_name.up.sql has a NNNN_name.down.sql rollback. Back up before running.
"""

import hashlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import psycopg

from app.config import Settings
from app.database import connect

MIGRATIONS = Path(__file__).parent / "migrations"
LOCK_ID = 0x4E45584F  # Serialises concurrent migration runs.
NAME = re.compile(r"^(\d{4})_([a-z0-9_]+)\.up\.sql$")


@dataclass(frozen=True)
class Migration:
    version: int
    name: str
    up: str
    down: str

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.up.encode()).hexdigest()


def available() -> list[Migration]:
    found = []
    for path in sorted(MIGRATIONS.glob("*.up.sql")):
        match = NAME.match(path.name)
        if not match:
            raise RuntimeError(f"Nom de migration invalide : {path.name}")
        down = path.with_name(path.name.replace(".up.sql", ".down.sql"))
        found.append(Migration(int(match[1]), match[2], path.read_text(), down.read_text()))
    versions = [migration.version for migration in found]
    if versions != list(range(1, len(found) + 1)):
        raise RuntimeError("Les versions de migration doivent se suivre à partir de 0001")
    return found


def _ensure_table(connection: psycopg.Connection) -> None:
    connection.execute(
        """CREATE TABLE IF NOT EXISTS schema_migrations (
            version integer PRIMARY KEY,
            name text NOT NULL,
            checksum text NOT NULL,
            applied_at timestamptz NOT NULL DEFAULT now())"""
    )


def applied(connection: psycopg.Connection) -> dict[int, str]:
    _ensure_table(connection)
    rows = connection.execute("SELECT version, checksum FROM schema_migrations").fetchall()
    return {row["version"]: row["checksum"] for row in rows}


def _verify(done: dict[int, str], migrations: list[Migration]) -> None:
    known = {migration.version: migration for migration in migrations}
    for version, checksum in done.items():
        if version not in known or known[version].checksum != checksum:
            raise RuntimeError(f"Migration {version:04d} appliquée différente du code")


def current_version(settings: Settings) -> int:
    with connect(settings) as connection:
        return max(applied(connection), default=0)


def upgrade(settings: Settings) -> list[int]:
    migrations = available()
    done_now = []
    with connect(settings) as connection:
        with connection.transaction():
            connection.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_ID,))
            done = applied(connection)
            _verify(done, migrations)
            for migration in migrations:
                if migration.version in done:
                    continue
                connection.execute(migration.up)
                connection.execute(
                    "INSERT INTO schema_migrations (version, name, checksum) VALUES (%s, %s, %s)",
                    (migration.version, migration.name, migration.checksum),
                )
                done_now.append(migration.version)
    return done_now


def downgrade(settings: Settings, target: int) -> list[int]:
    migrations = available()
    reverted = []
    with connect(settings) as connection:
        with connection.transaction():
            connection.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_ID,))
            done = applied(connection)
            _verify(done, migrations)
            for migration in reversed(migrations):
                if migration.version <= target or migration.version not in done:
                    continue
                connection.execute(migration.down)
                connection.execute(
                    "DELETE FROM schema_migrations WHERE version = %s", (migration.version,)
                )
                reverted.append(migration.version)
    return reverted


def main(argv: list[str]) -> int:
    settings = Settings()
    command = argv[0] if argv else "status"
    try:
        if command == "status":
            latest = available()[-1].version if available() else 0
            print(f"Version appliquée : {current_version(settings)} ; disponible : {latest}")
        elif command == "up":
            versions = upgrade(settings)
            print("Migrations appliquées : " + (", ".join(map(str, versions)) or "aucune"))
        elif command == "down" and len(argv) == 2 and argv[1].isdigit():
            versions = downgrade(settings, int(argv[1]))
            print("Migrations annulées : " + (", ".join(map(str, versions)) or "aucune"))
        else:
            print(__doc__)
            return 2
    except psycopg.Error as error:
        # Only the error class and SQLSTATE: messages may contain connection details.
        state = getattr(error, "sqlstate", None) or "-"
        print(f"Échec de migration : {type(error).__name__} ({state}).", file=sys.stderr)
        return 1
    except RuntimeError as error:
        print(f"Échec de migration : {error}.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
