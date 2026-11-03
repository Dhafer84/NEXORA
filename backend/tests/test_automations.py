import threading
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import psycopg
import pytest
from app import automations
from app.automations import NewAutomation, due_slots, next_slot, run_due
from app.database import connect
from app.main import create_app
from app.metrics import Capacity, ServerMetrics
from conftest import auth, database_settings
from fastapi.testclient import TestClient

PARIS = ZoneInfo("Europe/Paris")
UTC = timezone.utc
T0 = datetime(2026, 11, 3, 9, 20, tzinfo=UTC)  # 10:20 in Paris


def metrics(disk_percent: float) -> ServerMetrics:
    capacity = Capacity(total_bytes=100, used_bytes=50, available_bytes=50, used_percent=50)
    disk = capacity.model_copy(update={"used_percent": disk_percent})
    return ServerMetrics(observed_at=T0, scope="runtime", cpu_percent=1, memory=capacity, disk=disk)


class Probe:
    """Simulated disk readings: no disk is filled to trigger an alert."""

    def __init__(self, *values):
        self.values = list(values)
        self.calls = 0

    def __call__(self) -> ServerMetrics:
        self.calls += 1
        value = self.values.pop(0) if len(self.values) > 1 else self.values[0]
        if isinstance(value, BaseException):
            raise value
        return metrics(value)


class Clock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


def create(settings, now=T0, **values):
    body = {"threshold_percent": 80, "timezone": "Europe/Paris"} | values
    with connect(settings) as connection:
        return automations.create(connection, NewAutomation(**body), now)


def history(settings, automation_id):
    with connect(settings) as connection:
        return automations.runs(connection, automation_id, 200)


def notices(settings):
    with connect(settings) as connection:
        return automations.notifications(connection, 0, 100).items


@pytest.fixture
def client(db_settings):
    app = create_app(db_settings)
    app.state.measure = Probe(42.5)
    with TestClient(app) as client:
        yield client


# ----- Slots ------------------------------------------------------------------


def test_hourly_slots_follow_local_hours():
    assert next_slot(T0, 60, PARIS) == datetime(2026, 11, 3, 10, 0, tzinfo=UTC)  # 11:00 Paris
    # Strictly after: a run exactly on a slot schedules the following one.
    assert next_slot(datetime(2026, 11, 3, 10, tzinfo=UTC), 60, PARIS).hour == 11
    daily = next_slot(T0, 1440, PARIS)
    assert daily.astimezone(PARIS).hour == 0 and daily.astimezone(PARIS).day == 4
    quarter = next_slot(T0, 15, ZoneInfo("Asia/Kolkata"))  # UTC+05:30
    assert quarter.astimezone(ZoneInfo("Asia/Kolkata")).minute % 15 == 0


def test_daylight_saving_changes_neither_skip_nor_double_hours():
    # 29 March 2026: 02:00 does not exist in Paris; 25 October: 02:00 happens twice.
    spring = due_slots(
        datetime(2026, 3, 28, 23, tzinfo=UTC), datetime(2026, 3, 29, 3, tzinfo=UTC), 60, PARIS
    )
    autumn = due_slots(
        datetime(2026, 10, 24, 22, tzinfo=UTC), datetime(2026, 10, 25, 3, tzinfo=UTC), 60, PARIS
    )
    for slots in (spring, autumn):
        gaps = {b - a for a, b in zip(slots, slots[1:], strict=False)}
        assert gaps == {timedelta(hours=1)}
    assert [s.astimezone(PARIS).hour for s in autumn][:5] == [0, 1, 2, 2, 3]


# ----- Scheduling -------------------------------------------------------------


