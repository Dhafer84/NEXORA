"""Scheduled automations: persistent definitions, runs, alerts and notifications.

Only the disk check exists for now. Runs never depend on the AI provider.

Slot rules:
- Slots are local wall times, in the task's time zone, at multiples of the interval
  since local midnight (hourly = every hh:00). A wall time skipped by a DST change
  has no slot; a repeated one has two.
- ``next_run_at`` is advanced in the same transaction that records the run, and a
  unique index allows one run per (task, slot): a crash replays the slot at most
  once, a restart or a second scheduler never runs it twice.
- After downtime, only the latest due slot runs; older ones are counted in
  ``missed_slots`` instead of being replayed one after another.

Anti-repeat rule: one alert when the threshold is reached, none while the disk
stays at or above it, one "back to normal" notice when it drops below. The same
for failures: one notice when measuring starts failing. Changing the threshold
re-arms the alert.
"""

import logging
import threading
from collections.abc import Callable
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from typing import Any, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import psycopg
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.config import Settings
from app.database import connect
from app.metrics import ServerMetrics

logger = logging.getLogger("nexora")

INTERVALS = (15, 30, 60, 120, 180, 360, 720, 1440)
MAX_AUTOMATIONS = 20
MAX_CATCH_UP_DAYS = 400
# pg_advisory_xact_lock key serializing notification numbering (arbitrary, app-wide).
NOTIFICATION_LOCK = 0x4E58_4E4F
Interval = Literal[15, 30, 60, 120, 180, 360, 720, 1440]
Measure = Callable[[], ServerMetrics]
Clock = Callable[[], datetime]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError("Fuseau horaire inconnu") from None


# ----- Slots ------------------------------------------------------------------


