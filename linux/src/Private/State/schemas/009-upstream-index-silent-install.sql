-- Migration 009: upstream_index.has_silent_install
-- Indexes whether the upstream installer manifest declares an explicit Silent
-- switch (or is one of the inherently-silent installer types). Backs the
-- fitness matrix in the Add subscription typeahead.
--
-- Backfill is intentionally absent: rows default to 0 until the next walker
-- run repopulates them. Operators can trigger a re-walk from the Operations
-- tab once the schema is bumped.

ALTER TABLE upstream_index ADD COLUMN has_silent_install INTEGER NOT NULL DEFAULT 0;

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '9');