def test_slot_runs_once_at_its_time(db_settings):
    task = create(db_settings)
    probe, clock = Probe(40), Clock(T0)
    assert run_due(db_settings, probe, clock) == []  # 10:20: nothing due before 11:00
    clock.now = task.next_run_at.astimezone(UTC) + timedelta(seconds=5)
    [run] = run_due(db_settings, probe, clock)
    assert run.trigger == "schedule" and run.scheduled_for == task.next_run_at
    assert run.status == "ok" and run.measured_percent == 40 and run.missed_slots == 0
    assert run_due(db_settings, probe, clock) == []  # Same slot, second tick
    with connect(db_settings) as connection:
        after = automations.get(connection, task.id)
    assert after.next_run_at == task.next_run_at + timedelta(hours=1)
    assert after.last_run.id == run.id
    assert probe.calls == 1


def test_concurrent_schedulers_run_a_slot_once(db_settings):
    create(db_settings)
    clock = Clock(T0 + timedelta(hours=1))
    probe = Probe(40)
    barrier = threading.Barrier(4)
    results = []

    def worker():
        barrier.wait()
        results.append(run_due(db_settings, probe, clock))

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sum(len(runs) for runs in results) == 1
    assert probe.calls == 1


def test_restart_catches_up_latest_slot_only(db_settings):
    task = create(db_settings)
    # Backend stopped from 10:20 to 15:30 (Paris): slots 11:00 to 15:00 were due.
    clock = Clock(datetime(2026, 11, 3, 14, 30, tzinfo=UTC))
    [run] = run_due(db_settings, Probe(40), clock)
    assert run.scheduled_for.astimezone(PARIS).hour == 15
    assert run.missed_slots == 4
    with connect(db_settings) as connection:
        assert automations.get(connection, task.id).next_run_at.astimezone(PARIS).hour == 16
    assert run_due(db_settings, Probe(40), clock) == []


class Crash(BaseException):
    """Process killed in the middle of a run."""


def test_interrupted_run_is_replayed_once_after_restart(db_settings):
    task = create(db_settings)
    clock = Clock(T0 + timedelta(hours=1))
    with pytest.raises(Crash):
        run_due(db_settings, Probe(Crash()), clock)
    with connect(db_settings) as connection:
        # Nothing half-written: the slot is still due.
        assert automations.get(connection, task.id).next_run_at == task.next_run_at
    assert history(db_settings, task.id) == []
    [run] = run_due(db_settings, Probe(40), clock)
    assert run.scheduled_for == task.next_run_at
    assert run_due(db_settings, Probe(40), clock) == []


def test_database_refuses_a_second_run_of_a_slot(db_settings):
    task = create(db_settings)
    clock = Clock(T0 + timedelta(hours=1))
    [run] = run_due(db_settings, Probe(40), clock)
    with connect(db_settings) as connection, pytest.raises(psycopg.errors.UniqueViolation):
        connection.execute(
            """INSERT INTO automation_runs (automation_id, trigger, scheduled_for, started_at,
               finished_at, status, threshold_percent, message)
               VALUES (%s, 'schedule', %s, now(), now(), 'ok', 80, 'double')""",
            (task.id, run.scheduled_for),
        )


def test_suspended_task_does_not_run_and_resumes_without_replay(db_settings):
    task = create(db_settings)
    with connect(db_settings) as connection:
        paused = automations.update(
            connection, task.id, automations.AutomationChanges(enabled=False), T0
        )
    assert paused.enabled is False and paused.next_run_at is None
    later = T0 + timedelta(hours=5)
    assert run_due(db_settings, Probe(40), Clock(later)) == []
    with connect(db_settings) as connection:
        resumed = automations.update(
            connection, task.id, automations.AutomationChanges(enabled=True), later
        )
    assert resumed.next_run_at > later
    assert run_due(db_settings, Probe(40), Clock(later)) == []
    assert history(db_settings, task.id) == []


# ----- Alerts -----------------------------------------------------------------


