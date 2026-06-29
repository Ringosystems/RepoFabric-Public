-- @repofabric:disable-foreign-keys
-- @repofabric:legacy-alter-table
--
-- Migration 010: Widen the CHECK constraint on acquisition.outcome.
--
-- Migration 006 added signature columns and the verifier code (in
-- Invoke-RfAcquire.ps1) emits two outcomes that were never in the
-- original Wave 1 allow-list:
--    failed_signature_invalid
--    failed_signature_disallowed
--
-- Without this migration, any sync of a subscription whose installer
-- fails Authenticode validation under policy 'require' (or whose signer
-- is not on the allowed_signers list) raises:
--    "CHECK constraint failed: acquisition"
-- at the INSERT in Invoke-RfAcquire.ps1.
--
-- SQLite does not support ALTER on CHECK constraints, so this rebuilds
-- the table preserving all rows and indexes. Per the same pattern as
-- migration 003 (consolidate-run), we toggle foreign_keys = OFF and
-- legacy_alter_table = ON around the rebuild.

ALTER TABLE acquisition RENAME TO _acquisition_old;

CREATE TABLE acquisition (
    acquisition_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id             INTEGER NOT NULL REFERENCES subscription(subscription_id),
    package_id                  TEXT    NOT NULL,
    version                     TEXT    NOT NULL,
    manifest_path               TEXT    NOT NULL,
    upstream_sha                TEXT    NOT NULL,
    installer_url               TEXT    NOT NULL,
    declared_sha256             TEXT    NOT NULL,
    computed_sha256             TEXT,
    local_path                  TEXT,
    architecture                TEXT    NOT NULL,
    locale                      TEXT    NOT NULL,
    installer_type              TEXT,
    scope                       TEXT,
    file_size_bytes             INTEGER,
    download_started_at         TEXT    NOT NULL,
    download_completed_at       TEXT,
    outcome                     TEXT    NOT NULL CHECK (outcome IN
                                    ('success',
                                     'in_progress',
                                     'failed_download',
                                     'failed_hash_mismatch',
                                     'failed_signature_invalid',
                                     'failed_signature_disallowed')),
    failure_message             TEXT,
    tool_version                TEXT    NOT NULL,
    signature_status            TEXT,
    signature_signer_subject    TEXT,
    signature_signer_thumbprint TEXT,
    signature_policy            TEXT,
    signature_chain_json        TEXT,
    signature_chain_thumbprints TEXT,
    signature_revocation_status TEXT,
    signature_revocation_reason TEXT,
    signature_allowlist_verdict TEXT
);

INSERT INTO acquisition (
    acquisition_id, subscription_id, package_id, version, manifest_path, upstream_sha,
    installer_url, declared_sha256, computed_sha256, local_path,
    architecture, locale, installer_type, scope, file_size_bytes,
    download_started_at, download_completed_at, outcome, failure_message, tool_version,
    signature_status, signature_signer_subject, signature_signer_thumbprint, signature_policy,
    signature_chain_json, signature_chain_thumbprints,
    signature_revocation_status, signature_revocation_reason, signature_allowlist_verdict)
SELECT
    acquisition_id, subscription_id, package_id, version, manifest_path, upstream_sha,
    installer_url, declared_sha256, computed_sha256, local_path,
    architecture, locale, installer_type, scope, file_size_bytes,
    download_started_at, download_completed_at, outcome, failure_message, tool_version,
    signature_status, signature_signer_subject, signature_signer_thumbprint, signature_policy,
    signature_chain_json, signature_chain_thumbprints,
    signature_revocation_status, signature_revocation_reason, signature_allowlist_verdict
FROM _acquisition_old;

DROP TABLE _acquisition_old;

CREATE INDEX IF NOT EXISTS idx_acquisition_subscription ON acquisition (subscription_id);
CREATE INDEX IF NOT EXISTS idx_acquisition_package_version ON acquisition (package_id, version);

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '10');
INSERT OR REPLACE INTO state_meta (key, value)
    VALUES ('migration_010_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
