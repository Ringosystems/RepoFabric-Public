-- Migration 031: dr_drill_results table (RepoFabric 0.8.0 Phase D.7).
--
-- Test-RfDisasterRecovery reconstructs a Gitea repo from the archive
-- into a temporary bare git tree, runs git fsck, and verifies that
-- the reconstructed head commit's SHA matches the snapshot's
-- head_commit_sha (byte-perfect proof that the archive is restorable).
-- Each drill writes one row here so the admin UI can show "last
-- successful drill at <time> for repo X" and red-banner stale or
-- failed drills.

BEGIN;

CREATE TABLE IF NOT EXISTS dr_drill_results (
    drill_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at_utc        TEXT    NOT NULL,
    ended_at_utc          TEXT,
    repo_id               TEXT    NOT NULL,
    snapshot_id           INTEGER REFERENCES gitea_archive_snapshots(snapshot_id),
    expected_head_sha     TEXT    NOT NULL,
    reconstructed_head_sha TEXT,
    sha_matches           INTEGER NOT NULL DEFAULT 0,
    fsck_ok               INTEGER NOT NULL DEFAULT 0,
    commits_walked        INTEGER NOT NULL DEFAULT 0,
    files_written         INTEGER NOT NULL DEFAULT 0,
    bytes_written         INTEGER NOT NULL DEFAULT 0,
    duration_ms           INTEGER,
    outcome               TEXT    NOT NULL DEFAULT 'in_progress'
                          CHECK (outcome IN ('in_progress','passed','failed')),
    failure_message       TEXT,
    initiated_by_upn      TEXT,
    notes                 TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_dr_drill_results_repo
    ON dr_drill_results (repo_id, started_at_utc DESC);
CREATE INDEX IF NOT EXISTS ix_dr_drill_results_outcome
    ON dr_drill_results (outcome);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '31')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
