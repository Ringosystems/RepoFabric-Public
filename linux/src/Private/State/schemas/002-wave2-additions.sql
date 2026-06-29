-- RepoFabric v0.3.0 — Wave 2-5 schema additions (migration 002).
--
-- Purely additive over 001-initial. No renames, drops, or data migrations;
-- safe to run on any 001-applied database.
--
-- Why these additions?
--   The Wave 1 schema modeled what we'd need for end-to-end ingestion. Waves
--   2-5 require additional bookkeeping for: per-subscription filter rules,
--   per-run actor/status attribution, free-form event messages, parallel-path
--   email suppression, and structured publication notes (vs. the single-text
--   note column on publication).

PRAGMA foreign_keys = ON;

-- ---------- subscription additions ----------
ALTER TABLE subscription ADD COLUMN scope_filter            TEXT    NOT NULL DEFAULT '';
ALTER TABLE subscription ADD COLUMN installer_type_filter   TEXT    NOT NULL DEFAULT '';
ALTER TABLE subscription ADD COLUMN keep_last               INTEGER NOT NULL DEFAULT 2;
ALTER TABLE subscription ADD COLUMN notes_survive_retention INTEGER NOT NULL DEFAULT 1;

-- ---------- run additions ----------
-- Wave 1 captured per-run aggregates; Wave 2-5 needs attribution and
-- success vs change distinction.
ALTER TABLE run ADD COLUMN kind            TEXT;
ALTER TABLE run ADD COLUMN actor           TEXT;
ALTER TABLE run ADD COLUMN status          TEXT;
ALTER TABLE run ADD COLUMN started_utc     TEXT;
ALTER TABLE run ADD COLUMN ended_utc       TEXT;
ALTER TABLE run ADD COLUMN count_succeeded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE run ADD COLUMN count_failed    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE run ADD COLUMN count_skipped   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE run ADD COLUMN count_changed   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE run ADD COLUMN summary         TEXT    NOT NULL DEFAULT '';

-- A view to expose the simpler "id" alias used by Wave 2-5 cmdlets.
CREATE VIEW IF NOT EXISTS v_run AS
    SELECT
        run_id              AS id,
        kind,
        trigger,
        actor,
        COALESCE(status, outcome) AS status,
        COALESCE(started_utc, started_at)  AS started_utc,
        COALESCE(ended_utc,   completed_at) AS ended_utc,
        count_succeeded,
        count_failed,
        count_skipped,
        count_changed,
        summary
    FROM run;

-- ---------- run_event additions ----------
ALTER TABLE run_event ADD COLUMN message     TEXT    NOT NULL DEFAULT '';
ALTER TABLE run_event ADD COLUMN detail_json TEXT;
ALTER TABLE run_event ADD COLUMN created_utc TEXT;

-- ---------- notification_state ----------
-- One row per active stale-schedule alert signature; used for 24h suppression
-- and all-clear bookkeeping by Send-RfStaleScheduleAlert.
CREATE TABLE IF NOT EXISTS notification_state (
    signature      TEXT PRIMARY KEY,
    severity       TEXT NOT NULL,
    last_sent_utc  TEXT NOT NULL,
    message        TEXT NOT NULL DEFAULT ''
);

-- ---------- publication_notes ----------
-- Structured notes attached to a publication (multi-row).
-- The flat publication.notes field from Wave 1 is retained as a "current note"
-- summary; this table captures the audit trail.
CREATE TABLE IF NOT EXISTS publication_notes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    publication_id  INTEGER NOT NULL REFERENCES publication(publication_id),
    note            TEXT    NOT NULL,
    note_author     TEXT    NOT NULL,
    created_utc     TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_publication_notes_pub ON publication_notes (publication_id);

-- ---------- bookmark ----------
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '2');
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('migration_002_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
