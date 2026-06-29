-- Migration 025: publish_events ledger (RepoFabric 0.8.0 Phase D.1).
--
-- The 'publication' table from migration 001 is the operational record of
-- WHAT is currently published, and is mutable (notes can change, outcome
-- can flip success -> rolled_back). publish_events is its immutable
-- ledger counterpart, written append-only by every action that changes
-- the published catalog of any virtual repo:
--
--   * publish        successful Invoke-RfPublish (normal sync or custom
--                    upload). Refers back to a publication row.
--   * promote        successful Invoke-RfPromote landed in the target
--                    repo. promoted_from_event_id links to the source
--                    repo's publish event.
--   * revert         Phase D.4 (TBD): a publish event was rolled back.
--   * drift_merged   Phase D.5 (TBD): an external Gitea commit was
--                    captured into our ledger (someone pushed manifests
--                    to Gitea outside RepoFabric).
--   * restore        Phase D.7 (TBD): a publish event was reapplied
--                    from the gitea archive backup tables.
--
-- All Phase D operations that mutate the repo (revert, restore, drift
-- merge) will add their own rows here; together with the original
-- 'publish' / 'promote' rows they form a strictly-ordered history.
--
-- Forward compatibility:
--   * reverted_at and reverted_by_event_id columns are nullable now
--     and populated by the Phase D.4 revert workflow.
--   * source_publish_event_id on the existing promotion_events table
--     was added in migration 024 nullable; Phase D wires it to the
--     row we insert here, so post-Phase D every promotion will have
--     both source and target event ids populated.
--
-- Index strategy: range queries by repo + time dominate the Activity tab
-- and the future DR drill UI; the (repo_id, timestamp_utc) composite
-- supports both repo-scoped chronological reads and bulk audit dumps.

BEGIN;

CREATE TABLE IF NOT EXISTS publish_events (
    publish_event_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp_utc           TEXT NOT NULL,
    repo_id                 TEXT NOT NULL,

    event_type              TEXT NOT NULL
                            CHECK (event_type IN
                                ('publish','promote','revert','drift_merged','restore')),

    package_id              TEXT NOT NULL,
    package_version         TEXT NOT NULL,

    -- One of these is set depending on origin. NULL on promote/revert/restore
    -- because those derive from other rows rather than a fresh
    -- subscription / custom upload.
    subscription_id         INTEGER,
    custom_package_id       INTEGER,

    binary_mode_effective   TEXT
                            CHECK (binary_mode_effective IS NULL OR
                                   binary_mode_effective IN ('local','upstream')),

    -- Snapshots. JSON-encoded so SQLite stays portable.
    manifest_files_json     TEXT NOT NULL DEFAULT '[]',
    installer_files_json    TEXT NOT NULL DEFAULT '[]',
    upstream_installer_url  TEXT,

    gitea_commit_sha        TEXT,
    gitea_commit_message    TEXT,

    operator_upn            TEXT NOT NULL,
    source                  TEXT NOT NULL,   -- e.g. 'sync', 'custom_publish', 'promote', 'revert'

    -- Forward-compat for D.4 revert workflow. NULL until a revert row
    -- targets this event.
    reverted_at             TEXT,
    reverted_by_event_id    INTEGER REFERENCES publish_events(publish_event_id),

    -- Forward-compat for promotion + restore linkage.
    promoted_from_event_id  INTEGER REFERENCES publish_events(publish_event_id),
    source_repo_id          TEXT,

    notes                   TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_publish_events_repo_time  ON publish_events (repo_id, timestamp_utc);
CREATE INDEX IF NOT EXISTS ix_publish_events_pkg        ON publish_events (package_id, package_version);
CREATE INDEX IF NOT EXISTS ix_publish_events_type       ON publish_events (event_type);
CREATE INDEX IF NOT EXISTS ix_publish_events_subscription ON publish_events (subscription_id);
CREATE INDEX IF NOT EXISTS ix_publish_events_promoted_from ON publish_events (promoted_from_event_id);

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '25')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_025_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
