-- Migration 027: popularity ranking for search results.
--
-- The Add-subscription typeahead today sorts results by prefix-match
-- then alphabetical, which surfaces obscure packages above well-known
-- ones whenever the search term is short. Operators want the obvious
-- choice (Firefox, Chrome, 7zip, VSCode, etc.) at the top of the list.
--
-- No public bulk-popularity dump exists for winget specifically. The
-- chosen approach is a separate daily cron that calls winget.run's
-- per-package /v2/stats endpoint for the highest-interest packages
-- (currently subscribed in any virtual repo, then recently searched,
-- then a bundled curated list) and a weekly cron that backfills the
-- long tail. The search query joins this table and uses the score
-- as a tiebreaker that ranks above alphabetical but below prefix
-- match.
--
-- Schema is forward-compatible: 'source' lets a future feed (e.g.
-- Chocolatey download counts when reachable, GitHub stars, etc.)
-- land alongside winget.run without breaking existing rows. The
-- 'status' column captures fetch outcome so a 404 'not_in_source'
-- row can be skipped on subsequent runs until the next_eligible_at
-- horizon.

BEGIN;

CREATE TABLE IF NOT EXISTS upstream_popularity (
    package_id            TEXT    PRIMARY KEY,
    score                 INTEGER NOT NULL DEFAULT 0,
    source                TEXT    NOT NULL DEFAULT 'winget.run',
    status                TEXT    NOT NULL DEFAULT 'fresh'
                                 CHECK (status IN ('fresh','stale','not_in_source','rate_limited','error')),
    fetched_at_utc        TEXT    NOT NULL,
    next_eligible_at_utc  TEXT,
    error                 TEXT
);

CREATE INDEX IF NOT EXISTS ix_upstream_popularity_score
    ON upstream_popularity (score DESC);

-- Run-state checkpoint so a cron that crashes mid-pass (container
-- restart, rate-limit pause, network outage) resumes from the last
-- completed package_id instead of restarting at 0.
CREATE TABLE IF NOT EXISTS popularity_run (
    run_id            INTEGER PRIMARY KEY AUTOINCREMENT,
    tier              TEXT    NOT NULL CHECK (tier IN ('tier1','tier2','manual')),
    started_utc       TEXT    NOT NULL,
    ended_utc         TEXT,
    status            TEXT    NOT NULL DEFAULT 'in_progress'
                              CHECK (status IN ('in_progress','completed','aborted','rate_limited','disabled')),
    packages_total    INTEGER NOT NULL DEFAULT 0,
    packages_fetched  INTEGER NOT NULL DEFAULT 0,
    packages_skipped  INTEGER NOT NULL DEFAULT 0,
    packages_failed   INTEGER NOT NULL DEFAULT 0,
    cursor_package_id TEXT,
    summary           TEXT
);

CREATE INDEX IF NOT EXISTS ix_popularity_run_status
    ON popularity_run (status, started_utc DESC);

-- Lightweight query log so tier 1 can promote "the things our
-- operators actually search for" into the daily-refresh set. Only
-- the package_id mentioned in the search result, plus when, is
-- needed; the raw query is captured for future analytics but is
-- not used for ranking.
CREATE TABLE IF NOT EXISTS search_log (
    search_log_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    query                TEXT,
    resolved_package_id  TEXT,
    searched_at_utc      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_search_log_pkg
    ON search_log (resolved_package_id, searched_at_utc DESC);

INSERT INTO state_meta (key, value) VALUES ('schema_version', '27')
    ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
