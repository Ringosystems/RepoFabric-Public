-- Migration 026: scope the subscription UNIQUE constraint by repo_id.
--
-- Migration 011 created ux_subscription_pkg_track_pin on
-- (package_id, track, COALESCE(pinned_version, '')). That made sense
-- when 'main' was the only virtual repo. Now that virtual_repos
-- supports dev/test/prod and departmental repos (added in 020), the
-- same package can legitimately be subscribed independently in each
-- repo: main might pin 7zip.7zip 26.01 while test tracks latest.
-- The old constraint blocks the second subscription INSERT with a
-- spurious UNIQUE violation.
--
-- Drop the legacy index and recreate it scoped by repo_id. Existing
-- 'main'-only subscriptions are unaffected: their repo_id is 'main'
-- on every row (NOT NULL DEFAULT 'main' from 020), so the new index
-- enforces the same invariant within 'main' that the old one
-- enforced globally.

BEGIN;

DROP INDEX IF EXISTS ux_subscription_pkg_track_pin;

CREATE UNIQUE INDEX ux_subscription_repo_pkg_track_pin
    ON subscription (repo_id, package_id, track, COALESCE(pinned_version, ''));

INSERT INTO state_meta (key, value) VALUES ('schema_version', '26')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