def test_one_alert_per_crossing_then_recovery(db_settings):
    task = create(db_settings, threshold_percent=80)
    readings = [70, 85, 90, 88, 60, 81]
    clock = Clock(T0)
    statuses = []
    for value in readings:
        clock.now = clock.now + timedelta(hours=1)
        [run] = run_due(db_settings, Probe(value), clock)
        statuses.append((run.status, run.notified))
    assert statuses == [
        ("ok", False),
        ("alert", True),
        ("alert", False),
        ("alert", False),
        ("ok", True),
        ("alert", True),
    ]
    assert [n.level for n in notices(db_settings)] == ["alert", "recovery", "alert"]
    first = notices(db_settings)[0]
    assert first.title == "Disque du serveur à 85,0 %" and first.automation_id == task.id


def test_failures_are_recorded_and_notified_once(db_settings):
    task = create(db_settings)
    clock = Clock(T0)
    results = []
    for value in [OSError("disk"), OSError("disk"), 40]:
        clock.now += timedelta(hours=1)
        [run] = run_due(db_settings, Probe(value), clock)
        results.append((run.status, run.error_code, run.measured_percent, run.notified))
    assert results == [
        ("failed", "metrics_unavailable", None, True),
        ("failed", "metrics_unavailable", None, False),
        ("ok", None, 40, False),
    ]
    assert [n.level for n in notices(db_settings)] == ["failure"]
    assert all(run.finished_at >= run.started_at for run in history(db_settings, task.id))


def test_phone_reading_between_two_commits_misses_no_alert(db_settings):
    # Two alerts are raised by concurrent transactions. The first one numbered
    # commits last; the phone reads between the two commits, keeps the highest id
    # it saw, then reads again from there. It must end up with both alerts.
    first, second = create(db_settings, name="Premier"), create(db_settings, name="Second")
    numbered = {name: threading.Event() for name in ("first", "second")}
    commit = {name: threading.Event() for name in ("first", "second")}
    errors = []

    def alert(name, task):
        try:
            with connect(db_settings) as connection, connection.transaction():
                automations.run_now(connection, task.id, db_settings, Probe(95))
                numbered[name].set()
                assert commit[name].wait(10)
        except BaseException as error:  # noqa: BLE001 - reported by the main thread.
            errors.append(error)

    threads = {
        name: threading.Thread(target=alert, args=(name, task))
        for name, task in (("first", first), ("second", second))
    }
    seen, cursor = [], 0

    def read():
        nonlocal cursor
        with connect(db_settings) as connection:
            page = automations.notifications(connection, cursor, 100)
        seen.extend(item.id for item in page.items)
        cursor = max([cursor, *seen])
        assert page.latest_id == cursor

    try:
        threads["first"].start()
        assert numbered["first"].wait(5)
        threads["second"].start()
        # Numbered only once the first is committed: it cannot commit before it.
        second_numbered_early = numbered["second"].wait(1)
        commit["second"].set()
        threads["second"].join(1)
        read()  # Between the two commits.
    finally:
        commit["first"].set()
        commit["second"].set()
        for thread in threads.values():
            thread.join(10)
    assert not errors
    read()
    everything = notices(db_settings)
    assert len(everything) == 2
    assert seen == [notice.id for notice in everything]
    assert [notice.body.split(" »")[0] for notice in everything] == ["« Premier", "« Second"]
    assert not second_numbered_early


def test_threshold_change_rearms_the_alert(db_settings):
    task = create(db_settings, threshold_percent=80)
    clock = Clock(T0 + timedelta(hours=1))
    run_due(db_settings, Probe(85), clock)
    with connect(db_settings) as connection:
        automations.update(
            connection, task.id, automations.AutomationChanges(threshold_percent=84), T0
        )
        run = automations.run_now(connection, task.id, db_settings, Probe(85), clock)
    assert run.status == "alert" and run.notified
    assert len(notices(db_settings)) == 2


def test_scheduled_run_rechecks_permissions(db_settings):
    create(db_settings)
    limited = database_settings(nexora_permissions="automation:read,automation:write")
    [run] = run_due(limited, Probe(99), Clock(T0 + timedelta(hours=1)))
    assert (run.status, run.error_code, run.measured_percent) == (
        "failed",
        "permission_denied",
        None,
    )


# ----- API --------------------------------------------------------------------


