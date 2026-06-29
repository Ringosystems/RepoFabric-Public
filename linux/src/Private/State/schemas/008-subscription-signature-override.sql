-- Migration 008: per-subscription signature_policy override.
--
-- The global acquire.signature_policy setting now defaults to 'require' so
-- that unsigned/invalid installers are rejected by default. Some packages
-- (e.g. 7-Zip, which ships unsigned for cost reasons) need an explicit
-- per-subscription override to be publishable.
--
-- New column on subscription:
--   signature_policy_override TEXT NULL
--     NULL      -> use acquire.signature_policy from config (default)
--     'ignore'  -> record status but never block this subscription
--     'warn'    -> record + log warning on anything other than 'Valid'
--     'require' -> fail acquisition on anything other than 'Valid'
--
-- The override applies only to the subscription that carries it. There is no
-- merge/inherit logic: any non-NULL value wins outright.

ALTER TABLE subscription ADD COLUMN signature_policy_override TEXT;

-- Each migration is responsible for bumping the recorded schema_version.
-- See 001..007 for the convention. The migrator does NOT auto-bump.
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '8');
