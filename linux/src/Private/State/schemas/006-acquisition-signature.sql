-- Migration 006: Authenticode signature columns on acquisition.
--
-- v0.5 Phase 2 adds an Authenticode verification step after SHA-256
-- check inside Invoke-RfAcquire. The result of that check is recorded
-- on the acquisition row so the publish path (and run reports) can
-- consult it without re-running Get-AuthenticodeSignature.
--
-- Columns:
--   signature_status            normalized status:
--                               Valid | HashMismatch | NotSigned | NotTrusted |
--                               Expired | UnknownError | NotChecked
--   signature_signer_subject    signer cert Subject ('CN=..., O=..., ...'), nullable
--   signature_signer_thumbprint signer cert SHA-1 thumbprint, nullable
--   signature_policy            policy in effect at acquisition time:
--                               ignore | warn | require
--
-- The 'NotChecked' status records rows acquired before this migration
-- existed; rows inserted by code that has run migration 006 always set
-- one of the verifier-emitted statuses.

ALTER TABLE acquisition ADD COLUMN signature_status            TEXT;
ALTER TABLE acquisition ADD COLUMN signature_signer_subject    TEXT;
ALTER TABLE acquisition ADD COLUMN signature_signer_thumbprint TEXT;
ALTER TABLE acquisition ADD COLUMN signature_policy            TEXT;

UPDATE acquisition SET signature_status = 'NotChecked' WHERE signature_status IS NULL;

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '6');
