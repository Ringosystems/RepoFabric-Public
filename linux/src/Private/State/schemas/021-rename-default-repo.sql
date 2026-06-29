-- Migration 021: align upgraded virtual_repos.main row with the 0.8.0
-- container-name rename.
--
-- Migration 020 (RepoFabric 0.8.0 Phase A) created the virtual_repos
-- table and seeded a 'main' row. For operators running a fresh install,
-- the seed values use the new naming convention from the start.
--
-- For operators upgrading from 0.7.x to 0.8.0, the same migration ran
-- under the OLD naming convention (commit 32098eb on 0.8.0-repofabric
-- branch, predating the Phase A.6 mechanical rename to RepoFabric).
-- Their virtual_repos.main row therefore has rewinged_container_name
-- set to the legacy 'wgrs-rewinged'.
--
-- This migration brings upgraded databases into alignment with the
-- renamed container. The UPDATE is guarded by a WHERE clause matching
-- the exact legacy string, so:
--   * Already-aligned rows (fresh installs or already-migrated) are no-ops.
--   * Operators who customised the value to something else are not stomped.
--
-- gitea_repo_path is intentionally NOT updated here. The Gitea
-- organisation rename ('wgrs' -> 'repofabric') is an OPERATOR DECISION:
--   * Some operators will rename their Gitea org for consistency with
--     the new product name; they update the path via the admin UI
--     (Phase C delivers the CRUD endpoint).
--   * Others will keep 'wgrs' as their Gitea org because Gitea repo
--     URLs that show up in webhooks, external clones, etc. would
--     change and break those integrations.
--
-- Defaulting either way risks pointing the manifest publisher at a
-- non-existent Gitea repo, so we leave the field untouched.

BEGIN;

UPDATE virtual_repos
   SET rewinged_container_name = 'repofabric-rewinged'
 WHERE repo_id = 'main'
   AND rewinged_container_name = 'wgrs-rewinged';

INSERT INTO state_meta (key, value) VALUES ('schema_version', '21')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_021_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
