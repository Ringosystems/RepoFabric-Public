-- Migration 029: drift_events ledger (RepoFabric 0.8.0 Phase D.5).
--
-- Anyone with write access to the Gitea repos can commit directly,
-- bypassing RepoFabric. Day-to-day this should not happen because
-- operators publish via the admin UI which uses the publisher, but
-- in practice it does: ops poking at YAMLs for emergency hotfixes,
-- accidental push from a script, or a malicious actor with the PAT.
--
-- This table captures every commit on a virtual repo's main branch
-- that was NOT produced by RepoFabric's publisher. A daily cron job
-- walks each repo's recent commits via Gitea's REST API and writes
-- a row for any commit whose author email does not match the
-- configured publisher identity (gitea_author_email in solution.yaml).
--
-- The resolution column is the operator's reaction to the event:
--   * pending       fresh; needs operator attention.
--   * acknowledged  operator saw it and chose to leave it as-is
--                   ('I know about this commit; it stays').
--   * merged        operator captured the commit's manifest YAMLs
--                   into the local catalog (planned for D.6+; not
--                   implemented in this migration).
--   * rejected      operator chose to undo the commit by reverting
--                   it via the publisher (planned for D.6+; not
--                   implemented in this migration).
--
-- The unique index on (repo_id, gitea_commit_sha) makes the detection
-- cmdlet's idempotent: if it runs twice for the same commit, the
-- second INSERT silently ignores (we use INSERT OR IGNORE).

BEGIN;

CREATE TABLE IF NOT EXISTS drift_events (
    drift_event_id            INTEGER PRIMARY KEY AUTOINCREMENT,
    detected_at_utc           TEXT NOT NULL,
    repo_id                   TEXT NOT NULL,

    gitea_commit_sha          TEXT NOT NULL,
    gitea_commit_author       TEXT,
    gitea_commit_author_email TEXT,
    gitea_commit_message      TEXT,
    gitea_commit_date         TEXT,
    files_changed_json        TEXT NOT NULL DEFAULT '[]',

    resolution                TEXT NOT NULL DEFAULT 'pending'
                              CHECK (resolution IN ('pending','merged','rejected','acknowledged')),
    resolved_at_utc           TEXT,
    resolved_by_upn           TEXT,
    notes                     TEXT NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_drift_events_repo_sha
    ON drift_events (repo_id, gitea_commit_sha);

CREATE INDEX IF NOT EXISTS ix_drift_events_pending
    ON drift_events (resolution, detected_at_utc DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '29')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
