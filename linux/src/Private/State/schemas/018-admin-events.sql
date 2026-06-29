-- Migration 018 (linux fork): admin_event table.
--
-- Captures operator-driven admin actions (subscription add/edit/remove,
-- custom-package publish/edit/remove, config save, setup completion) so
-- the admin UI's Activity tab can surface them alongside the existing
-- runs table.
--
-- Why a separate table from runs:
--   * runs has a fixed (kind, trigger, status, count_*) shape that fits
--     sync/cleanup/index-refresh, but does not fit "operator added a
--     subscription" without contorting the columns.
--   * Keeping admin actions in their own table lets us evolve the
--     schema (more event types, structured detail) without touching the
--     sync run audit shape.
--   * /api/activity unions both tables and normalises into one wire
--     shape for the UI.

BEGIN;

CREATE TABLE IF NOT EXISTS admin_event (
    event_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type  TEXT NOT NULL,           -- e.g. subscription_added, custom_published, config_saved
    subject     TEXT,                    -- PackageId, subscription_id, section name; null for global events
    actor       TEXT,                    -- UPN or 'repofabric@<host>' for cron-driven events
    outcome     TEXT NOT NULL DEFAULT 'succeeded',  -- succeeded | failed | partial
    detail_json TEXT,                    -- arbitrary JSON payload, never indexed
    created_at  TEXT NOT NULL            -- ISO-8601 UTC ('YYYY-MM-DDTHH:MM:SSZ')
);

-- Activity tab queries by created_at DESC LIMIT N; the index keeps that
-- fast as the table grows.
CREATE INDEX IF NOT EXISTS idx_admin_event_created
    ON admin_event (created_at DESC);

-- Secondary index for the "filter by event type" chip on the UI.
CREATE INDEX IF NOT EXISTS idx_admin_event_type_created
    ON admin_event (event_type, created_at DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '18')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
