-- Rollback of 0002: removes every automation, run and notification. Back up first.
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS automation_runs;
DROP TABLE IF EXISTS automations;
