-- Migration 012 (linux fork): repo_catalog table.
--
-- Populated by Update-RfRepoCatalog which walks the read-only manifest
-- volume mount at /var/cache/repofabric/manifests every 5 minutes via cron and
-- on-demand after a managed sync or custom publish. The unified
-- Subscriptions view joins this against the subscription and
-- custom_packages tables to render three sections (managed, custom,
-- untracked).

BEGIN;

CREATE TABLE IF NOT EXISTS repo_catalog (
    package_id       TEXT NOT NULL PRIMARY KEY,
    package_name     TEXT,
    publisher        TEXT,
    latest_version   TEXT,
    version_count    INTEGER NOT NULL DEFAULT 0,
    -- All versions present in the repo, JSON array sorted descending by
    -- semver-ish version comparison. The wizard's adopt-as-subscription
    -- flow uses this to pre-fill the pinned-version dropdown.
    versions_json    TEXT NOT NULL DEFAULT '[]',
    first_seen_at    TEXT NOT NULL,
    last_seen_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_repo_catalog_publisher ON repo_catalog (publisher);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '12')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
