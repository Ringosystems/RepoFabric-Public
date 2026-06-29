// Unit tests for metrics.js. Runs under node --test.

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  initMetrics,
  closeMetrics,
  recordInstallerRequest,
  rollupAndPrune,
  computeSubnet,
  getHeadlineSummary,
  getTimeSeries,
  getSubnetEffectiveness,
  getTopInstallers,
} from './metrics.js';

let tmpDir;
let db;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'metrics-test-'));
  db = initMetrics({ dbPath: path.join(tmpDir, 'metrics.db') });
});

afterEach(() => {
  closeMetrics();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function sampleRow(overrides = {}) {
  return {
    ts: new Date().toISOString(),
    client_ip: '10.20.30.40',
    client_subnet: '10.20.30.0/24',
    client_ua: 'BITS/7.8',
    installer_path: '/Mozilla.Firefox/Firefox-130-x64.msi',
    installer_size: 100_000_000,
    bytes_sent: 100_000_000,
    peerdist_negotiated: 0,
    http_status: 200,
    duration_ms: 1234,
    ...overrides,
  };
}

test('recordInstallerRequest: inserts a row', () => {
  recordInstallerRequest(sampleRow());
  const rows = db.prepare('SELECT * FROM installer_request').all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].installer_path, '/Mozilla.Firefox/Firefox-130-x64.msi');
  assert.equal(rows[0].installer_size, 100_000_000);
  assert.equal(rows[0].bytes_sent, 100_000_000);
  assert.equal(rows[0].peerdist_negotiated, 0);
});

test('recordInstallerRequest: distinguishes peerdist-negotiated', () => {
  recordInstallerRequest(sampleRow({ peerdist_negotiated: 0, bytes_sent: 100_000_000 }));
  recordInstallerRequest(sampleRow({ peerdist_negotiated: 1, bytes_sent: 15_000 }));
  const rows = db.prepare('SELECT peerdist_negotiated, bytes_sent FROM installer_request ORDER BY request_id').all();
  assert.equal(rows[0].peerdist_negotiated, 0);
  assert.equal(rows[1].peerdist_negotiated, 1);
  assert.equal(rows[1].bytes_sent, 15_000);
});

test('rollupAndPrune: aggregates and deletes rows older than retention', () => {
  const ancient = new Date(Date.now() - 120 * 24 * 3600 * 1000).toISOString();
  const fresh = new Date().toISOString();

  recordInstallerRequest(sampleRow({ ts: ancient, installer_size: 100, bytes_sent: 100 }));
  recordInstallerRequest(sampleRow({ ts: ancient, installer_size: 200, bytes_sent: 50 }));
  recordInstallerRequest(sampleRow({ ts: fresh,   installer_size: 999, bytes_sent: 999 }));

  const pruned = rollupAndPrune(90);

  assert.equal(pruned, 2, 'two old rows pruned');
  const remaining = db.prepare('SELECT COUNT(*) AS n FROM installer_request').get();
  assert.equal(remaining.n, 1, 'one fresh row remains in raw table');

  // Install-based rollup: the two old rows are the same device (client_ip) for
  // the same file, so they collapse to ONE install, not two requests.
  const summary = db.prepare('SELECT * FROM installer_request_summary').all();
  assert.equal(summary.length, 1);
  assert.equal(summary[0].installs, 1, 'two requests from one device = one install');
  assert.equal(summary[0].peerdist_installs, 0);
  assert.equal(summary[0].file_size, 200, 'MAX(installer_size), constant per file');
  assert.equal(summary[0].actual_bytes, 150, 'SUM(bytes_sent), true egress');
});

