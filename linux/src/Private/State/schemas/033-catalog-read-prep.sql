-- Migration 033: per-repo catalog key + promotion stage.
-- Groundwork for the M6 catalog-read API (Ringosystems/RepoFabric#2): the
-- presence point-query and projection-export are per (repo_id, app_id), but
-- repo_catalog was keyed on package_id alone (012) with repo_id only added as
-- a column in 020 (default 'main'). This rebuilds it to a composite primary
-- key so a package can be present in more than one virtual repo, and adds the
-- promotion-stage column the presence response carries (decision Q10).

BEGIN;

-- 1. repo_catalog -> composite (repo_id, package_id) primary key.
-- SQLite cannot change a PK in place, so rebuild + copy + swap (same pattern
-- as 003/005/010). repo_catalog has no inbound foreign keys, so the drop is
-- safe. repo_id keeps DEFAULT 'main' so the existing single-repo writer that
-- omits repo_id keeps working unchanged.
CREATE TABLE repo_catalog_new (
    repo_id        TEXT NOT NULL DEFAULT 'main',
    package_id     TEXT NOT NULL,
    package_name   TEXT,
    publisher      TEXT,
    latest_version TEXT,
    version_count  INTEGER NOT NULL DEFAULT 0,
    versions_json  TEXT NOT NULL DEFAULT '[]',
    first_seen_at  TEXT NOT NULL,
    last_seen_at   TEXT NOT NULL,
    PRIMARY KEY (repo_id, package_id)
);

INSERT INTO repo_catalog_new
    (repo_id, package_id, package_name, publisher, latest_version,
     version_count, versions_json, first_seen_at, last_seen_at)
SELECT repo_id, package_id, package_name, publisher, latest_version,
       version_count, versions_json, first_seen_at, last_seen_at
FROM repo_catalog;

DROP TABLE repo_catalog;
ALTER TABLE repo_catalog_new RENAME TO repo_catalog;

CREATE INDEX IF NOT EXISTS ix_repo_catalog_publisher ON repo_catalog (publisher);
CREATE INDEX IF NOT EXISTS ix_repo_catalog_repo      ON repo_catalog (repo_id);

-- 2. virtual_repos.stage: nullable promotion stage (Q10). NULL means the
-- endpoint passes the bare slug through as the stage. Fixed enum.
ALTER TABLE virtual_repos ADD COLUMN stage TEXT
    CHECK (stage IS NULL OR stage IN ('main', 'dev', 'test', 'departmental'));

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '33')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_033_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
