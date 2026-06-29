-- RepoFabric v0.3.0 — initial schema (migration 001).
-- Applied idempotently by Invoke-RfStateMigration on every database open.
-- Schema source-of-truth: spec/DataModel.md.
--
-- Conventions:
--   * Timestamps: TEXT in ISO 8601 with 'Z' suffix (UTC).
--   * Boolean: INTEGER 0/1.
--   * JSON arrays/objects: TEXT (parsed by the PS layer).
--   * Identities: TEXT in "DOMAIN\username" form.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------- state_meta ----------
-- Schema version tracking and other system-internal metadata.
CREATE TABLE IF NOT EXISTS state_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- ---------- subscription ----------
CREATE TABLE IF NOT EXISTS subscription (
    subscription_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id        TEXT    NOT NULL,
    track             TEXT    NOT NULL CHECK (track IN ('latest', 'pinned')),
    pinned_version    TEXT,
    arch_policy       TEXT    NOT NULL,                              -- JSON array
    locale_policy     TEXT    NOT NULL,                              -- JSON array
    retention         INTEGER NOT NULL DEFAULT 2 CHECK (retention >= 1),
    notes             TEXT    NOT NULL DEFAULT '',
    notes_modified_by TEXT,
    notes_modified_at TEXT,
    created_by        TEXT    NOT NULL,
    created_at        TEXT    NOT NULL,
    modified_by       TEXT    NOT NULL,
    modified_at       TEXT    NOT NULL,
    pinned_by         TEXT,
    pinned_at         TEXT,
    UNIQUE (package_id, track, pinned_version)
);

CREATE INDEX IF NOT EXISTS idx_subscription_package_id ON subscription (package_id);

-- ---------- upstream_index ----------
CREATE TABLE IF NOT EXISTS upstream_index (
    package_id        TEXT    NOT NULL,
    version           TEXT    NOT NULL,
    publisher         TEXT,
    package_name      TEXT,
    short_description TEXT,
    license           TEXT,
    manifest_path     TEXT    NOT NULL,
    installer_types   TEXT,                                          -- JSON array
    architectures     TEXT,                                          -- JSON array
    locales           TEXT,                                          -- JSON array
    first_seen_at     TEXT    NOT NULL,
    last_seen_at      TEXT    NOT NULL,
    upstream_sha      TEXT    NOT NULL,
    PRIMARY KEY (package_id, version)
);

CREATE INDEX IF NOT EXISTS idx_upstream_index_package_id ON upstream_index (package_id);
CREATE INDEX IF NOT EXISTS idx_upstream_index_publisher ON upstream_index (publisher);

