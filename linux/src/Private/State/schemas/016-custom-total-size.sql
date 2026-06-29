-- Migration 016 (linux fork): record total installer size per custom package.
--
-- The combined Subscriptions tab Custom apps section surfaces the
-- size column for parity with managed subscriptions. Compute the value
-- in Publish-RfCustomPackage by summing InstallerUploads[].SizeBytes.

BEGIN;

ALTER TABLE custom_packages ADD COLUMN total_size_bytes INTEGER;

INSERT INTO state_meta (key, value) VALUES ('schema_version', '16')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
