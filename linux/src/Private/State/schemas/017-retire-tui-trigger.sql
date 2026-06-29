-- Migration 017 (linux fork): rename the legacy 'tui' run trigger to 'force'.
--
-- Background: the Linux container has no TUI (it was a Windows-only
-- Terminal.Gui surface in the retired fork). The publisher's worker
-- pool was still tagging operator-driven force-sync runs with
-- trigger='tui' for historical compatibility, which surfaced in the
-- admin Runs table as a confusing label. New code emits 'force';
-- this migration relabels every historical row so the Runs view is
-- consistent.
--
-- NOTE (fresh-init fix): the original relabel statement here targeted a
-- table named 'runs', but the table is 'run' (singular, created in 001 and
-- rebuilt in 003). On already-deployed databases this errored soft -- the
-- relabel was skipped but the schema_version bump still committed -- so
-- migration 019 was added to re-apply the relabel against 'run' correctly.
-- Under the current sqlite3-CLI migration runner the bad statement instead
-- aborts the whole migration, which broke fresh initialisation from
-- schema_version 0 at this step. The relabel is intentionally removed here
-- (it is a historical no-op; 019 performs the real, idempotent relabel) so
-- 017 is a clean schema_version bump. Deployed databases are already past
-- 017 and never re-run it.

BEGIN;

-- (relabel intentionally not performed here; see the note above and 019.)

INSERT INTO state_meta (key, value) VALUES ('schema_version', '17')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