-- ---------- upstream_index_meta ----------
-- Tracks the index refresh state separate from row-level data.
CREATE TABLE IF NOT EXISTS upstream_index_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- ---------- acquisition ----------
CREATE TABLE IF NOT EXISTS acquisition (
    acquisition_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id       INTEGER NOT NULL REFERENCES subscription(subscription_id),
    package_id            TEXT    NOT NULL,
    version               TEXT    NOT NULL,
    manifest_path         TEXT    NOT NULL,
    upstream_sha          TEXT    NOT NULL,
    installer_url         TEXT    NOT NULL,
    declared_sha256       TEXT    NOT NULL,
    computed_sha256       TEXT,
    local_path            TEXT,
    architecture          TEXT    NOT NULL,
    locale                TEXT    NOT NULL,
    installer_type        TEXT,
    scope                 TEXT,
    file_size_bytes       INTEGER,
    download_started_at   TEXT    NOT NULL,
    download_completed_at TEXT,
    outcome               TEXT    NOT NULL CHECK (outcome IN
                                ('success', 'failed_download', 'failed_hash_mismatch', 'in_progress')),
    failure_message       TEXT,
    tool_version          TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_acquisition_subscription ON acquisition (subscription_id);
CREATE INDEX IF NOT EXISTS idx_acquisition_package_version ON acquisition (package_id, version);

-- ---------- transformation ----------
CREATE TABLE IF NOT EXISTS transformation (
    transformation_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id           INTEGER NOT NULL REFERENCES subscription(subscription_id),
    package_id                TEXT    NOT NULL,
    version                   TEXT    NOT NULL,
    transformed_manifest_path TEXT    NOT NULL,
    arch_fallback_applied     INTEGER NOT NULL DEFAULT 0,
    validate_exit_code        INTEGER,
    validate_stdout           TEXT,
    validate_stderr           TEXT,
    transformed_at            TEXT    NOT NULL,
    outcome                   TEXT    NOT NULL CHECK (outcome IN
                                    ('success', 'failed_validation', 'failed_filter')),
    failure_message           TEXT
);

CREATE INDEX IF NOT EXISTS idx_transformation_subscription ON transformation (subscription_id);

-- ---------- publication ----------
CREATE TABLE IF NOT EXISTS publication (
    publication_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id   INTEGER NOT NULL REFERENCES subscription(subscription_id),
    transformation_id INTEGER NOT NULL REFERENCES transformation(transformation_id),
    package_id        TEXT    NOT NULL,
    version           TEXT    NOT NULL,
    architectures     TEXT    NOT NULL,                              -- JSON array
    locales           TEXT    NOT NULL,                              -- JSON array
    total_size_bytes  INTEGER NOT NULL,
    notes             TEXT    NOT NULL DEFAULT '',
    notes_modified_by TEXT,
    notes_modified_at TEXT,
    published_by      TEXT    NOT NULL,
    published_at      TEXT    NOT NULL,
    outcome           TEXT    NOT NULL CHECK (outcome IN ('success', 'failed', 'rolled_back')),
    failure_message   TEXT,
    UNIQUE (subscription_id, version)
);

CREATE INDEX IF NOT EXISTS idx_publication_subscription ON publication (subscription_id);
CREATE INDEX IF NOT EXISTS idx_publication_package_version ON publication (package_id, version);

-- ---------- run ----------
CREATE TABLE IF NOT EXISTS run (
    run_id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at                TEXT    NOT NULL,
    completed_at              TEXT,
    trigger                   TEXT    NOT NULL,
    dry_run                   INTEGER NOT NULL DEFAULT 0,
    subscriptions_total       INTEGER,
    subscriptions_changed     INTEGER,
    subscriptions_skipped     INTEGER,
    subscriptions_failed      INTEGER,
    outcome                   TEXT    CHECK (outcome IN ('success', 'partial', 'failed', 'in_progress')),
    notes                     TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_run_started ON run (started_at);
CREATE INDEX IF NOT EXISTS idx_run_outcome ON run (outcome);

-- ---------- run_event ----------
CREATE TABLE IF NOT EXISTS run_event (
    event_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id            INTEGER NOT NULL REFERENCES run(run_id),
    subscription_id   INTEGER REFERENCES subscription(subscription_id),
    phase             TEXT    NOT NULL,
    package_id        TEXT,
    from_version      TEXT,
    to_version        TEXT,
    outcome           TEXT    NOT NULL,
    error_message     TEXT,
    duration_ms       INTEGER,
    event_at          TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_run_event_run ON run_event (run_id);
CREATE INDEX IF NOT EXISTS idx_run_event_subscription ON run_event (subscription_id);

-- ---------- notification ----------
CREATE TABLE IF NOT EXISTS notification (
    notification_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id               INTEGER REFERENCES run(run_id),
    sent_at              TEXT    NOT NULL,
    category             TEXT    NOT NULL CHECK (category IN
                            ('changes', 'failure', 'heartbeat', 'index_failure',
                             'stale_task', 'all_clear', 'test')),
    severity             TEXT    NOT NULL CHECK (severity IN ('info', 'error')),
    subject              TEXT    NOT NULL,
    recipients           TEXT    NOT NULL,                           -- JSON array
    body_size_bytes      INTEGER,
    smtp_outcome         TEXT    NOT NULL CHECK (smtp_outcome IN ('delivered', 'failed')),
    smtp_failure_message TEXT
);

CREATE INDEX IF NOT EXISTS idx_notification_sent ON notification (sent_at);
CREATE INDEX IF NOT EXISTS idx_notification_category ON notification (category);

-- ---------- publication_notes_archive ----------
-- Populated only when notifications.notes_survive_retention is true in config.
CREATE TABLE IF NOT EXISTS publication_notes_archive (
    archive_id              INTEGER PRIMARY KEY AUTOINCREMENT,
    original_publication_id INTEGER NOT NULL,
    package_id              TEXT    NOT NULL,
    version                 TEXT    NOT NULL,
    notes                   TEXT    NOT NULL,
    notes_modified_by       TEXT,
    notes_modified_at       TEXT,
    published_by            TEXT,
    published_at            TEXT,
    archived_at             TEXT    NOT NULL,
    archived_by_run_id      INTEGER REFERENCES run(run_id)
);

CREATE INDEX IF NOT EXISTS idx_archive_package_version ON publication_notes_archive (package_id, version);

-- ---------- Bookmark this migration ----------
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('schema_version', '1');
INSERT OR REPLACE INTO state_meta (key, value) VALUES ('initial_migration_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