def test_full_api_journey(client):
    body = {"threshold_percent": 40, "interval_minutes": 60, "timezone": "Europe/Paris"}
    created = client.post("/api/v1/automations", json=body, headers=auth())
    assert created.status_code == 201
    task = created.json()
    assert task["name"] == "Vérification du disque" and task["enabled"] is True
    assert task["next_run_at"].endswith(("+01:00", "+02:00"))  # Paris offset, not UTC
    assert task["last_run"] is None

    run = client.post(f"/api/v1/automations/{task['id']}/run", headers=auth())
    assert run.status_code == 200
    assert run.json() | {"id": None, "started_at": None, "finished_at": None} == {
        "id": None,
        "automation_id": task["id"],
        "trigger": "manual",
        "scheduled_for": None,
        "missed_slots": 0,
        "started_at": None,
        "finished_at": None,
        "status": "alert",
        "measured_percent": 42.5,
        "threshold_percent": 40.0,
        "error_code": None,
        "message": "Disque utilisé à 42,5 % (seuil 40 %)",
        "notified": True,
    }
    # A manual run neither consumes nor moves the next slot.
    detail = client.get(f"/api/v1/automations/{task['id']}", headers=auth()).json()
    assert detail["next_run_at"] == task["next_run_at"] and detail["alert_active"] is True

    page = client.get("/api/v1/notifications", headers=auth()).json()
    assert [n["level"] for n in page["items"]] == ["alert"]
    latest = page["latest_id"]
    empty = client.get(f"/api/v1/notifications?after_id={latest}", headers=auth()).json()
    assert empty == {"items": [], "latest_id": latest}

    changed = client.patch(
        f"/api/v1/automations/{task['id']}",
        json={"threshold_percent": 90, "interval_minutes": 30, "enabled": False},
        headers=auth(),
    ).json()
    assert changed["threshold_percent"] == 90 and changed["interval_minutes"] == 30
    assert changed["enabled"] is False and changed["next_run_at"] is None
    assert changed["alert_active"] is False

    runs = client.get(f"/api/v1/automations/{task['id']}/runs", headers=auth()).json()
    assert len(runs) == 1
    assert client.get("/api/v1/automations", headers=auth()).json()[0]["id"] == task["id"]
    assert client.delete(f"/api/v1/automations/{task['id']}", headers=auth()).status_code == 204
    missing = client.get(f"/api/v1/automations/{task['id']}", headers=auth())
    assert missing.status_code == 404
    assert missing.json()["detail"]["code"] == "automation_not_found"
    # Notifications outlive the task they came from.
    assert (
        client.get("/api/v1/notifications", headers=auth()).json()["items"][0]["automation_id"]
        is None
    )


@pytest.mark.parametrize(
    "body",
    [
        {"threshold_percent": 0, "timezone": "Europe/Paris"},
        {"threshold_percent": 100, "timezone": "Europe/Paris"},
        {"threshold_percent": 80, "timezone": "Mars/Olympus"},
        {"threshold_percent": 80, "timezone": "../../etc/passwd"},
        {"threshold_percent": 80, "timezone": "Europe/Paris", "interval_minutes": 45},
        {"threshold_percent": 80, "timezone": "Europe/Paris", "command": "rm -rf /"},
        {"timezone": "Europe/Paris"},
    ],
)
def test_invalid_definitions_rejected(client, body):
    assert client.post("/api/v1/automations", json=body, headers=auth()).status_code == 422


def test_null_change_rejected(client):
    body = {"threshold_percent": 80, "timezone": "Europe/Paris"}
    task = client.post("/api/v1/automations", json=body, headers=auth()).json()
    response = client.patch(
        f"/api/v1/automations/{task['id']}", json={"enabled": None}, headers=auth()
    )
    assert response.status_code == 422