test('rollupAndPrune: is idempotent across calls', () => {
  const ancient = new Date(Date.now() - 120 * 24 * 3600 * 1000).toISOString();
  recordInstallerRequest(sampleRow({ ts: ancient, installer_size: 100, bytes_sent: 25 }));
  rollupAndPrune(90);

  const ancientAgain = new Date(Date.now() - 120 * 24 * 3600 * 1000).toISOString();
  recordInstallerRequest(sampleRow({ ts: ancientAgain, installer_size: 100, bytes_sent: 25 }));
  rollupAndPrune(90);

  // ON CONFLICT merge is additive across rollup runs (idempotency safety net):
  // distinct installs and egress accumulate, file_size takes the MAX.
  const summary = db.prepare('SELECT * FROM installer_request_summary').all();
  assert.equal(summary.length, 1, 'still one summary row (same key)');
  assert.equal(summary[0].installs, 2, 'installs merged across rollups');
  assert.equal(summary[0].actual_bytes, 50, 'egress summed across rollups');
  assert.equal(summary[0].file_size, 100, 'file_size is the MAX across rollups');
});

test('computeSubnet: IPv4 → /24', () => {
  assert.equal(computeSubnet('10.20.30.40'),  '10.20.30.0/24');
  assert.equal(computeSubnet('192.168.1.99'), '192.168.1.0/24');
});

test('computeSubnet: IPv4-mapped IPv6 → /24', () => {
  assert.equal(computeSubnet('::ffff:10.20.30.40'), '10.20.30.0/24');
});

test('computeSubnet: IPv6 → /64', () => {
  assert.equal(
    computeSubnet('2001:db8:0:1:abcd:ef01:2345:6789'),
    '2001:db8:0:1::/64'
  );
});

test('computeSubnet: malformed input returns as-is', () => {
  assert.equal(computeSubnet(''), '0.0.0.0/24');
  assert.equal(computeSubnet(null), '0.0.0.0/24');
  assert.equal(computeSubnet('not-an-ip'), 'not-an-ip');
});

// -- Aggregation queries (corrected install-based savings model) -------
//
// The model counts DISTINCT (client_ip, installer_path) as one install and
// uses file_size * installs as the no-peer baseline, so range chunks and
// repeated peerdist negotiations from one device no longer inflate the count
// or the savings. See the model comment in metrics.js.

// Emit the row fan-out a single real BITS download produces: one tiny
// peerdist content-info negotiation plus N ranged GETs that sum to `delivered`
// bytes, all from one client_ip for one installer_path.
function recordDownload({ ip, subnet = '10.0.0.0/24', path: p, fileSize, delivered, ranges = 8, peerdist = true, day }) {
  const ts = (day || new Date()).toISOString();
  if (peerdist) {
    recordInstallerRequest({
      ts, client_ip: ip, client_subnet: subnet, client_ua: 'Microsoft-Delivery-Optimization/10.0',
      installer_path: p, installer_size: fileSize, bytes_sent: 20_000,
      peerdist_negotiated: 1, http_status: 200, duration_ms: 50,
    });
  }
  const per = Math.floor(delivered / ranges);
  for (let i = 0; i < ranges; i++) {
    const chunk = i === ranges - 1 ? delivered - per * (ranges - 1) : per;
    recordInstallerRequest({
      ts, client_ip: ip, client_subnet: subnet, client_ua: 'Microsoft-BITS/7.8',
      installer_path: p, installer_size: fileSize, bytes_sent: chunk,
      peerdist_negotiated: 0, http_status: 206, duration_ms: 30,
    });
  }
}

test('getHeadlineSummary: one device, one install, ~zero savings (the reported bug)', () => {
  // ONE device installs a 100MB package. peerdist on, so it fans out into a
  // content-info negotiation + 200 ranged GETs that together pull the whole
  // file from the server (no peer existed). The OLD model reported ~201
  // "installs" and ~100% savings; the corrected model reports 1 install and
  // ~0 saved.
  recordDownload({ ip: '10.0.0.1', path: '/Adobe.Acrobat.Reader.64-bit/reader.exe',
    fileSize: 100_000_000, delivered: 100_000_000, ranges: 200, peerdist: true });

  const s = getHeadlineSummary({ windowDays: 30 });
  assert.equal(s.installs, 1, 'one distinct device+installer = one install');
  assert.equal(s.requests, 1, 'back-compat field equals install count');
  assert.equal(s.naiveBytes, 100_000_000, 'baseline = file size * 1 install');
  assert.equal(s.actualBytes, 100_020_000, 'true egress: full file + 20KB content-info');
  assert.equal(s.bytesSaved, 0, 'no peer served any bytes, so nothing was saved');
  assert.equal(s.savingsRatio, 0);
});

