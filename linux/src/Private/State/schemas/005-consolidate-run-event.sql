-- @repofabric:disable-foreign-keys
-- @repofabric:legacy-alter-table
--
-- Migration 005: Reconcile run_event Wave 1/Wave 2 hybrid columns.
--
-- The original 001-initial schema defined Wave 1 columns on run_event:
--     from_version, to_version, error_message, duration_ms, event_at
-- 002-wave2-additions.sql then layered Wave 2 columns:
--     message, detail_json, created_utc
-- Working code (Write-RfRunEvent.ps1) writes only the Wave 2 columns
-- plus event_at (because it was declared NOT NULL without a default).
--
-- No reader queries the Wave 1 fields anymore. This migration rebuilds
-- run_event with only the Wave 2 surface so future inserts don't need
-- to redundantly populate event_at (== created_utc).
--
-- Per 003-consolidate-run.sql's notes, we toggle foreign_keys=OFF and
-- legacy_alter_table=ON for the rebuild so SQLite doesn't dangle the
-- run_event.run_id FK target onto the temp `_run_event_old` shell.

ALTER TABLE run_event RENAME TO _run_event_old;

CREATE TABLE run_event (
    event_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER NOT NULL REFERENCES run(run_id),
    subscription_id INTEGER          REFERENCES subscription(subscription_id),
    phase           TEXT    NOT NULL,
    package_id      TEXT,
    outcome         TEXT    NOT NULL,
    message         TEXT    NOT NULL DEFAULT '',
    detail_json     TEXT,
    created_utc     TEXT    NOT NULL
);

INSERT INTO run_event (event_id, run_id, subscription_id, phase, package_id,
                       outcome, message, detail_json, created_utc)
SELECT event_id, run_id, subscription_id, phase, package_id,
       outcome,
       COALESCE(message, ''),
       detail_json,
       COALESCE(created_utc, event_at)
  FROM _run_event_old;

DROP TABLE _run_event_old;

CREATE INDEX IF NOT EXISTS idx_run_event_run          ON run_event (run_id);
CREATE INDEX IF NOT EXISTS idx_run_event_subscription ON run_event (subscription_id);
CREATE INDEX IF NOT EXISTS idx_run_event_created      ON run_event (created_utc);

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '5');
