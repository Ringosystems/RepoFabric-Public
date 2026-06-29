-- Migration 014 (linux fork): sync_queue table.
--
-- SQLite-backed priority queue for the parallel worker pool in
-- Private/Queue/. Persisted so pending requests survive a container
-- restart. Workers SELECT the highest-priority pending row, atomically
-- claim it via UPDATE ... WHERE state='pending', then run acquire +
-- build + publish for that subscription, then transition state to
-- 'completed' or 'failed'.

BEGIN;

CREATE TABLE IF NOT EXISTS sync_queue (
    queue_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id INTEGER NOT NULL,
    -- 0 = force-sync (operator clicked "Sync Now" in the GUI)
    -- 50 = manual (operator triggered Sync All)
    -- 100 = scheduled (cron-driven via Sync-RfSubscriptions -Trigger scheduled)
    priority        INTEGER NOT NULL,
    state           TEXT NOT NULL CHECK (state IN ('pending','running','completed','failed','cancelled')),
    requested_at    TEXT NOT NULL,
    -- Set when a worker claims the row. NULL while pending.
    started_at      TEXT,
    completed_at    TEXT,
    -- Worker identity for diagnostics (worker_<n>).
    worker_id       TEXT,
    -- Last error captured on failure.
    failure_message TEXT,
    -- Optional reason / trigger string for audit (manual, scheduled, force).
    trigger         TEXT
);

CREATE INDEX IF NOT EXISTS ix_sync_queue_state_priority
    ON sync_queue (state, priority, requested_at);

CREATE INDEX IF NOT EXISTS ix_sync_queue_subscription
    ON sync_queue (subscription_id, state);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '14')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