def _day_slots(day: date, interval: int, tz: ZoneInfo) -> list[datetime]:
    slots = set()
    for minute in range(0, 1440, interval):
        for fold in (0, 1):
            wall = datetime.combine(day, time(minute // 60, minute % 60, fold=fold), tzinfo=tz)
            instant = wall.astimezone(timezone.utc)
            # Wall times that do not exist (spring forward) do not round-trip.
            if instant.astimezone(tz).replace(tzinfo=None) == wall.replace(tzinfo=None):
                slots.add(instant)
    return sorted(slots)


def next_slot(after: datetime, interval: int, tz: ZoneInfo) -> datetime:
    """First slot strictly after ``after``."""
    day = after.astimezone(tz).date() - timedelta(days=1)
    for offset in range(4):
        for slot in _day_slots(day + timedelta(days=offset), interval, tz):
            if slot > after:
                return slot
    raise RuntimeError("Aucun créneau trouvé")


def due_slots(first: datetime, now: datetime, interval: int, tz: ZoneInfo) -> list[datetime]:
    """Slots in [first, now], ``first`` being a stored next_run_at."""
    start = first.astimezone(tz).date() - timedelta(days=1)
    end = now.astimezone(tz).date()
    if (end - start).days > MAX_CATCH_UP_DAYS:
        start = end - timedelta(days=MAX_CATCH_UP_DAYS)
    slots: list[datetime] = []
    day = start
    while day <= end:
        slots.extend(s for s in _day_slots(day, interval, tz) if first <= s <= now)
        day += timedelta(days=1)
    return slots or [first]


# ----- Views and requests -----------------------------------------------------


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RunView(BaseModel):
    id: UUID
    automation_id: UUID
    trigger: Literal["schedule", "manual"]
    scheduled_for: datetime | None
    missed_slots: int
    started_at: datetime
    finished_at: datetime
    status: Literal["ok", "alert", "failed"]
    measured_percent: float | None
    threshold_percent: float
    error_code: str | None
    message: str
    notified: bool


class AutomationView(BaseModel):
    id: UUID
    name: str
    kind: Literal["disk_check"]
    threshold_percent: float
    interval_minutes: int
    timezone: str
    enabled: bool
    next_run_at: datetime | None
    alert_active: bool
    failing: bool
    last_run: RunView | None
    created_at: datetime
    updated_at: datetime


class NotificationView(BaseModel):
    id: int
    created_at: datetime
    level: Literal["alert", "recovery", "failure"]
    title: str
    body: str
    automation_id: UUID | None
    run_id: UUID | None


class NotificationPage(BaseModel):
    items: list[NotificationView]
    latest_id: int


def _check_zone(value: str | None) -> str | None:
    if value is not None:
        zone(value)
    return value


class NewAutomation(Strict):
    name: str = Field(default="Vérification du disque", min_length=1, max_length=80)
    kind: Literal["disk_check"] = "disk_check"
    threshold_percent: float = Field(gt=0, lt=100)
    interval_minutes: Interval = 60
    timezone: str = Field(min_length=1, max_length=64)
    enabled: bool = True

    _zone = field_validator("timezone")(_check_zone)


class AutomationChanges(Strict):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    threshold_percent: float | None = Field(default=None, gt=0, lt=100)
    interval_minutes: Interval | None = None
    timezone: str | None = Field(default=None, min_length=1, max_length=64)
    enabled: bool | None = None

    _zone = field_validator("timezone")(_check_zone)


class AutomationError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


NOT_FOUND = AutomationError(404, "automation_not_found", "Automatisation introuvable")


def _float(value: Decimal | None) -> float | None:
    return None if value is None else float(value)


def _run(row: dict[str, Any]) -> RunView:
    values = {key: row[key] for key in RunView.model_fields}
    values["measured_percent"] = _float(row["measured_percent"])
    values["threshold_percent"] = float(row["threshold_percent"])
    return RunView(**values)


def _automation(connection: psycopg.Connection, row: dict[str, Any]) -> AutomationView:
    last = connection.execute(
        "SELECT * FROM automation_runs WHERE automation_id = %s ORDER BY started_at DESC LIMIT 1",
        (row["id"],),
    ).fetchone()
    tz = zone(row["timezone"])
    values = {key: row[key] for key in AutomationView.model_fields if key != "last_run"}
    values["threshold_percent"] = float(row["threshold_percent"])
    # Shown in the task's own time zone (ISO 8601 with its offset).
    values["next_run_at"] = row["next_run_at"] and row["next_run_at"].astimezone(tz)
    return AutomationView(**values, last_run=_run(last) if last else None)


# ----- Definitions ------------------------------------------------------------


def list_all(connection: psycopg.Connection) -> list[AutomationView]:
    rows = connection.execute("SELECT * FROM automations ORDER BY created_at").fetchall()
    return [_automation(connection, row) for row in rows]


def get(connection: psycopg.Connection, automation_id: UUID) -> AutomationView:
    row = connection.execute("SELECT * FROM automations WHERE id = %s", (automation_id,)).fetchone()
    if row is None:
        raise NOT_FOUND
    return _automation(connection, row)


def create(connection: psycopg.Connection, body: NewAutomation, now: datetime) -> AutomationView:
    next_run = next_slot(now, body.interval_minutes, zone(body.timezone)) if body.enabled else None
    with connection.transaction():
        # Serialises concurrent creations so the limit holds.
        connection.execute("LOCK TABLE automations IN SHARE ROW EXCLUSIVE MODE")
        count = connection.execute("SELECT count(*) AS n FROM automations").fetchone()["n"]
        if count >= MAX_AUTOMATIONS:
            raise AutomationError(
                409, "automation_limit", f"{MAX_AUTOMATIONS} automatisations au maximum"
            )
        row = connection.execute(
            """INSERT INTO automations
               (name, kind, threshold_percent, interval_minutes, timezone, enabled, next_run_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *""",
            (
                body.name,
                body.kind,
                round(body.threshold_percent, 2),
                body.interval_minutes,
                body.timezone,
                body.enabled,
                next_run,
            ),
        ).fetchone()
    return _automation(connection, row)


def update(
    connection: psycopg.Connection, automation_id: UUID, body: AutomationChanges, now: datetime
) -> AutomationView:
    changes = body.model_dump(exclude_unset=True)
    if any(value is None for value in changes.values()):
        raise AutomationError(422, "invalid_changes", "Valeur absente pour un champ modifié")
    with connection.transaction():
        row = connection.execute(
            "SELECT * FROM automations WHERE id = %s FOR UPDATE", (automation_id,)
        ).fetchone()
        if row is None:
            raise NOT_FOUND
        merged = row | changes
        if "threshold_percent" in changes:
            merged["threshold_percent"] = round(changes["threshold_percent"], 2)
            if Decimal(str(merged["threshold_percent"])) != row["threshold_percent"]:
                merged["alert_active"] = False  # New threshold: re-armed.
        schedule_changed = any(
            key in changes and changes[key] != row[key]
            for key in ("interval_minutes", "timezone", "enabled")
        )
        if not merged["enabled"]:
            merged["next_run_at"] = None
        elif schedule_changed or merged["next_run_at"] is None:
            # Recomputed from now: resuming never replays the slots of the pause.
            merged["next_run_at"] = next_slot(
                now, merged["interval_minutes"], zone(merged["timezone"])
            )
        row = connection.execute(
            """UPDATE automations SET name = %s, threshold_percent = %s, interval_minutes = %s,
                   timezone = %s, enabled = %s, next_run_at = %s, alert_active = %s,
                   updated_at = now()
               WHERE id = %s RETURNING *""",
            (
                merged["name"],
                merged["threshold_percent"],
                merged["interval_minutes"],
                merged["timezone"],
                merged["enabled"],
                merged["next_run_at"],
                merged["alert_active"],
                automation_id,
            ),
        ).fetchone()
    return _automation(connection, row)


def delete(connection: psycopg.Connection, automation_id: UUID) -> None:
    deleted = connection.execute(
        "DELETE FROM automations WHERE id = %s RETURNING id", (automation_id,)
    ).fetchone()
    if deleted is None:
        raise NOT_FOUND


def runs(connection: psycopg.Connection, automation_id: UUID, limit: int) -> list[RunView]:
    get(connection, automation_id)
    rows = connection.execute(
        """SELECT * FROM automation_runs WHERE automation_id = %s
           ORDER BY started_at DESC LIMIT %s""",
        (automation_id, limit),
    ).fetchall()
    return [_run(row) for row in rows]


def notifications(connection: psycopg.Connection, after_id: int, limit: int) -> NotificationPage:
    # One statement, one snapshot: latest_id never exceeds what the page could show.
    rows = connection.execute(
        """SELECT n.*, latest.id AS latest_id
           FROM (SELECT coalesce(max(id), 0) AS id FROM notifications) AS latest
           LEFT JOIN LATERAL (
               SELECT * FROM notifications WHERE id > %s ORDER BY id LIMIT %s
           ) AS n ON true
           ORDER BY n.id""",
        (after_id, limit),
    ).fetchall()
    fields = NotificationView.model_fields
    return NotificationPage(
        items=[
            NotificationView(**{key: row[key] for key in fields})
            for row in rows
            if row["id"] is not None
        ],
        latest_id=rows[0]["latest_id"],
    )


# ----- Runs -------------------------------------------------------------------


def _percent(value: float) -> str:
    return f"{value:.1f}".replace(".", ",")


def _threshold(value: float) -> str:
    return f"{value:g}".replace(".", ",")


def _evaluate(
    connection: psycopg.Connection,
    row: dict[str, Any],
    settings: Settings,
    measure: Measure,
    clock: Clock,
    trigger: str,
    scheduled_for: datetime | None,
    missed: int,
) -> RunView:
    """Measures, applies the anti-repeat rule and records everything.

    The caller holds the row lock on the automation inside a transaction.
    """
    started = clock()
    threshold = float(row["threshold_percent"])
    measured: float | None = None
    error_code: str | None = None
    if "server:read" not in settings.permissions:
        error_code = "permission_denied"
    else:
        try:
            measured = round(float(measure().disk.used_percent), 2)
        except Exception as error:  # noqa: BLE001 - any failure is a recorded run.
            logger.warning("automation_measure_failed type=%s", type(error).__name__)
            error_code = "metrics_unavailable"

    alert_active, failing = row["alert_active"], row["failing"]
    notice: tuple[str, str, str] | None = None
    name = row["name"]
    if measured is None:
        status = "failed"
        message = (
            "Permission manquante : server:read"
            if error_code == "permission_denied"
            else "Mesure du disque impossible"
        )
        if not failing:
            notice = ("failure", "Vérification du disque impossible", f"« {name} » : {message}.")
        failing = True
    else:
        failing = False
        text = f"Disque utilisé à {_percent(measured)} % (seuil {_threshold(threshold)} %)"
        if measured >= threshold:
            status, message = "alert", text
            if not alert_active:
                notice = (
                    "alert",
                    f"Disque du serveur à {_percent(measured)} %",
                    f"« {name} » : seuil de {_threshold(threshold)} % atteint. "
                    "Pas d’autre alerte tant que le disque reste au-dessus.",
                )
            alert_active = True
        else:
            status, message = "ok", text
            if alert_active:
                notice = (
                    "recovery",
                    "Disque revenu sous le seuil",
                    f"« {name} » : {_percent(measured)} %, sous le seuil de "
                    f"{_threshold(threshold)} %.",
                )
            alert_active = False

    run = connection.execute(
        """INSERT INTO automation_runs
           (automation_id, trigger, scheduled_for, missed_slots, started_at, finished_at, status,
            measured_percent, threshold_percent, error_code, message, notified)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING *""",
        (
            row["id"],
            trigger,
            scheduled_for,
            missed,
            started,
            clock(),
            status,
            measured,
            threshold,
            error_code,
            message,
            notice is not None,
        ),
    ).fetchone()
    connection.execute(
        "UPDATE automations SET alert_active = %s, failing = %s, last_run_at = %s WHERE id = %s",
        (alert_active, failing, started, row["id"]),
    )
    if notice:
        # Phones read notifications by increasing id and keep the last one seen:
        # ids must become visible in order. The lock is held until commit, so a
        # notification is numbered only once every earlier one is committed or
        # rolled back. Last statement of the transaction: held for its commit only.
        connection.execute("SELECT pg_advisory_xact_lock(%s)", (NOTIFICATION_LOCK,))
        connection.execute(
            """INSERT INTO notifications (level, title, body, automation_id, run_id)
               VALUES (%s, %s, %s, %s, %s)""",
            (*notice, row["id"], run["id"]),
        )
    logger.info(
        "automation_run automation=%s trigger=%s status=%s notified=%s",
        row["id"],
        trigger,
        status,
        notice is not None,
    )
    return _run(run)


def run_now(
    connection: psycopg.Connection,
    automation_id: UUID,
    settings: Settings,
    measure: Measure,
    clock: Clock = utc_now,
) -> RunView:
    """Manual run: does not consume nor move the next scheduled slot."""
    with connection.transaction():
        row = connection.execute(
            "SELECT * FROM automations WHERE id = %s FOR UPDATE", (automation_id,)
        ).fetchone()
        if row is None:
            raise NOT_FOUND
        return _evaluate(connection, row, settings, measure, clock, "manual", None, 0)


def run_due(settings: Settings, measure: Measure, clock: Clock = utc_now) -> list[RunView]:
    """Runs every due slot once. Safe to call concurrently and after a crash."""
    done: list[RunView] = []
    with connect(settings) as connection:
        while True:
            now = clock()
            with connection.transaction():
                row = connection.execute(
                    """SELECT * FROM automations WHERE enabled AND next_run_at <= %s
                       ORDER BY next_run_at LIMIT 1 FOR UPDATE SKIP LOCKED""",
                    (now,),
                ).fetchone()
                if row is None:
                    return done
                tz = zone(row["timezone"])
                slots = due_slots(row["next_run_at"], now, row["interval_minutes"], tz)
                slot = slots[-1]
                connection.execute(
                    "UPDATE automations SET next_run_at = %s WHERE id = %s",
                    (next_slot(now, row["interval_minutes"], tz), row["id"]),
                )
                already = connection.execute(
                    "SELECT 1 FROM automation_runs WHERE automation_id = %s AND scheduled_for = %s",
                    (row["id"], slot),
                ).fetchone()
                if already is None:
                    done.append(
                        _evaluate(
                            connection,
                            row,
                            settings,
                            measure,
                            clock,
                            "schedule",
                            slot,
                            len(slots) - 1,
                        )
                    )


class Scheduler:
    """Background thread polling for due slots. One per backend process."""

    def __init__(self, settings: Settings, measure: Measure) -> None:
        self.settings = settings
        self.measure = measure
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="nexora-scheduler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10)

    def tick(self) -> None:
        try:
            run_due(self.settings, self.measure)
        except psycopg.Error as error:
            # Nothing was recorded: the slot stays due and is retried at the next tick.
            logger.warning("scheduler_database_error type=%s", type(error).__name__)
        except Exception as error:  # noqa: BLE001 - the loop must survive.
            logger.warning("scheduler_error type=%s", type(error).__name__)

    def _loop(self) -> None:
        # First tick at start-up: catches up slots missed while stopped.
        while True:
            self.tick()
            if self._stop.wait(self.settings.nexora_scheduler_poll_seconds):
                return
