-- @repofabric:disable-foreign-keys
-- @repofabric:legacy-alter-table
--
-- Migration 040: scope RFIP idempotency keys PER CLIENT.
--
-- Migration 039 made idempotency_key the sole PRIMARY KEY, so the idempotency
-- namespace was shared across every ingest client. Two independent tenants that
-- happen to use the same natural key (e.g. "publish-<pkgid>-<ver>" or a
-- sequential "req-001") would collide: a differing body yields a cross-client
-- 409 (one client's key blocks another's publish -> DoS), and a byte-identical
-- body would replay the OTHER client's stored response (wrong commit/event
-- metadata). Every other part of RFIP treats a client as an isolated tenant
-- (bearer, signature keyid, per-client allow-list), so idempotency must be
-- namespaced by client too.
--
-- Rebuild with a composite PK (client_id, idempotency_key) and client_id
-- NOT NULL. SQLite cannot ALTER a PRIMARY KEY in place; rebuild per the
-- migration 035 pattern (foreign_keys OFF + legacy_alter_table ON around a
-- rename / create / copy / drop). ingest_requests references publish_events, so
-- the FK-off directive avoids a cascade rewrite during the rename.
--
-- Legacy rows (client_id was nullable in 039) are backfilled to a '_legacy'
-- sentinel to satisfy the NOT NULL composite PK. Because idempotency_key was
-- itself unique under 039, (client_id, idempotency_key) is still unique after
-- the rebuild, so the copy cannot violate the new PK.

BEGIN;

ALTER TABLE ingest_requests RENAME TO _ingest_requests_old;

CREATE TABLE ingest_requests (
    client_id         TEXT NOT NULL,
    idempotency_key   TEXT NOT NULL,
    verb              TEXT NOT NULL,
    repo_id           TEXT,
    package_id        TEXT,
    package_version   TEXT,
    request_sha256    TEXT NOT NULL,
    publish_event_id  INTEGER REFERENCES publish_events(publish_event_id),
    http_status       INTEGER NOT NULL,
    response_json     TEXT,
    created_at        TEXT NOT NULL,
    PRIMARY KEY (client_id, idempotency_key)
);

INSERT INTO ingest_requests
    (client_id, idempotency_key, verb, repo_id, package_id, package_version,
     request_sha256, publish_event_id, http_status, response_json, created_at)
SELECT
    COALESCE(client_id, '_legacy'), idempotency_key, verb, repo_id, package_id, package_version,
    request_sha256, publish_event_id, http_status, response_json, created_at
FROM _ingest_requests_old;

DROP TABLE _ingest_requests_old;

CREATE INDEX IF NOT EXISTS ix_ingest_requests_client ON ingest_requests (client_id, created_at DESC);

INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '40');
INSERT OR REPLACE INTO state_meta (key, value)
    VALUES ('migration_040_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

COMMIT;
