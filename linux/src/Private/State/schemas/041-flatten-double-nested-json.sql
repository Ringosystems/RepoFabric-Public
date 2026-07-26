-- Migration 041: flatten legacy double-nested JSON-array columns.
--
-- Writers up to PR #155 serialized these columns with
-- `ConvertTo-Json -InputObject @(...) -AsArray`, which double-wraps an
-- already-array input (@('x64') -> [["x64"]], @() -> [[]]). #155 fixed the
-- writers to emit flat arrays; this normalizes the rows written before that so
-- the invariant is simple and uniform: THESE COLUMNS ALWAYS HOLD A FLAT JSON
-- ARRAY. With that guaranteed, readers can just parse — no shape-tolerance
-- special-casing needed.
--
-- Detection is shape-based and IDEMPOTENT: a value is a double-wrap iff it is a
-- JSON array of length 1 whose single element is itself an array. A legitimately
-- flat array never matches (its $[0] is a string/object), so re-running is a
-- no-op and already-flat rows are left untouched. json_extract(col,'$[0]')
-- returns that inner array as flat JSON text. Verified against the target
-- sqlite3: [["x64","x86"]]->["x64","x86"], [[]]->[], [[{...}]]->[{...}].
--
-- Columns (writers all fixed in #155; empirically confirmed on the live
-- instance before shipping): subscription.arch_policy / locale_policy,
-- publish_events.manifest_files_json, custom_packages.upstream_match_json,
-- gitea_archive_commits.parent_shas_json. installer_files_json, versions_json,
-- files_copied_json and files_changed_json were checked and are already flat.
--
-- Data-only UPDATEs (no schema change), so no PRAGMA rebuild directives.

BEGIN;

UPDATE subscription SET arch_policy = json_extract(arch_policy, '$[0]')
 WHERE json_valid(arch_policy) AND json_type(arch_policy) = 'array'
   AND json_array_length(arch_policy) = 1 AND json_type(arch_policy, '$[0]') = 'array';

UPDATE subscription SET locale_policy = json_extract(locale_policy, '$[0]')
 WHERE json_valid(locale_policy) AND json_type(locale_policy) = 'array'
   AND json_array_length(locale_policy) = 1 AND json_type(locale_policy, '$[0]') = 'array';

UPDATE publish_events SET manifest_files_json = json_extract(manifest_files_json, '$[0]')
 WHERE json_valid(manifest_files_json) AND json_type(manifest_files_json) = 'array'
   AND json_array_length(manifest_files_json) = 1 AND json_type(manifest_files_json, '$[0]') = 'array';

UPDATE custom_packages SET upstream_match_json = json_extract(upstream_match_json, '$[0]')
 WHERE upstream_match_json IS NOT NULL AND json_valid(upstream_match_json) AND json_type(upstream_match_json) = 'array'
   AND json_array_length(upstream_match_json) = 1 AND json_type(upstream_match_json, '$[0]') = 'array';

UPDATE gitea_archive_commits SET parent_shas_json = json_extract(parent_shas_json, '$[0]')
 WHERE json_valid(parent_shas_json) AND json_type(parent_shas_json) = 'array'
   AND json_array_length(parent_shas_json) = 1 AND json_type(parent_shas_json, '$[0]') = 'array';

INSERT INTO state_meta (key, value) VALUES ('schema_version', '41')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_041_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
