-- Migration 037: point the 'main' virtual repo's gitea_repo_path at the bundled
-- Gitea publisher ACCOUNT, so the manifests repo can actually be created and
-- pushed to on a fresh deploy.
--
-- deploy/gitea-provision.sh creates the publisher as the Gitea USER
-- 'repofabric-publisher' and mints a token scoped 'write:repository,write:user'
-- (no org-create rights). On first publish, New-RfGiteaRepoIfMissing creates the
-- manifests repo UNDER that user -> 'repofabric-publisher/winget-manifests'.
-- Migrations 020/022 seeded the path as 'repofabric/winget-manifests' (owner
-- 'repofabric'), which exists as neither a Gitea user nor an org, so every
-- publish failed to auto-create the repo (org endpoint 403, user endpoint 409)
-- and subscriptions sat 'completed' in the queue with no manifests served.
--
-- Idempotent guard: only the exact legacy value is rewritten. Fresh installs
-- (where 020 now seeds the new value directly) and operators who already fixed
-- the row by hand are no-ops.

BEGIN;

UPDATE virtual_repos
   SET gitea_repo_path = 'repofabric-publisher/winget-manifests'
 WHERE repo_id = 'main'
   AND gitea_repo_path = 'repofabric/winget-manifests';

INSERT INTO state_meta (key, value) VALUES ('schema_version', '37')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_037_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
