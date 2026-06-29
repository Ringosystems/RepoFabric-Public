-- Migration 028: precomputed natural-sort key for upstream_index versions.
--
-- The Add-subscription typeahead and any other surface that picks
-- "the latest version of this package" was ordering versions lexically
-- via SQL ORDER BY version DESC. winget version strings like '99.0.1'
-- sort higher than '150.0.1' in lexical order because '9' > '1', so
-- Mozilla.Firefox showed as latest = 99.0.1 in the search dropdown even
-- though the upstream index contained 150-plus.
--
-- The drill-in preview (Get-RfUpstreamPackage) was fixed earlier in
-- 3b59660 by sorting PowerShell-side after the SQL pull. The search
-- CTE needs the same correctness but cannot afford a PS post-sort
-- because the CTE picks one row per package across ~10k packages on
-- every keystroke.
--
-- Add a precomputed sort key that is sortable lexically: each dot-
-- segment of the version is left-padded with zeros to 10 chars, so
-- '150.0.7558.62' becomes '0000000150.0000000000.0000007558.0000000062'
-- which collates correctly against '99.0.1' -> '0000000099.0000000000.0000000001'.
-- Non-numeric segments (prerelease tags, letter suffixes) collapse to
-- their leading digits or '0' so the key remains comparable.
--
-- Population: the column is NULL on existing rows after migration.
-- The next Update-RfUpstreamIndex pass fills it in. Until then, the
-- search query uses COALESCE(version_sort_key, version) so existing
-- rows fall back to lexical sort (today's behavior, no regression).

BEGIN;

ALTER TABLE upstream_index ADD COLUMN version_sort_key TEXT;

CREATE INDEX IF NOT EXISTS ix_upstream_index_sort_key
    ON upstream_index (package_id, version_sort_key DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '28')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
