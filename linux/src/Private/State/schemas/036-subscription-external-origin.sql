-- Migration 036: external-origin fields on subscription (A4 / FD-037).
--
-- Enables the DSCForge agent auto-carry path: subscriptions whose installer is
-- acquired from an allow-listed GitHub Release instead of a winget upstream
-- manifest (e.g. Ringo.DSCForge.RemoteAgent from Ringosystems/DscForge).
--
--   * origin_type    NULL or 'winget'  -> existing manifest-driven acquire path
--                    'github-release'  -> external-acquire path
--                    (Resolve-RfExternalRelease + download + sha256-pin verify).
--   * origin_repo    '<owner>/<repo>' of the allow-listed release origin
--                    (required when origin_type='github-release').
--   * asset_pattern  Wildcard selecting the installer asset on the release
--                    (e.g. '*.msi'); required for github-release.
--   * pinned_sha256  FD-037 MANDATORY sha256 pin captured at subscription time.
--                    The external acquire verifies the downloaded bytes against
--                    this hash and ABORTS on mismatch. Required for
--                    github-release.
--
-- Idempotent + backwards-safe: ADD COLUMN with NULL default leaves every
-- existing subscription at origin_type=NULL, which the acquire path treats as
-- 'winget' — so 0.8.x rows keep their current manifest-driven behaviour
-- unchanged. The CHECK constraints fail closed on an unknown origin_type and
-- enforce that a github-release row carries its origin_repo + asset_pattern +
-- pinned_sha256 (no half-configured external subscriptions).

BEGIN;

ALTER TABLE subscription
    ADD COLUMN origin_type TEXT
    CHECK (origin_type IS NULL OR origin_type IN ('winget','github-release'));
ALTER TABLE subscription
    ADD COLUMN origin_repo TEXT;
ALTER TABLE subscription
    ADD COLUMN asset_pattern TEXT;
ALTER TABLE subscription
    ADD COLUMN pinned_sha256 TEXT;

-- A github-release subscription MUST be fully specified; winget/NULL rows must
-- leave the external fields NULL. Enforced as a table-level CHECK via a trigger
-- (SQLite cannot add a multi-column CHECK through ALTER TABLE).
CREATE TRIGGER IF NOT EXISTS subscription_external_origin_complete_insert
BEFORE INSERT ON subscription
FOR EACH ROW
WHEN NEW.origin_type = 'github-release'
     AND (NEW.origin_repo IS NULL OR NEW.asset_pattern IS NULL OR NEW.pinned_sha256 IS NULL)
BEGIN
    SELECT RAISE(ABORT, 'github-release subscription requires origin_repo, asset_pattern and pinned_sha256 (FD-037)');
END;

CREATE TRIGGER IF NOT EXISTS subscription_external_origin_complete_update
BEFORE UPDATE ON subscription
FOR EACH ROW
WHEN NEW.origin_type = 'github-release'
     AND (NEW.origin_repo IS NULL OR NEW.asset_pattern IS NULL OR NEW.pinned_sha256 IS NULL)
BEGIN
    SELECT RAISE(ABORT, 'github-release subscription requires origin_repo, asset_pattern and pinned_sha256 (FD-037)');
END;

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '36')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_036_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
