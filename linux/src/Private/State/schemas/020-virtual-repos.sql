-- Migration 020: virtual_repos table + repo_id scoping (RepoFabric 0.8.0).
--
-- Introduces the multi-virtual-repo data model that the 0.8.0 architecture
-- redesign is built around. A "virtual repo" is a logically isolated
-- catalog with its own subscriptions, custom apps, sync queue, publish
-- history, manifest tree, and dedicated Rewinged container. Operators
-- typically run several virtual repos (dev/test/prod, or per-department)
-- against the same RepoFabric instance.
--
-- Phase A scope:
--   * Create virtual_repos table.
--   * Seed a default 'main' row that all existing data is auto-attributed
--     to, so a 0.7.x -> 0.8.0 upgrade is non-destructive.
--   * Add repo_id columns to operational tables with DEFAULT 'main' so
--     SQLite backfills existing rows in-place. NOT NULL on tables whose
--     rows always belong to one repo; NULL allowed on tables that capture
--     a mix of repo-scoped and global events (admin_event, notification,
--     notification_state, publication_notes).
--   * Add lookup indexes on the new columns.
--
-- Out of scope for this migration (deferred to Phase C when the multi-repo
-- CRUD lands):
--   * Tightening UNIQUE constraints (e.g., subscription.UNIQUE(package_id,
--     track, pinned_version)) to include repo_id. Safe to defer because
--     only one repo exists today; conflicts only become possible after
--     the operator creates a second virtual repo via the new admin UI.
--   * Foreign-key constraints from repo_id columns back to virtual_repos.
--     SQLite cannot add FKs via ALTER TABLE; application code enforces
--     validity until Phase C rebuilds the affected tables.
--
-- Tables that intentionally stay global (no repo_id):
--   * state_meta (schema versioning is system-wide).
--   * upstream_index, upstream_index_meta (the cached microsoft/winget-pkgs
--     index is a shared resource by design: a single sparse clone serves
--     every virtual repo's catalog lookups).

BEGIN;

-- ---------- virtual_repos ----------
CREATE TABLE IF NOT EXISTS virtual_repos (
    repo_id                 TEXT PRIMARY KEY,                          -- slug: [a-z0-9-]+
    display_name            TEXT NOT NULL,
    description             TEXT NOT NULL DEFAULT '',
    base_domain             TEXT,                                      -- nullable; filled at setup
    hostname                TEXT,                                      -- nullable; defaults to winget-{repo_id}.{base_domain}
    gitea_repo_path         TEXT NOT NULL,                             -- e.g. 'repofabric/winget-main'
    default_binary_mode     TEXT NOT NULL DEFAULT 'local'
                            CHECK (default_binary_mode IN ('local','upstream','hybrid')),
    upstream_probe_enabled  INTEGER NOT NULL DEFAULT 0,
    status                  TEXT NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','archived','creating','tearing_down')),
    rewinged_container_name TEXT,                                      -- dynamically managed by docker-driver in Phase C
    rewinged_host_port      INTEGER,                                   -- assigned at repo creation
    created_at              TEXT NOT NULL,
    created_by              TEXT NOT NULL DEFAULT 'system',
    modified_at             TEXT,
    modified_by             TEXT
);

CREATE INDEX IF NOT EXISTS ix_virtual_repos_status ON virtual_repos (status);

-- Seed the default 'main' repo so existing rows have a valid attribution
-- after the ALTER TABLE backfills below. Uses ON CONFLICT DO NOTHING so
-- re-running the migration on an already-migrated DB is a no-op.
INSERT INTO virtual_repos (
    repo_id, display_name, description, gitea_repo_path,
    default_binary_mode, status,
    rewinged_container_name, rewinged_host_port,
    created_at, created_by
) VALUES (
    'main',
    'Main',
    'Default virtual repository (auto-created during 0.8.0 schema migration).',
    'repofabric/winget-manifests',
    'local',
    'active',
    'repofabric-rewinged',
    8090,
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    'system'
)
ON CONFLICT(repo_id) DO NOTHING;

-- ---------- Top-level operational tables (NOT NULL repo_id) ----------
-- SQLite ALTER TABLE ADD COLUMN with a non-NULL DEFAULT populates existing
-- rows at the time the column is added. Safe and atomic per statement.

ALTER TABLE subscription      ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE custom_packages   ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE sync_queue        ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE repo_catalog      ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE run               ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';

-- ---------- Dependent tables (denormalized repo_id for query perf) ----------
-- These could be looked up via FK joins, but denormalizing lets the admin
-- UI render per-repo activity views with simple WHERE clauses instead of
-- nested joins.

ALTER TABLE acquisition                 ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE transformation              ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE publication                 ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE publication_notes_archive   ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
ALTER TABLE run_event                   ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';

-- ---------- Mixed-scope tables (nullable repo_id) ----------
-- admin_event captures both per-repo (subscription_added) and global
-- (setup_completed, config_saved) events. Existing rows pre-migration
-- have no repo context; new rows populate when applicable.

ALTER TABLE admin_event         ADD COLUMN repo_id TEXT;
ALTER TABLE notification        ADD COLUMN repo_id TEXT;
ALTER TABLE notification_state  ADD COLUMN repo_id TEXT;
ALTER TABLE publication_notes   ADD COLUMN repo_id TEXT;

-- ---------- Indexes ----------
-- One index per operational table to make per-repo WHERE-clause scans fast.
-- Compound indexes that combine repo_id with package_id / version land in
-- Phase C alongside the multi-repo query patterns that need them.

CREATE INDEX IF NOT EXISTS ix_subscription_repo                ON subscription (repo_id);
CREATE INDEX IF NOT EXISTS ix_custom_packages_repo             ON custom_packages (repo_id);
CREATE INDEX IF NOT EXISTS ix_sync_queue_repo                  ON sync_queue (repo_id);
CREATE INDEX IF NOT EXISTS ix_repo_catalog_repo                ON repo_catalog (repo_id);
CREATE INDEX IF NOT EXISTS ix_run_repo                         ON run (repo_id);
CREATE INDEX IF NOT EXISTS ix_acquisition_repo                 ON acquisition (repo_id);
CREATE INDEX IF NOT EXISTS ix_transformation_repo              ON transformation (repo_id);
CREATE INDEX IF NOT EXISTS ix_publication_repo                 ON publication (repo_id);
CREATE INDEX IF NOT EXISTS ix_publication_notes_archive_repo   ON publication_notes_archive (repo_id);
CREATE INDEX IF NOT EXISTS ix_run_event_repo                   ON run_event (repo_id);
CREATE INDEX IF NOT EXISTS ix_admin_event_repo                 ON admin_event (repo_id);
CREATE INDEX IF NOT EXISTS ix_notification_repo                ON notification (repo_id);

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '20')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_020_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
