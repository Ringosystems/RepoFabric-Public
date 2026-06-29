-- @repofabric:disable-foreign-keys
-- @repofabric:legacy-alter-table
--
-- Migration 003: Consolidate the `run` table on the Wave 2-5 column names.
--
-- The original 001-initial schema defined Wave 1 columns (started_at,
-- completed_at, outcome, subscriptions_total/changed/skipped/failed) that
-- the working code stopped writing once 002-wave2-additions.sql introduced
-- the canonical names (started_utc, ended_utc, status, count_*). Because
-- Wave 1 columns were declared NOT NULL, fresh DBs would fail at the very
-- first INSERT from Start-RfRun.ps1. This migration rebuilds `run` to
-- carry only the Wave 2-5 columns, COALESCEing any legacy data forward.
--
-- The file is prefixed with `-- @repofabric:disable-foreign-keys` so the runner
-- (Invoke-RfStateMigration.ps1) toggles `PRAGMA foreign_keys = OFF`
-- around the apply. Without that, dropping `_run_old` would dangle FK
-- references from run_event, notification, and publication_notes_archive.
--
-- The `-- @repofabric:legacy-alter-table` directive additionally toggles
-- `PRAGMA legacy_alter_table = ON` for the apply. SQLite 3.25+ rewrites
-- foreign-key target names in dependent tables when you `ALTER TABLE ...
-- RENAME`, even with foreign_keys=OFF. Without legacy_alter_table=ON,
-- `run_event.run_id REFERENCES run(run_id)` is silently rewritten to
-- `REFERENCES _run_old(run_id)`, leaving a dangling FK after we drop
-- `_run_old`. The very next `INSERT INTO run_event` then fails with
-- `no such table: main._run_old`.

DROP VIEW IF EXISTS v_run;

ALTER TABLE run RENAME TO _run_old;

CREATE TABLE run (
    run_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    kind            TEXT,
    trigger         TEXT    NOT NULL,
    actor           TEXT,
    status          TEXT,
    started_utc     TEXT,
    ended_utc       TEXT,
    dry_run         INTEGER NOT NULL DEFAULT 0,
    count_succeeded INTEGER NOT NULL DEFAULT 0,
    count_failed    INTEGER NOT NULL DEFAULT 0,
    count_skipped   INTEGER NOT NULL DEFAULT 0,
    count_changed   INTEGER NOT NULL DEFAULT 0,
    summary         TEXT    NOT NULL DEFAULT '',
    notes           TEXT    NOT NULL DEFAULT ''
);

INSERT INTO run (run_id, kind, trigger, actor, status, started_utc, ended_utc,
                 dry_run, count_succeeded, count_failed, count_skipped, count_changed,
                 summary, notes)
SELECT
    run_id,
    kind,
    trigger,
    actor,
    COALESCE(status, outcome),
    COALESCE(started_utc, started_at),
    COALESCE(ended_utc, completed_at),
    COALESCE(dry_run, 0),
    COALESCE(count_succeeded, 0),
    COALESCE(count_failed, 0),
    COALESCE(count_skipped, 0),
    COALESCE(count_changed, 0),
    COALESCE(summary, ''),
    COALESCE(notes, '')
FROM _run_old;

DROP TABLE _run_old;

CREATE INDEX IF NOT EXISTS idx_run_started ON run (started_utc);
CREATE INDEX IF NOT EXISTS idx_run_status  ON run (status);
CREATE INDEX IF NOT EXISTS idx_run_kind    ON run (kind);

CREATE VIEW v_run AS
    SELECT  run_id          AS id,
            kind,
            trigger,
            actor,
            status,
            started_utc,
            ended_utc,
            count_succeeded,
            count_failed,
            count_skipped,
            count_changed,
            summary
    FROM run;

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '3');
INSERT OR REPLACE INTO state_meta (key, value)
    VALUES ('migration_003_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
