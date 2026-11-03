-- Scheduled automations (disk check), their runs and the notifications they raise.
CREATE TABLE automations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
    kind text NOT NULL CHECK (kind IN ('disk_check')),
    threshold_percent numeric(5, 2) NOT NULL CHECK (threshold_percent > 0 AND threshold_percent < 100),
    interval_minutes integer NOT NULL
        CHECK (interval_minutes IN (15, 30, 60, 120, 180, 360, 720, 1440)),
    timezone text NOT NULL CHECK (char_length(timezone) BETWEEN 1 AND 64),
    enabled boolean NOT NULL DEFAULT true,
    -- Next slot to run; NULL while suspended. Only advanced in the transaction
    -- that records the run, so a crash replays the slot instead of losing it.
    next_run_at timestamptz,
    -- Anti-repeat state: one alert per crossing, one failure notice per outage.
    alert_active boolean NOT NULL DEFAULT false,
    failing boolean NOT NULL DEFAULT false,
    last_run_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (enabled = (next_run_at IS NOT NULL))
);
CREATE INDEX automations_due_idx ON automations (next_run_at) WHERE enabled;

CREATE TABLE automation_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    automation_id uuid NOT NULL REFERENCES automations (id) ON DELETE CASCADE,
    trigger text NOT NULL CHECK (trigger IN ('schedule', 'manual')),
    scheduled_for timestamptz CHECK ((trigger = 'schedule') = (scheduled_for IS NOT NULL)),
    missed_slots integer NOT NULL DEFAULT 0 CHECK (missed_slots >= 0),
    started_at timestamptz NOT NULL,
    finished_at timestamptz NOT NULL,
    status text NOT NULL CHECK (status IN ('ok', 'alert', 'failed')),
    measured_percent numeric(5, 2),
    threshold_percent numeric(5, 2) NOT NULL,
    error_code text,
    message text NOT NULL CHECK (char_length(message) <= 500),
    notified boolean NOT NULL DEFAULT false
);
-- A scheduled slot runs at most once, across restarts and concurrent schedulers.
CREATE UNIQUE INDEX automation_runs_one_per_slot
    ON automation_runs (automation_id, scheduled_for) WHERE scheduled_for IS NOT NULL;
CREATE INDEX automation_runs_history_idx ON automation_runs (automation_id, started_at DESC);

CREATE TABLE notifications (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    level text NOT NULL CHECK (level IN ('alert', 'recovery', 'failure')),
    title text NOT NULL CHECK (char_length(title) <= 120),
    body text NOT NULL CHECK (char_length(body) <= 500),
    automation_id uuid REFERENCES automations (id) ON DELETE SET NULL,
    run_id uuid REFERENCES automation_runs (id) ON DELETE SET NULL
);
