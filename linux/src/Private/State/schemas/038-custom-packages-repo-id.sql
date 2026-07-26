-- Migration 038 (linux fork): custom_packages becomes repo-aware.
--
-- custom_packages (migration 013) predates virtual repos (migration 020) and
-- was hard-wired to the single 'main' repo: its uniqueness was per package_id
-- alone, and Publish-/Update-/Remove-RfCustomPackage always wrote to main's
-- Gitea repo + manifest mount. The RepoFabric Ingest Protocol lets a client
-- target any EXISTING managed repo (via the promote-style config override that
-- Invoke-RfPromote already uses), so a custom package must be identified by
-- (repo_id, package_id) rather than package_id alone -- the same app can now be
-- published independently into more than one repo.
--
-- ADD COLUMN with a constant default is an in-place, table-rewrite-free change
-- in SQLite, and DEFAULT 'main' backfills every existing row to the repo they
-- were implicitly published to, so no data migration is needed. Only the
-- uniqueness shape changes: drop the package_id-only index, add the composite.
-- Publish-RfCustomPackage's ON CONFLICT target moves to (repo_id, package_id)
-- in lockstep with this migration.

-- NOTE (fix): the ADD COLUMN that used to sit here was redundant and fatal.
-- Migration 020 (line 89) ALREADY does the identical
--     ALTER TABLE custom_packages ADD COLUMN repo_id TEXT NOT NULL DEFAULT 'main';
-- and 020 always runs before 038, so on every FRESH database this failed with
-- "duplicate column name: repo_id". It went unnoticed because the migration
-- runner used to invoke sqlite3 WITHOUT -bail, which swallowed the error and
-- carried on; #153 added -bail (correctly), which turned the latent duplicate
-- into a hard stop and broke first-boot for any new deployment. Existing
-- databases at schema_version >= 38 never re-run this file and are unaffected.
-- The column is left to 020; this migration only reshapes uniqueness.

BEGIN;

DROP INDEX IF EXISTS ux_custom_packages_pkg;
CREATE UNIQUE INDEX IF NOT EXISTS ux_custom_packages_repo_pkg
    ON custom_packages (repo_id, package_id);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '38')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_038_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
