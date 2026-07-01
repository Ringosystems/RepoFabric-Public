// metrics.js: bandwidth measurement layer for the installer route.
//
// Owns a SQLite database at /var/lib/repofabric/metrics.db that records one
// row per installer download request. The Bandwidth admin UI tab reads
// from this database to surface savings ratios per subnet, per installer,
// and over time. See docs/0.8.0-bandwidth-plan.md for the design.
//
// Two tables:
//
//   installer_request          raw per-request rows, 90-day retention.
//                               One row per /installers/* GET or HEAD.
//   installer_request_summary  daily rollup keyed (day, subnet, installer).
//                               Long-term trend storage, install-based so it
//                               never reinflates (distinct installs, file size,
//                               actual egress).
//
// The byte-counting middleware in installers.js writes into installer_request.
// A scheduled rollup (default 03:30 UTC daily) aggregates rows older than
// the retention window into installer_request_summary, then deletes them.

import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS installer_request (
    request_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts                  TEXT    NOT NULL,
    client_ip           TEXT    NOT NULL,
    client_subnet       TEXT    NOT NULL,
    client_ua           TEXT,
    installer_path      TEXT    NOT NULL,
    installer_size      INTEGER NOT NULL,
    bytes_sent          INTEGER NOT NULL,
    peerdist_negotiated INTEGER NOT NULL DEFAULT 0,
    http_status         INTEGER NOT NULL,
    duration_ms         INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_installer_request_ts     ON installer_request(ts);
CREATE INDEX IF NOT EXISTS ix_installer_request_subnet ON installer_request(client_subnet);
CREATE INDEX IF NOT EXISTS ix_installer_request_path   ON installer_request(installer_path);

CREATE TABLE IF NOT EXISTS installer_request_summary (
    day                TEXT    NOT NULL,
    client_subnet      TEXT    NOT NULL,
    installer_path     TEXT    NOT NULL,
    installs           INTEGER NOT NULL,   -- distinct client_ip delivering bytes that day
    peerdist_installs  INTEGER NOT NULL,   -- of those, distinct client_ip that negotiated peerdist
    file_size          INTEGER NOT NULL,   -- MAX(installer_size); constant per file
    actual_bytes       INTEGER NOT NULL,   -- SUM(bytes_sent): true egress from this server
    PRIMARY KEY (day, client_subnet, installer_path)
);

CREATE INDEX IF NOT EXISTS ix_installer_request_summary_day ON installer_request_summary(day);
`;

const DEFAULT_RETENTION_DAYS = 90;

let dbInstance = null;
let insertStmt = null;
let rollupTimer = null;

export function initMetrics(opts = {}) {
  const stateDir = opts.stateDir || process.env.REPOFABRIC_STATE_DIR || '/var/lib/repofabric';
  const dbPath = opts.dbPath || path.join(stateDir, 'metrics.db');
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  dbInstance = db;
  insertStmt = null;
  return db;
}

export function getDb() {
  if (!dbInstance) initMetrics();
  return dbInstance;
}

export function closeMetrics() {
  stopRollupSchedule();
  if (dbInstance) {
    dbInstance.close();
    dbInstance = null;
    insertStmt = null;
  }
}

// Persist a single installer-request observation. Called from the
// res.on('finish') hook in the installers middleware. Wrapped in try/catch
// upstream so an insert failure never affects the HTTP response.
export function recordInstallerRequest(row) {
  const db = getDb();
  if (!insertStmt) {
    insertStmt = db.prepare(`
      INSERT INTO installer_request (
        ts, client_ip, client_subnet, client_ua,
        installer_path, installer_size, bytes_sent,
        peerdist_negotiated, http_status, duration_ms
      ) VALUES (
        @ts, @client_ip, @client_subnet, @client_ua,
        @installer_path, @installer_size, @bytes_sent,
        @peerdist_negotiated, @http_status, @duration_ms
      )
    `);
  }
  insertStmt.run(row);
}

// Aggregate raw rows older than retentionDays into the summary table and
// delete the originals. Returns the number of raw rows pruned. Safe to call
// repeatedly; the summary table uses ON CONFLICT to merge increments.
//
// The aggregation mirrors the dashboard's install-based model (see the savings
// model note below) so a future >90-day blended view computes savings the same
// way and never reinflates: it stores distinct installs (not request count),
// MAX(installer_size) as the constant per-file size, and the true egress
// (SUM(bytes_sent)). Only delivery rows (DELIVERY_FILTER) contribute to the
// summary; HEAD/error rows are pruned but never summarised.
//
// Blending semantics: per installer_path a long-term query sums `installs` and
// `actual_bytes` across days and takes MAX(file_size), then naive = file_size *
// installs, saved = max(0, naive - actual). Summing per-day distinct installs
// counts a device that installs the same file on multiple days once per day
// (an "install event" view), which is the intended trend semantic and is far
// closer to truth than the old request-count rollup.
export function rollupAndPrune(retentionDays = DEFAULT_RETENTION_DAYS) {
  const db = getDb();
  const cutoffMs = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  const cutoff = new Date(cutoffMs).toISOString();

  const tx = db.transaction(() => {
    db.prepare(`
      INSERT INTO installer_request_summary AS s (
        day, client_subnet, installer_path,
        installs, peerdist_installs, file_size, actual_bytes
      )
      SELECT
        date(ts), client_subnet, installer_path,
        COUNT(DISTINCT client_ip),
        COUNT(DISTINCT CASE WHEN peerdist_negotiated = 1 THEN client_ip END),
        MAX(installer_size),
        SUM(bytes_sent)
      FROM installer_request
      WHERE ts < @cutoff AND ${DELIVERY_FILTER}
      GROUP BY date(ts), client_subnet, installer_path
      ON CONFLICT(day, client_subnet, installer_path) DO UPDATE SET
        installs          = s.installs          + excluded.installs,
        peerdist_installs = s.peerdist_installs + excluded.peerdist_installs,
        file_size         = MAX(s.file_size, excluded.file_size),
        actual_bytes      = s.actual_bytes      + excluded.actual_bytes
    `).run({ cutoff });
    const pruned = db.prepare('DELETE FROM installer_request WHERE ts < @cutoff').run({ cutoff }).changes;
    return pruned;
  });

  return tx();
}

// Daily rollup scheduler. Fires at 03:30 UTC, then 24 hours later, and so on.
// Picked to avoid the hourly stale-schedule alert at top-of-hour. Uses
// setTimeout (not setInterval) so each tick recomputes the next 03:30 UTC,
// surviving DST and clock drift.
export function startRollupSchedule(opts = {}) {
  if (rollupTimer) return;
  const retentionDays = opts.retentionDays || DEFAULT_RETENTION_DAYS;
  const hourUtc = opts.hourUtc ?? 3;
  const minuteUtc = opts.minuteUtc ?? 30;

  function scheduleNext() {
    const now = new Date();
    const next = new Date(Date.UTC(
      now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
      hourUtc, minuteUtc, 0, 0
    ));
    if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    const ms = next.getTime() - now.getTime();
    rollupTimer = setTimeout(() => {
      try {
        const pruned = rollupAndPrune(retentionDays);
        console.log(`[metrics] nightly rollup complete; pruned ${pruned} raw rows older than ${retentionDays} days`);
      } catch (err) {
        console.error(`[metrics] rollup failed: ${err.message}`);
      }
      rollupTimer = null;
      scheduleNext();
    }, ms);
    if (rollupTimer.unref) rollupTimer.unref();
  }

  scheduleNext();
}

export function stopRollupSchedule() {
  if (rollupTimer) {
    clearTimeout(rollupTimer);
    rollupTimer = null;
  }
}

// Aggregation queries powering the Bandwidth admin UI tab. All queries
// read from the raw installer_request table only; the summary table is
// reserved for trend analysis past the 90-day retention window. The summary
// now stores the same install-based quantities these queries derive, so a
// future wave can blend both tables transparently without reinflating.
//
// `windowDays` is converted to an ISO cutoff at query time so each call
// sees a freshly-computed window. Default 30 days for headline numbers,
// 90 for the time series.
//
// ---------------------------------------------------------------------------
// Savings model (corrected). The metric is "bandwidth NOT served by this
// server because LAN peers served it instead". Getting it right hinges on one
// distinction: a single device installing one package produces MANY HTTP rows,
// not one.
//
//   * BITS / Delivery Optimization pull a file as dozens-to-hundreds of ranged
//     GETs (HTTP 206). Each row's installer_size is the FULL file size.
//   * With peerdist on, the device first fetches a tiny Content-Information
//     hash blob (Content-Encoding: peerdist, a few KB) and Windows re-negotiates
//     it repeatedly across BITS/DoSvc/winget.
//
// The previous queries used SUM(installer_size) over EVERY row as the "naive"
// (no-peer) baseline, so every range chunk and every hash-blob negotiation
// booked the full file size as "saved". One real install fanned out into
// hundreds of phantom installs each claiming ~100% savings.
//
// Corrected definitions (all server-measurable):
//   install        = a DISTINCT (client_ip, installer_path) with at least one
//                    successful content GET (200/206, installer_size > 0,
//                    bytes_sent > 0). Collapses every range chunk + negotiation
//                    for one device's download into a single install. HEAD and
//                    error rows (bytes_sent 0) are excluded.
//   file_size      = MAX(installer_size) per installer_path (constant per file).
//   actual_bytes   = SUM(bytes_sent): the true egress that left this server.
//   naive_bytes    = SUM over installer_path of (file_size * distinct installs):
//                    what egress WOULD have been if every device pulled the full
//                    file from the server once, i.e. no peer caching.
//   bytes_saved    = max(0, naive_bytes - actual_bytes).
//   savings_ratio  = bytes_saved / naive_bytes.
//
// Consequence: one device installing one package shows 1 install and ~0 saved
// (it pulled the whole file from the server; no peer existed). Savings only
// accrue when additional devices on a subnet are served by a peer.
// ---------------------------------------------------------------------------

// Shared row filter: a successful content delivery that actually moved bytes.
const DELIVERY_FILTER = `
  http_status IN (200, 206)
  AND installer_size > 0
  AND bytes_sent > 0
`;

function cutoffIso(windowDays) {
  return new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000).toISOString();
}

function clampSaved(naive, actual) {
  return Math.max(0, naive - actual);
}

export function getHeadlineSummary({ windowDays = 30 } = {}) {
  const db = getDb();
  const cutoff = cutoffIso(windowDays);

  // Per-installer aggregation first (distinct devices + constant file size),
  // then sum across installers. naive = file_size * distinct installs.
  const row = db.prepare(`
    SELECT
      COALESCE(SUM(installs), 0)             AS installs,
      COALESCE(SUM(file_size * installs), 0) AS naive_bytes,
      COALESCE(SUM(actual_bytes), 0)         AS actual_bytes,
      COALESCE(SUM(peerdist_installs), 0)    AS peerdist_installs
    FROM (
      SELECT
        installer_path,
        MAX(installer_size)                                                AS file_size,
        COUNT(DISTINCT client_ip)                                          AS installs,
        SUM(bytes_sent)                                                    AS actual_bytes,
        COUNT(DISTINCT CASE WHEN peerdist_negotiated = 1 THEN client_ip END) AS peerdist_installs
      FROM installer_request
      WHERE ts >= @cutoff AND ${DELIVERY_FILTER}
      GROUP BY installer_path
    )
  `).get({ cutoff });

  const bytesSaved = clampSaved(row.naive_bytes, row.actual_bytes);
  const savingsRatio = row.naive_bytes > 0 ? bytesSaved / row.naive_bytes : 0;

  return {
    windowDays,
    requests:          row.installs,          // back-compat field name; now = installs
    installs:          row.installs,
    naiveBytes:        row.naive_bytes,
    actualBytes:       row.actual_bytes,
    bytesSaved,
    savingsRatio,
    peerdistRequests:  row.peerdist_installs, // back-compat field name; now = peer-accelerated installs
    peerdistInstalls:  row.peerdist_installs,
    peerdistRatio:     row.installs > 0 ? row.peerdist_installs / row.installs : 0,
  };
}

export function getTimeSeries({ windowDays = 90 } = {}) {
  const db = getDb();
  const cutoff = cutoffIso(windowDays);
  const rows = db.prepare(`
    SELECT
      day,
      COALESCE(SUM(installs), 0)             AS requests,
      COALESCE(SUM(file_size * installs), 0) AS naive_bytes,
      COALESCE(SUM(actual_bytes), 0)         AS actual_bytes
    FROM (
      SELECT
        date(ts)                  AS day,
        installer_path,
        MAX(installer_size)       AS file_size,
        COUNT(DISTINCT client_ip) AS installs,
        SUM(bytes_sent)           AS actual_bytes
      FROM installer_request
      WHERE ts >= @cutoff AND ${DELIVERY_FILTER}
      GROUP BY date(ts), installer_path
    )
    GROUP BY day
    ORDER BY day
  `).all({ cutoff });

  return rows.map(r => ({ ...r, bytes_saved: clampSaved(r.naive_bytes, r.actual_bytes) }));
}

export function getSubnetEffectiveness({ windowDays = 30 } = {}) {
  const db = getDb();
  const cutoff = cutoffIso(windowDays);
  const rows = db.prepare(`
    SELECT
      client_subnet,
      COALESCE(SUM(installs), 0)             AS requests,
      COALESCE(SUM(file_size * installs), 0) AS naive_bytes,
      COALESCE(SUM(actual_bytes), 0)         AS actual_bytes,
      COALESCE(SUM(peerdist_installs), 0)    AS peerdist_requests
    FROM (
      SELECT
        client_subnet,
        installer_path,
        MAX(installer_size)                                                AS file_size,
        COUNT(DISTINCT client_ip)                                          AS installs,
        SUM(bytes_sent)                                                    AS actual_bytes,
        COUNT(DISTINCT CASE WHEN peerdist_negotiated = 1 THEN client_ip END) AS peerdist_installs
      FROM installer_request
      WHERE ts >= @cutoff AND ${DELIVERY_FILTER}
      GROUP BY client_subnet, installer_path
    )
    GROUP BY client_subnet
  `).all({ cutoff });

  return rows
    .map(r => {
      const bytes_saved = clampSaved(r.naive_bytes, r.actual_bytes);
      return {
        ...r,
        bytes_saved,
        savings_ratio: r.naive_bytes > 0 ? bytes_saved / r.naive_bytes : 0,
      };
    })
    .sort((a, b) => b.bytes_saved - a.bytes_saved);
}

export function getTopInstallers({ windowDays = 30, limit = 20 } = {}) {
  const db = getDb();
  const cutoff = cutoffIso(windowDays);
  const rows = db.prepare(`
    SELECT
      installer_path,
      COUNT(DISTINCT client_ip) AS requests,
      MAX(installer_size)       AS avg_installer_size,
      COUNT(DISTINCT client_ip) AS installs,
      MAX(installer_size)       AS file_size,
      SUM(bytes_sent)           AS actual_bytes
    FROM installer_request
    WHERE ts >= @cutoff AND ${DELIVERY_FILTER}
    GROUP BY installer_path
  `).all({ cutoff });

  return rows
    .map(r => {
      const naive_bytes = r.file_size * r.installs;
      const bytes_saved = clampSaved(naive_bytes, r.actual_bytes);
      return { ...r, naive_bytes, bytes_saved };
    })
    .sort((a, b) => b.bytes_saved - a.bytes_saved)
    .slice(0, limit);
}

// IPv4 /24 or IPv6 /64 prefix, used to bucket client IPs into "subnet"
// for the dashboard. Best-effort: malformed inputs are returned as-is.
export function computeSubnet(ip) {
  if (!ip || typeof ip !== 'string') return '0.0.0.0/24';
  // Strip IPv6-mapped-IPv4 prefix (e.g. ::ffff:192.0.2.1 -> 192.0.2.1)
  const stripped = ip.replace(/^::ffff:/i, '');
  if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(stripped)) {
    return stripped.split('.').slice(0, 3).join('.') + '.0/24';
  }
  if (stripped.includes(':')) {
    const parts = stripped.split(':');
    if (parts.length >= 4) return parts.slice(0, 4).join(':') + '::/64';
  }
  return stripped;
}
