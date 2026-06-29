-- Migration 030: Gitea archive tables (RepoFabric 0.8.0 Phase D.6).
--
-- Goal: SQLite holds a byte-perfect copy of every commit reachable from
-- HEAD of every virtual repo's manifest tree. If Gitea's volume is
-- nuked, Restore-RfGiteaFromArchive (Phase D.7) can reconstruct each
-- repo from these tables alone -- no remote, no backup tarball.
--
-- The design is content-addressed: a blob's primary key is the SHA-256
-- of its raw bytes, so identical YAML content across versions stores
-- once. A commit references its blobs via gitea_archive_files. A
-- snapshot records "as of this moment, HEAD of repo X was commit Y";
-- snapshots are taken on every publish, every drift capture, and once
-- per day so we have multiple recovery points.
--
-- Tables are append-only by convention. UPDATE / DELETE triggers that
-- block edits land in a later commit alongside the retention story;
-- for now the call sites (Save-RfGiteaArchiveCommit and
-- New-RfGiteaArchiveSnapshot) are the sole writers.

BEGIN;

-- Raw blob storage. content_sha256 is the deduplication key.
-- content_text holds the YAML content as text (the manifest tree is
-- entirely UTF-8 YAML, never binary), so SQLite full-text indexing
-- and grep stays trivial.
CREATE TABLE IF NOT EXISTS gitea_archive_blobs (
    content_sha256    TEXT    PRIMARY KEY,
    content_text      TEXT    NOT NULL,
    content_size      INTEGER NOT NULL,
    first_seen_utc    TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_gitea_archive_blobs_size
    ON gitea_archive_blobs (content_size);

-- Commit metadata. parent_shas_json lets us reconstruct the DAG
-- without joining a separate parents table; the archive is
-- write-once, so a JSON list is simpler than a normalised edge
-- table. tree_sha records Gitea's tree hash so a future restore
-- can cross-check the reconstructed tree.
CREATE TABLE IF NOT EXISTS gitea_archive_commits (
    commit_sha            TEXT    PRIMARY KEY,
    repo_id               TEXT    NOT NULL,
    parent_shas_json      TEXT    NOT NULL DEFAULT '[]',
    tree_sha              TEXT,

    author_name           TEXT,
    author_email          TEXT,
    author_date_utc       TEXT,
    committer_name        TEXT,
    committer_email       TEXT,
    committer_date_utc    TEXT,
    message               TEXT,

    source                TEXT    NOT NULL
                          CHECK (source IN ('publish','promote','revert','drift_captured','snapshot_backfill','restore')),
    archived_at_utc       TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_gitea_archive_commits_repo
    ON gitea_archive_commits (repo_id, archived_at_utc DESC);
CREATE INDEX IF NOT EXISTS ix_gitea_archive_commits_source
    ON gitea_archive_commits (source);

-- File-in-commit join. (commit_sha, file_path) uniquely identifies
-- a tree leaf; content_sha256 points at the actual bytes in
-- gitea_archive_blobs. mode is the unix file mode (e.g. '100644'
-- for normal files) so a restore can preserve permissions if needed.
CREATE TABLE IF NOT EXISTS gitea_archive_files (
    commit_sha       TEXT    NOT NULL REFERENCES gitea_archive_commits(commit_sha),
    file_path        TEXT    NOT NULL,
    content_sha256   TEXT    NOT NULL REFERENCES gitea_archive_blobs(content_sha256),
    mode             TEXT    NOT NULL DEFAULT '100644',
    PRIMARY KEY (commit_sha, file_path)
);

CREATE INDEX IF NOT EXISTS ix_gitea_archive_files_blob
    ON gitea_archive_files (content_sha256);
CREATE INDEX IF NOT EXISTS ix_gitea_archive_files_path
    ON gitea_archive_files (file_path);

-- Snapshot ledger. One row per recovery point; head_commit_sha is the
-- restore target. branch_refs_json reserved for future multi-branch
-- snapshots, populated with {"main": "<head_sha>"} for now.
CREATE TABLE IF NOT EXISTS gitea_archive_snapshots (
    snapshot_id           INTEGER PRIMARY KEY AUTOINCREMENT,
    repo_id               TEXT    NOT NULL,
    taken_at_utc          TEXT    NOT NULL,
    head_commit_sha       TEXT    NOT NULL REFERENCES gitea_archive_commits(commit_sha),
    branch_refs_json      TEXT    NOT NULL DEFAULT '{}',

    reason                TEXT    NOT NULL
                          CHECK (reason IN ('publish','promote','drift','daily','manual','pre_upgrade','restore_verification')),
    trigger_event_id      INTEGER,
    commit_count          INTEGER NOT NULL DEFAULT 0,
    blob_count            INTEGER NOT NULL DEFAULT 0,
    total_size_bytes      INTEGER NOT NULL DEFAULT 0,
    notes                 TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS ix_gitea_archive_snapshots_repo_time
    ON gitea_archive_snapshots (repo_id, taken_at_utc DESC);
CREATE INDEX IF NOT EXISTS ix_gitea_archive_snapshots_reason
    ON gitea_archive_snapshots (reason);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '30')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
