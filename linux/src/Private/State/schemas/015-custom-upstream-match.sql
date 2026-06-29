-- Migration 015 (linux fork): record upstream-hash collisions for
-- operator-published custom packages.
--
-- Two columns on custom_packages:
--   upstream_match_json       JSON array of {PackageId, Version, ManifestPath}
--                             entries from the most recent scan. Empty
--                             array means scanned and no match. NULL
--                             means never scanned (post-migration, pre-
--                             first-scan; cron fills it on Sunday).
--   upstream_match_checked_at ISO 8601 UTC of the scan that produced
--                             upstream_match_json. NULL until first
--                             scan.
--
-- The synchronous wizard inspection at upload time ALSO writes both
-- fields when the publish completes. The weekly cron job
-- Update-RfCustomPackageCollisions re-runs every Sunday overnight to
-- catch upstream additions that landed AFTER the original publish.

BEGIN;

ALTER TABLE custom_packages ADD COLUMN upstream_match_json       TEXT;
ALTER TABLE custom_packages ADD COLUMN upstream_match_checked_at TEXT;

INSERT INTO state_meta (key, value) VALUES ('schema_version', '15')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
