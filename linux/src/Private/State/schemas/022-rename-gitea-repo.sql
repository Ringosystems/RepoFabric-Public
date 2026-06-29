-- Migration 022: align virtual_repos.gitea_repo_path with the post-rename
-- Gitea organisation name (RepoFabric 0.8.0 Phase A.11).
--
-- Migration 020 seeded the 'main' virtual repo's gitea_repo_path with
-- whatever string was in the SQL file at the moment 020 first ran. For
-- operators who applied 020 from commit 32098eb (before the Phase A.6
-- mechanical rename), the seeded value is 'wgrs/winget-manifests'. The
-- migration script's deploy/migrate-0.7-to-0.8.sh renames the Gitea
-- organisation 'wgrs' to 'repofabric', so the seeded value must be
-- updated to match.
--
-- Idempotent guard: WHERE matches only the exact legacy value. Fresh
-- installs (where 020 seeded the new value directly) and operators who
-- already updated the row manually are no-ops.

BEGIN;

UPDATE virtual_repos
   SET gitea_repo_path = 'repofabric/winget-manifests'
 WHERE repo_id = 'main'
   AND gitea_repo_path = 'wgrs/winget-manifests';

INSERT INTO state_meta (key, value) VALUES ('schema_version', '22')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_022_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
