-- Migration 019 (linux fork): re-apply the trigger='tui' relabel that
-- migration 017 attempted against a non-existent 'runs' table (typo:
-- the actual table is named 'run'). Migration 017 still committed
-- its schema_version bump, so the relabel never ran and the legacy
-- 'tui' label kept surfacing on the admin's new Activity feed.

BEGIN;

-- Idempotent. Safe to re-run.
UPDATE run SET trigger = 'force' WHERE trigger = 'tui';

INSERT INTO state_meta (key, value) VALUES ('schema_version', '19')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
