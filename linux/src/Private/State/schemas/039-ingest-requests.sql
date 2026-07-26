-- Migration 039 (linux fork): RFIP idempotency side table.
--
-- The RepoFabric Ingest Protocol requires an idempotencyKey on every mutating
-- call. This table gives the exactly-once contract independent of the
-- publish_events natural-key dedup:
--   * same idempotency_key + same request_sha256 -> return the stored response
--     verbatim (a safe retry / replay; 200).
--   * same idempotency_key + DIFFERENT request_sha256 -> 409 conflict (the key
--     was reused for a different payload, which is a client bug).
-- The stored response_json lets a retried create return the same 201 body
-- (custom_id, commit sha, ...) without re-running the publish pipeline.

BEGIN;

CREATE TABLE IF NOT EXISTS ingest_requests (
    idempotency_key   TEXT PRIMARY KEY,
    client_id         TEXT,
    verb              TEXT NOT NULL,           -- publish | update | delete
    repo_id           TEXT,
    package_id        TEXT,
    package_version   TEXT,
    request_sha256    TEXT NOT NULL,           -- hex SHA-256 of the RAW request body bytes (byte-exact; a safe retry must resend a byte-identical body)
    publish_event_id  INTEGER REFERENCES publish_events(publish_event_id),
    http_status       INTEGER NOT NULL,
    response_json     TEXT,                    -- stored response body for verbatim replay
    created_at        TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_ingest_requests_client ON ingest_requests (client_id, created_at DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '39')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO state_meta (key, value) VALUES ('migration_039_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
