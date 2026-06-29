-- @repofabric:disable-foreign-keys
-- @repofabric:legacy-alter-table
--
-- Migration 034: widen publish_events.event_type to the ratified cross-fabric
-- verb union (M6 / 0.8.1 integrated ConfigFabric sidecar; RepoFabric#4).
--
-- Migration 032 added source_fabric but deliberately deferred widening the
-- event_type CHECK until ConfigFabric froze its verb set. ConfigFabric has now
-- ratified and shipped the union (ConfigFabric commit e934e42 / its migration
-- 091):
--   publish | promote | revert | import | drift | drift_merged | restore | assign
-- keeping drift (single-source) and drift_merged (post-merge) distinct, and
-- promoting assign (config -> Entra-group assignment) to a first-class event.
-- Until RepoFabric matches, ConfigFabric's drift / assign / import audit events
-- POSTed to the shared POST /api/audit/events ingress are rejected by the CHECK.
--
-- SQLite cannot ALTER a CHECK in place, so rebuild per the migration 010 pattern
-- (foreign_keys OFF + legacy_alter_table ON around a rename / create / copy /
-- drop), preserving every column (including source_fabric from 032), all
-- indexes, and the self-referential FKs. Copying publish_event_id explicitly
-- preserves ids and the AUTOINCREMENT high-water mark.
--
-- ORDERING: this is migration 034 and assumes 033 (the catalog-read prep,
-- RepoFabric#7) has been applied. Merge #7 before this.
--
-- ATOMICITY: wrap the rebuild in a single transaction so an interruption between
-- the RENAME and the schema_version bump rolls back cleanly instead of leaving
-- publish_events renamed away and wedging all future migrations (RepoFabric#35 M3).
-- The foreign_keys pragma is applied by the runner OUTSIDE this transaction (it is
-- a no-op inside one); BEGIN/COMMIT here matches the migration 011 pattern.

BEGIN;

ALTER TABLE publish_events RENAME TO _publish_events_old;

CREATE TABLE publish_events (
    publish_event_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp_utc           TEXT NOT NULL,
    repo_id                 TEXT NOT NULL,

    event_type              TEXT NOT NULL
                            CHECK (event_type IN
                                ('publish','promote','revert','import','drift','drift_merged','restore','assign')),

    package_id              TEXT NOT NULL,
    package_version         TEXT NOT NULL,

    subscription_id         INTEGER,
    custom_package_id       INTEGER,

    binary_mode_effective   TEXT
                            CHECK (binary_mode_effective IS NULL OR
                                   binary_mode_effective IN ('local','upstream')),

    manifest_files_json     TEXT NOT NULL DEFAULT '[]',
    installer_files_json    TEXT NOT NULL DEFAULT '[]',
    upstream_installer_url  TEXT,

    gitea_commit_sha        TEXT,
    gitea_commit_message    TEXT,

    operator_upn            TEXT NOT NULL,
    source                  TEXT NOT NULL,

    reverted_at             TEXT,
    reverted_by_event_id    INTEGER REFERENCES publish_events(publish_event_id),

    promoted_from_event_id  INTEGER REFERENCES publish_events(publish_event_id),
    source_repo_id          TEXT,

    notes                   TEXT NOT NULL DEFAULT '',

    source_fabric           TEXT NOT NULL DEFAULT 'repofabric'
                            CHECK (source_fabric IN ('repofabric','configfabric'))
);

INSERT INTO publish_events (
    publish_event_id, timestamp_utc, repo_id, event_type, package_id, package_version,
    subscription_id, custom_package_id, binary_mode_effective,
    manifest_files_json, installer_files_json, upstream_installer_url,
    gitea_commit_sha, gitea_commit_message, operator_upn, source,
    reverted_at, reverted_by_event_id, promoted_from_event_id, source_repo_id,
    notes, source_fabric)
SELECT
    publish_event_id, timestamp_utc, repo_id, event_type, package_id, package_version,
    subscription_id, custom_package_id, binary_mode_effective,
    manifest_files_json, installer_files_json, upstream_installer_url,
    gitea_commit_sha, gitea_commit_message, operator_upn, source,
    reverted_at, reverted_by_event_id, promoted_from_event_id, source_repo_id,
    notes, source_fabric
FROM _publish_events_old;

DROP TABLE _publish_events_old;

CREATE INDEX IF NOT EXISTS ix_publish_events_repo_time     ON publish_events (repo_id, timestamp_utc);
CREATE INDEX IF NOT EXISTS ix_publish_events_pkg           ON publish_events (package_id, package_version);
CREATE INDEX IF NOT EXISTS ix_publish_events_type          ON publish_events (event_type);
CREATE INDEX IF NOT EXISTS ix_publish_events_subscription  ON publish_events (subscription_id);
CREATE INDEX IF NOT EXISTS ix_publish_events_promoted_from ON publish_events (promoted_from_event_id);
CREATE INDEX IF NOT EXISTS ix_publish_events_source_fabric ON publish_events (source_fabric);

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '34');
INSERT OR REPLACE INTO state_meta (key, value)
    VALUES ('migration_034_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

COMMIT;
