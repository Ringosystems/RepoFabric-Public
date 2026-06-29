-- Migration 007: Authenticode chain + revocation + signer allowlist outcome.
--
-- v0.6 Phase 3 extends the Authenticode verifier to walk the full certificate
-- chain (X509Chain with RevocationFlag=EntireChain) and records the result on
-- the acquisition row. It also captures the verdict of the per-subscription
-- signer allowlist (acquire.allowed_signers) so reports can distinguish
-- "signature is valid but the publisher is not on this subscription's allowlist"
-- from a plain signature failure.
--
-- New columns on acquisition:
--   signature_chain_json          JSON array of {subject, issuer, thumbprint,
--                                 notBefore, notAfter}, leaf first. Nullable
--                                 when no chain could be built.
--   signature_chain_thumbprints   JSON array of thumbprints (leaf -> root),
--                                 denormalized for fast querying. Nullable.
--   signature_revocation_status   one of:
--                                   NotChecked       — verifier did not check
--                                   NotRevoked       — chain verified online
--                                   Revoked          — at least one cert revoked
--                                   Unknown          — CRL/OCSP fetch failed
--                                   OfflineFallback  — fell back to cached/offline
--                                                      list (policy:
--                                                      online_with_offline_fallback)
--   signature_revocation_reason   verbose chain status string (X509ChainStatus
--                                 joined with '; '), nullable
--   signature_allowlist_verdict   one of:
--                                   not_configured   — allowed_signers empty
--                                   allowed          — leaf matched a rule
--                                   disallowed       — leaf did not match
--                                   skipped_unsigned — signature was not Valid;
--                                                      allowlist not evaluated
--
-- The new columns are nullable; rows written by v0.5 code remain valid.

ALTER TABLE acquisition ADD COLUMN signature_chain_json         TEXT;
ALTER TABLE acquisition ADD COLUMN signature_chain_thumbprints  TEXT;
ALTER TABLE acquisition ADD COLUMN signature_revocation_status  TEXT;
ALTER TABLE acquisition ADD COLUMN signature_revocation_reason  TEXT;
ALTER TABLE acquisition ADD COLUMN signature_allowlist_verdict  TEXT;

UPDATE acquisition
   SET signature_revocation_status = 'NotChecked'
 WHERE signature_revocation_status IS NULL;

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '7');