def test_limit_on_number_of_automations(client):
    body = {"threshold_percent": 80, "timezone": "Europe/Paris"}
    for _ in range(automations.MAX_AUTOMATIONS):
        assert client.post("/api/v1/automations", json=body, headers=auth()).status_code == 201
    refused = client.post("/api/v1/automations", json=body, headers=auth())
    assert refused.status_code == 409 and refused.json()["detail"]["code"] == "automation_limit"


@pytest.mark.parametrize(
    ("permissions", "method", "path", "missing"),
    [
        ("server:read,automation:write", "get", "/api/v1/automations", "automation:read"),
        ("server:read,automation:read", "post", "/api/v1/automations", "automation:write"),
        ("automation:read,automation:write", "post", "/api/v1/automations", "server:read"),
        ("automation:read", "get", "/api/v1/notifications", "notifications:read"),
    ],
)
def test_routes_require_permissions(db_settings, permissions, method, path, missing):
    settings = db_settings.model_copy(update={"nexora_permissions": permissions})
    with TestClient(create_app(settings)) as client:
        body = {"threshold_percent": 80, "timezone": "Europe/Paris"}
        kwargs = {"json": body} if method == "post" else {}
        response = getattr(client, method)(path, headers=auth(), **kwargs)
    assert response.status_code == 403
    assert response.json()["detail"]["message"] == f"Permission manquante : {missing}"


def test_manual_run_requires_server_read(db_settings):
    task = create(db_settings)
    settings = db_settings.model_copy(
        update={"nexora_permissions": "automation:read,automation:write"}
    )
    with TestClient(create_app(settings)) as client:
        response = client.post(f"/api/v1/automations/{task.id}/run", headers=auth())
    assert response.status_code == 403
    assert history(db_settings, task.id) == []


def test_routes_require_the_key(client):
    assert client.get("/api/v1/automations").status_code == 401
    assert (
        client.get("/api/v1/notifications", headers={"Authorization": "Bearer x"}).status_code
        == 401
    )


def test_checks_run_without_ai_provider(db_settings, tmp_path):
    # Real provider selected but its key is missing: conversations fail, checks do not.
    settings = db_settings.model_copy(
        update={
            "nexora_ai_provider": "openai_compatible",
            "nexora_ai_api_key_file": str(tmp_path / "absent"),
            "nexora_ai_base_url": "http://127.0.0.1:9",
        }
    )
    app = create_app(settings)
    app.state.measure = Probe(91)
    with TestClient(app) as client:
        assert client.get("/api/v1/ai/status", headers=auth()).json()["configured"] is False
        body = {"threshold_percent": 80, "timezone": "Europe/Paris"}
        task = client.post("/api/v1/automations", json=body, headers=auth()).json()
        run = client.post(f"/api/v1/automations/{task['id']}/run", headers=auth()).json()
    assert run["status"] == "alert" and run["notified"] is True
    [run] = run_due(settings, Probe(91), Clock(T0 + timedelta(days=2)))
    assert run.status == "alert" and run.notified is False


def test_background_scheduler_starts_with_the_app_and_stops(db_settings):
    task = create(db_settings, now=datetime.now(UTC) - timedelta(hours=2))
    settings = db_settings.model_copy(
        update={"nexora_scheduler_enabled": True, "nexora_scheduler_poll_seconds": 1}
    )
    app = create_app(settings)
    app.state.measure = Probe(30)
    with TestClient(app):
        deadline = time.monotonic() + 10
        while not history(db_settings, task.id) and time.monotonic() < deadline:
            time.sleep(0.2)
    [run] = history(db_settings, task.id)
    assert run.trigger == "schedule" and run.missed_slots >= 1
    threads = [t.name for t in threading.enumerate()]
    assert "nexora-scheduler" not in threads


def test_scheduler_survives_database_outage(db_settings, caplog):
    settings = db_settings.model_copy(update={"postgres_port": 1})
    scheduler = automations.Scheduler(settings, Probe(30))
    scheduler.tick()  # Logged, not raised; the slot stays due.
    assert "scheduler_database_error type=OperationalError" in caplog.text
    assert db_settings.postgres_password.get_secret_value() not in caplog.text
