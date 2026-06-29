-- Migration 032: source_fabric discriminator on publish_events
-- (RepoFabric 0.8.0, M6 bolt-on groundwork; see Ringosystems/RepoFabric#4).
--
-- When ConfigFabric is bolted onto RepoFabric (sidecar-absorption), it
-- consolidates its publish/assign/revert/drift audit events onto this
-- ledger instead of running a parallel publish_events table of its own.
-- To keep one physical ledger while still telling the two fabrics apart
-- in the Activity feed, every row carries a source_fabric tag.
--
-- This migration is the verb-agnostic, default-off-safe substrate only:
--   * adds source_fabric with DEFAULT 'repofabric', so every existing row
--     (all RepoFabric-originated) backfills correctly and no current
--     reader or writer changes behavior.
--   * does NOT widen the event_type CHECK. ConfigFabric's 'assign' verb
--     and the drift-vs-drift_merged decision are still open on the
--     ConfigFabric side (Ringosystems/ConfigFabric#3), so adding those
--     values is deferred to a follow-up migration once the taxonomy is
--     frozen. Holding it here avoids a second table rebuild and avoids
--     committing to a verb set that may change.
--
-- ALTER TABLE ADD COLUMN is used rather than a table rebuild precisely
-- because we are only adding a column: the self-referential FKs
-- (reverted_by_event_id, promoted_from_event_id) and the AUTOINCREMENT
-- high-water mark are left untouched, which a rebuild would have to
-- reconstruct by hand. The constant default satisfies the CHECK for all
-- pre-existing rows.

BEGIN;

ALTER TABLE publish_events ADD COLUMN source_fabric TEXT NOT NULL DEFAULT 'repofabric'
    CHECK (source_fabric IN ('repofabric','configfabric'));

CREATE INDEX IF NOT EXISTS ix_publish_events_source_fabric
    ON publish_events (source_fabric);

-- ---------- Bookmark ----------
INSERT INTO state_meta (key, value) VALUES ('schema_version', '32')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_032_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
