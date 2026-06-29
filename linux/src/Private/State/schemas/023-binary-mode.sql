-- Migration 023: binary_mode field on subscription and custom_packages
-- (RepoFabric 0.8.0 Phase C.a).
--
-- Introduces per-package binary hosting modes:
--   * 'local'        Publisher downloads the installer and writes it to the
--                    repo's installer storage; manifest InstallerUrl is
--                    rewritten to point at the local installer base URL.
--                    This is the 0.7.x default behaviour.
--   * 'upstream'     Publisher does NOT download the installer. The manifest
--                    keeps the upstream vendor's InstallerUrl. Saves
--                    disk + bandwidth for packages with reliable upstream
--                    CDNs. Periodic HEAD probes surface broken upstream
--                    URLs in the admin UI.
--   * NULL           Defer to the virtual repo's default_binary_mode
--                    (column already exists on virtual_repos from
--                    migration 020). Most rows use this so changing
--                    the repo-level default is a single UPDATE.
--
-- Idempotent: ADD COLUMN with a NULL default leaves existing rows at
-- NULL (= inherit), so 0.7.x -> 0.8.0 upgrades preserve current behaviour
-- because virtual_repos.default_binary_mode itself defaults to 'local'.
--
-- The upstream_url_override field is the publisher's source of truth when
-- binary_mode='upstream' but the operator wants a different URL than what
-- upstream-tracking would normally pick. Common case: the upstream
-- microsoft/winget-pkgs manifest points at a CDN that's slow or blocked
-- in the operator's region; they pin a known-good mirror URL instead.

BEGIN;

ALTER TABLE subscription
    ADD COLUMN binary_mode TEXT
    CHECK (binary_mode IS NULL OR binary_mode IN ('local','upstream'));
ALTER TABLE subscription
    ADD COLUMN upstream_url_override TEXT;

ALTER TABLE custom_packages
    ADD COLUMN binary_mode TEXT
    CHECK (binary_mode IS NULL OR binary_mode IN ('local','upstream'));
ALTER TABLE custom_packages
    ADD COLUMN upstream_url_override TEXT;

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '23')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_023_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
