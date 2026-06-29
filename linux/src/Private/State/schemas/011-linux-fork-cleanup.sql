-- @repofabric:disable-foreign-keys
-- Migration 011 (linux fork): drop Authenticode-related columns and add
-- UNIQUE constraints to subscription so that the path-based, no-cross-call
-- transaction model relies on schema enforcement instead of code-level
-- duplicate checks.

BEGIN;

-- 1. Drop the per-subscription signature override (Linux fork has no
--    signature verification at all).
ALTER TABLE subscription DROP COLUMN signature_policy_override;

-- 2. Drop the Authenticode columns from acquisition. SQLite 3.35+ supports
--    DROP COLUMN directly; the Debian 12 container image ships SQLite 3.40+.
ALTER TABLE acquisition DROP COLUMN signature_status;
ALTER TABLE acquisition DROP COLUMN signature_signer_subject;
ALTER TABLE acquisition DROP COLUMN signature_signer_thumbprint;
ALTER TABLE acquisition DROP COLUMN signature_policy;
ALTER TABLE acquisition DROP COLUMN signature_chain_json;
ALTER TABLE acquisition DROP COLUMN signature_chain_thumbprints;
ALTER TABLE acquisition DROP COLUMN signature_revocation_status;
ALTER TABLE acquisition DROP COLUMN signature_revocation_reason;
ALTER TABLE acquisition DROP COLUMN signature_allowlist_verdict;

-- 3. Enforce subscription uniqueness at the schema layer. Without
--    cross-call transactions, the racing duplicate-check-then-INSERT
--    in Add-RfSubscription needs schema-level backstop. The constraint
--    matches the Wave 1 invariant from REQ-SUB-006/007: at most one
--    'latest' subscription per package_id, and at most one 'pinned'
--    subscription per (package_id, pinned_version) tuple. We model this
--    as one unique index that treats NULL pinned_version as a literal
--    via COALESCE, so latest-track rows with pinned_version IS NULL all
--    collide on the same coalesced empty string per package_id.
DROP INDEX IF EXISTS ux_subscription_pkg_track_pin;
CREATE UNIQUE INDEX ux_subscription_pkg_track_pin
    ON subscription (package_id, track, COALESCE(pinned_version, ''));

-- Record version
INSERT INTO state_meta (key, value) VALUES ('schema_version', '11')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
