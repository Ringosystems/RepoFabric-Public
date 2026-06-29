-- Migration 004: v0.4 publication fields.
--
-- v0.4 swaps the publish backend from winget.pro (Django) to Gitea (git push)
-- + nginx (file upload). The publication row now needs to record:
--   * git_commit_sha    — SHA of the manifest commit pushed to Gitea
--   * manifest_repo_path — repo-relative directory holding the 3-file YAML set
--   * installer_base_url — base URL the installer URLs were rewritten to
--                          (captured at publish time so a later config change
--                          does not silently invalidate old publications)
--
-- All three columns are nullable so historic v0.3 rows (published via the
-- SSH transport) continue to load.

ALTER TABLE publication ADD COLUMN git_commit_sha    TEXT;
ALTER TABLE publication ADD COLUMN manifest_repo_path TEXT;
ALTER TABLE publication ADD COLUMN installer_base_url TEXT;

CREATE INDEX IF NOT EXISTS idx_publication_commit_sha
    ON publication (git_commit_sha)
    WHERE git_commit_sha IS NOT NULL;

-- Record the v0.3 -> v0.4 transition for forensic purposes.
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '4');
INSERT OR REPLACE INTO state_meta (key, value)
VALUES ('v0_4_transition_at', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