test('getHeadlineSummary: savings accrue only across additional devices', () => {
  // Device 1 pulls the full 100MB file from the server (first on the subnet).
  // Devices 2 and 3 are served by the LAN peer: tiny content-info + a few
  // missing-block ranges. Baseline = 100MB * 3 installs = 300MB. Actual egress
  // = ~100MB + 2 * (~negligible). Saved ~= 200MB.
  recordDownload({ ip: '10.0.0.1', path: '/x.exe', fileSize: 100_000_000, delivered: 100_000_000, ranges: 50 });
  recordDownload({ ip: '10.0.0.2', path: '/x.exe', fileSize: 100_000_000, delivered: 200_000, ranges: 4 });
  recordDownload({ ip: '10.0.0.3', path: '/x.exe', fileSize: 100_000_000, delivered: 200_000, ranges: 4 });

  const s = getHeadlineSummary({ windowDays: 30 });
  assert.equal(s.installs, 3);
  assert.equal(s.naiveBytes, 300_000_000);
  // actual = full(100M) + 3 negotiations(60K) + 2 peer-served deliveries(400K)
  assert.equal(s.actualBytes, 100_000_000 + 60_000 + 400_000);
  assert.equal(s.bytesSaved, 300_000_000 - (100_000_000 + 60_000 + 400_000));
  assert.ok(s.savingsRatio > 0.66 && s.savingsRatio < 0.67, `ratio ${s.savingsRatio}`);
  assert.equal(s.peerdistInstalls, 3, 'all three negotiated peerdist');
  assert.equal(s.peerdistRatio, 1);
});

test('getHeadlineSummary: HEAD probes and errors do not count as installs', () => {
  // A HEAD (bytes_sent 0) and a 404 must not register as installs or savings.
  recordInstallerRequest({
    ts: new Date().toISOString(), client_ip: '10.0.0.9', client_subnet: '10.0.0.0/24',
    client_ua: 'BITS', installer_path: '/x.exe', installer_size: 100_000_000,
    bytes_sent: 0, peerdist_negotiated: 1, http_status: 200, duration_ms: 5,
  });
  recordInstallerRequest({
    ts: new Date().toISOString(), client_ip: '10.0.0.9', client_subnet: '10.0.0.0/24',
    client_ua: 'scanner', installer_path: '/missing.exe', installer_size: 0,
    bytes_sent: 150, peerdist_negotiated: 0, http_status: 404, duration_ms: 1,
  });
  const s = getHeadlineSummary({ windowDays: 30 });
  assert.equal(s.installs, 0);
  assert.equal(s.bytesSaved, 0);
});

test('getHeadlineSummary: zero requests returns zero ratio', () => {
  const summary = getHeadlineSummary({ windowDays: 30 });
  assert.equal(summary.requests, 0);
  assert.equal(summary.savingsRatio, 0);
  assert.equal(summary.peerdistRatio, 0);
});

test('getTimeSeries: groups by day, install-based', () => {
  const today = new Date();
  const yesterday = new Date(today.getTime() - 24 * 3600 * 1000);
  // Yesterday: one device pulls full 1MB file (no savings).
  recordDownload({ ip: '10.0.0.1', path: '/a.msi', fileSize: 1_000_000, delivered: 1_000_000, ranges: 10, peerdist: false, day: yesterday });
  // Today: two devices for a 2MB file, second peer-served.
  recordDownload({ ip: '10.0.0.1', path: '/b.msi', fileSize: 2_000_000, delivered: 2_000_000, ranges: 10, peerdist: false, day: today });
  recordDownload({ ip: '10.0.0.2', path: '/b.msi', fileSize: 2_000_000, delivered: 10_000, ranges: 2, peerdist: false, day: today });

  const series = getTimeSeries({ windowDays: 7 });
  assert.equal(series.length, 2);
  assert.ok(series[0].day < series[1].day);
  assert.equal(series[0].requests, 1, 'one install yesterday');
  assert.equal(series[0].bytes_saved, 0, 'single device, no savings');
  assert.equal(series[1].requests, 2, 'two installs today');
  // naive = 2MB * 2 = 4MB; actual = 2MB + 10KB; saved = 2MB - 10KB.
  assert.equal(series[1].naive_bytes, 4_000_000);
  assert.equal(series[1].bytes_saved, 4_000_000 - (2_000_000 + 10_000));
});

