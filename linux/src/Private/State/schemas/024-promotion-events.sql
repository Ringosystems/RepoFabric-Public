-- Migration 024: promotion_events table (RepoFabric 0.8.0 Phase C.f).
--
-- Records every cross-repo promotion event. A "promotion" copies a
-- published package version's manifest set (and optionally its installer)
-- from one virtual repo's tree to another's, with the target's binary
-- mode driving whether the installer is copied locally or referenced
-- as an upstream URL.
--
-- The full publish-events ledger (Phase D) will eventually let us link
-- source_publish_event_id and target_publish_event_id to specific
-- canonical rows; for Phase C.f those fields are nullable and remain
-- empty. We capture enough information (package_id, package_version,
-- source/target gitea commit shas) that the promotion is auditable
-- and reversible without the ledger.
--
-- Status lifecycle:
--   queued      Inserted by Invoke-RfPromote at the start of a run.
--   in_progress Set when manifest copy + git push begin.
--   succeeded   All copies and the target Gitea commit succeeded.
--   failed      Any step failed; failure_message holds the diagnostic.
--
-- The append-only convention applies (Phase D will add triggers; until
-- then, application code is the only writer).

BEGIN;

CREATE TABLE IF NOT EXISTS promotion_events (
    promotion_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    initiated_at              TEXT NOT NULL,
    initiated_by              TEXT NOT NULL,

    source_repo_id            TEXT NOT NULL,
    target_repo_id            TEXT NOT NULL,
    -- Optional ledger links, populated by Phase D once publish_events lands.
    source_publish_event_id   INTEGER,
    target_publish_event_id   INTEGER,

    package_id                TEXT NOT NULL,
    package_version           TEXT NOT NULL,

    -- 'inherit_source' = follow source's binary_mode at promote time;
    -- 'force_local'    = always copy installer to target;
    -- 'force_upstream' = always keep upstream URL (no installer copy).
    binary_mode_decision      TEXT NOT NULL DEFAULT 'inherit_source'
                              CHECK (binary_mode_decision IN
                                  ('inherit_source','force_local','force_upstream')),
    -- Resolved decision actually applied after factoring in target repo's
    -- default_binary_mode. Useful for audit reads.
    binary_mode_applied       TEXT
                              CHECK (binary_mode_applied IS NULL OR
                                     binary_mode_applied IN ('local','upstream')),

    status                    TEXT NOT NULL DEFAULT 'queued'
                              CHECK (status IN ('queued','in_progress','succeeded','failed')),

    -- Gitea commit shas. Source identifies what we copied from; target
    -- captures the new commit on the destination repo.
    source_gitea_commit_sha   TEXT,
    target_gitea_commit_sha   TEXT,

    -- Manifest filenames copied, JSON array. Useful for revert tooling.
    files_copied_json         TEXT NOT NULL DEFAULT '[]',
    installer_copied          INTEGER NOT NULL DEFAULT 0,   -- 0/1 bool
    installer_bytes           INTEGER,

    completed_at              TEXT,
    duration_ms               INTEGER,
    failure_message           TEXT,
    notes                     TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_promotion_events_source       ON promotion_events (source_repo_id);
CREATE INDEX IF NOT EXISTS ix_promotion_events_target       ON promotion_events (target_repo_id);
CREATE INDEX IF NOT EXISTS ix_promotion_events_package      ON promotion_events (package_id, package_version);
CREATE INDEX IF NOT EXISTS ix_promotion_events_status       ON promotion_events (status);
CREATE INDEX IF NOT EXISTS ix_promotion_events_initiated_at ON promotion_events (initiated_at);

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '24')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_024_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
