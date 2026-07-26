-- Migration 042 (linux fork): ingest client registry + transport audit.
--
-- RENUMBERED from 037 to 042. It originally shipped as a SECOND file numbered
-- 037, colliding with 037-rename-gitea-repo-publisher.sql (which reached main
-- three weeks earlier, in #145). The runner reads schema_version ONCE before its
-- loop and skips any file whose prefix is <= that value, so ANY database that had
-- been migrated while main carried the rename file but not this one sat at exactly
-- 37 and then skipped BOTH 037 files forever. Such a database climbs to 41 and
-- looks perfectly healthy in state_meta -- identical schema_version, and the
-- shared migration_037_at marker written by the other file -- while ingest_client
-- and ingest_event DO NOT EXIST. Nothing errors, because 038-041 never reference
-- them, so -bail never fires. The visible symptom is every RFIP call 401ing (the
-- token lookup's catch is empty) and New-RfIngestClient dying on
-- "no such table: ingest_client".
--
-- Renumbering above the current maximum makes stranded databases pick this up on
-- their next boot. Every statement here is CREATE TABLE/INDEX IF NOT EXISTS, so
-- re-applying it to a database that already got it as 037 is a no-op.
--
-- Introduces the RepoFabric Ingest Protocol (RFIP) trust store. An ingest
-- client is an external system (first consumer: Kamino) permitted to publish /
-- change / delete WinGet apps and binaries over the /api/v1/ingest/* surface.
--
-- Two-factor, both anchored on THIS one row so revocation is atomic:
--   * bearer factor    -> key_prefix + key_salt + key_hash (salted SHA-256;
--                         the plaintext token is shown once at issuance and
--                         never stored). Looked up by key_prefix, compared
--                         constant-time (Test-RfConstantTimeEqual).
--   * signature factor -> public_key_spki (RFC 9421 ECDSA P-256). Unlike the
--                         root-signed fabric-trust.json bundle, ingest client
--                         keys live HERE, so Test-RfIngestSignature resolves
--                         the verify key from the row and gates it on
--                         status='active'. One UPDATE status='revoked' kills
--                         BOTH factors (bearer lookup stops matching AND the
--                         key resolver returns nothing) with no key ceremony.
--
-- ingest_event is the per-client transport ledger. It captures every inbound
-- ingest call INCLUDING rejected ones (revoked / bad-signature / repo not
-- allowed / gate-denied) that never reach a publish, plus per-call bytes and
-- the signature verdict. publish_events only records SUCCESSFUL catalog
-- mutations and admin_event records OPERATOR actions, so neither can hold this;
-- the machine-to-machine transport ledger is a genuinely separate concern.
--
-- Operator-driven management of clients (register / rotate / suspend /
-- reactivate / revoke) is NOT stored here: it reuses admin_event via
-- Write-RfAdminEvent (event types ingest_client_*), so it flows into the
-- existing Activity feed attributed to the operator UPN.

BEGIN;

CREATE TABLE IF NOT EXISTS ingest_client (
    client_id            TEXT PRIMARY KEY,        -- slug [a-z0-9-]+; doubles as the RFC 9421 keyid
    display_name         TEXT NOT NULL,
    owner_contact        TEXT,                    -- team / email, operator convenience only

    status               TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','suspended','revoked')),

    -- Bearer factor (plaintext token NEVER stored).
    key_prefix           TEXT NOT NULL,           -- indexed lookup handle, e.g. rfk_kamino_a1b2c3
    key_last4            TEXT NOT NULL,           -- display only
    key_salt             TEXT NOT NULL,           -- base64, 16 random bytes
    key_hash             TEXT NOT NULL,           -- base64( SHA-256(salt || token) )
    key_issued_at        TEXT NOT NULL,
    key_issued_by        TEXT NOT NULL,           -- operator UPN
    key_version          INTEGER NOT NULL DEFAULT 1,

    -- Signature factor (RFC 9421 P-256 pinned key; this table is the trust store).
    public_key_spki      TEXT NOT NULL,           -- base64 SPKI DER (same encoding as fabric-trust.json)
    public_key_alg       TEXT NOT NULL DEFAULT 'ecdsa-p256-sha256',
    public_key_fp        TEXT NOT NULL,           -- SHA-256 fingerprint hex, for UI display + out-of-band confirmation
    key_source           TEXT NOT NULL DEFAULT 'client_supplied'
                          CHECK (key_source IN ('client_supplied','repofabric_issued')),

    -- Authorization.
    allowed_repos_json   TEXT NOT NULL DEFAULT '[]',   -- per-client allow-list of EXISTING repo slugs
    capabilities_json    TEXT NOT NULL DEFAULT '["package:write"]',

    -- Lifecycle / audit.
    created_at           TEXT NOT NULL,
    created_by           TEXT NOT NULL,
    last_used_at         TEXT,
    revoked_at           TEXT,
    revoked_by           TEXT,
    revoked_reason       TEXT
);

-- key_prefix is the hot-path lookup: the auth layer extracts the prefix from a
-- presented token, does ONE indexed read, then a single constant-time compare
-- (never a table scan of hashes). UNIQUE so a prefix collision is impossible.
CREATE UNIQUE INDEX IF NOT EXISTS ux_ingest_client_prefix ON ingest_client (key_prefix);
CREATE INDEX IF NOT EXISTS ix_ingest_client_status ON ingest_client (status);

CREATE TABLE IF NOT EXISTS ingest_event (
    ingest_event_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id           TEXT NOT NULL,           -- correlation id echoed to the client
    client_id            TEXT,                    -- NULL when auth failed before a client resolved
    verb                 TEXT NOT NULL,           -- publish | update | delete | discover | stage
    method               TEXT NOT NULL,           -- HTTP method
    path                 TEXT NOT NULL,
    repo_id              TEXT,
    package_id           TEXT,
    package_version      TEXT,
    outcome              TEXT NOT NULL            -- accepted | rejected
                          CHECK (outcome IN ('accepted','rejected')),
    http_status          INTEGER NOT NULL,
    reject_reason        TEXT,                    -- revoked | bad_signature | repo_not_allowed | deletion_gate_denied | ...
    sig_verdict          TEXT,                    -- 'ok' or a Test-RfMessageSignature reason string; never signature bytes
    bytes_in             INTEGER NOT NULL DEFAULT 0,
    publish_event_id     INTEGER REFERENCES publish_events(publish_event_id),  -- links the ledger row on success
    created_at           TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_ingest_event_client_time ON ingest_event (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_ingest_event_time        ON ingest_event (created_at DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '42')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_042_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