test('getSubnetEffectiveness: install-based savings per subnet', () => {
  // Subnet A: 3 devices install the same 1MB file; first full, other two
  // peer-served. Subnet B: 1 device, full pull, no savings.
  recordDownload({ ip: '10.0.0.1', subnet: '10.0.0.0/24', path: '/x.msi', fileSize: 1_000_000, delivered: 1_000_000, ranges: 8 });
  recordDownload({ ip: '10.0.0.2', subnet: '10.0.0.0/24', path: '/x.msi', fileSize: 1_000_000, delivered: 5_000, ranges: 2 });
  recordDownload({ ip: '10.0.0.3', subnet: '10.0.0.0/24', path: '/x.msi', fileSize: 1_000_000, delivered: 5_000, ranges: 2 });
  recordDownload({ ip: '10.9.0.1', subnet: '10.9.0.0/24', path: '/x.msi', fileSize: 1_000_000, delivered: 1_000_000, ranges: 8 });

  const rows = getSubnetEffectiveness({ windowDays: 30 });
  assert.equal(rows.length, 2);
  // Highest savings first.
  assert.equal(rows[0].client_subnet, '10.0.0.0/24');
  assert.equal(rows[0].requests, 3, 'three installs in subnet A');
  assert.equal(rows[0].naive_bytes, 3_000_000);
  // actual = full(1M) + 3 negotiations(60K) + 2 peer deliveries(10K)
  assert.equal(rows[0].actual_bytes, 1_000_000 + 60_000 + 10_000);
  assert.equal(rows[0].bytes_saved, 3_000_000 - (1_000_000 + 60_000 + 10_000));
  assert.equal(rows[0].peerdist_requests, 3, 'peer-accelerated installs');
  // Subnet B: one device, no savings.
  assert.equal(rows[1].client_subnet, '10.9.0.0/24');
  assert.equal(rows[1].requests, 1);
  assert.equal(rows[1].bytes_saved, 0);
});

test('getTopInstallers: ranks by install-based bytes_saved descending', () => {
  // large.msi: 2 devices (one full, one peer-served) -> real savings.
  recordDownload({ ip: '10.0.0.1', path: '/large.msi', fileSize: 100_000_000, delivered: 100_000_000, ranges: 50 });
  recordDownload({ ip: '10.0.0.2', path: '/large.msi', fileSize: 100_000_000, delivered: 100_000, ranges: 2 });
  // small.msi: 1 device only -> no savings.
  recordDownload({ ip: '10.0.0.3', path: '/small.msi', fileSize: 1_000_000, delivered: 1_000_000, ranges: 8 });

  const rows = getTopInstallers({ windowDays: 30, limit: 10 });
  assert.equal(rows.length, 2);
  assert.equal(rows[0].installer_path, '/large.msi', 'most-saved installer first');
  assert.equal(rows[0].requests, 2, 'two installs');
  assert.equal(rows[0].avg_installer_size, 100_000_000, 'reports the file size');
  // naive = 100M * 2 = 200M; actual = 100M + 40K(negs) + 100K(peer); saved = ~99.86M
  assert.equal(rows[0].bytes_saved, 200_000_000 - (100_000_000 + 40_000 + 100_000));
  assert.equal(rows[1].installer_path, '/small.msi');
  assert.equal(rows[1].bytes_saved, 0, 'single device, no savings');
});
