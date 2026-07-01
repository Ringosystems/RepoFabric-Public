// installers.js: dedicated Express app that serves installer binaries.
//
// The bind mount target inside the container is /var/cache/repofabric/installers
// (matches the path convention the rest of the code already uses).
//
// Listens on a separate port from the admin UI so the operator's existing
// reverse-proxy hostname for installers.<domain> (which forwards to
// host:8091) does not need to be retargeted.
//
// Security posture: this is a read-only static server. No auth (clients
// verify SHA256 from the WinGet manifest). No body parsing (no POST/PUT).
// No directory listing (express.static defaults to file-only).
//
// PeerDist negotiation (0.8.0): when config.installers.peerdist.enabled is
// true AND the client sends "Accept-Encoding: peerdist" (plus X-P2P-PeerDist)
// on a non-range GET/HEAD for an installer file, we respond with
// "Content-Encoding: peerdist" and a body that IS the MS-PCCRC v1.0 Content
// Information Data Structure (the segment/block hash tree), NOT the file.
// BITS parses it, derives each segment's HoHoDk discovery label, finds peers
// on the subnet via WS-Discovery, and pulls blocks from them. For blocks no
// peer has, BITS issues a follow-up ranged GET (MissingDataRequest=true);
// those carry a Range header and fall through to the static layer, which
// serves the raw bytes. Clients that do not request peerdist download the
// file normally with no behavioural change.

import express from 'express';
import path from 'node:path';
import fs from 'node:fs';
import yaml from 'js-yaml';
import { config } from './config.js';
import { loadOrCompute, encodeContentInformation, getServerSecret, PEERDIST_CONSTANTS } from './peerdist.js';
import { recordInstallerRequest, computeSubnet } from './metrics.js';
import { buildClientBootstrapScript } from './clientbootstrap.js';
import { repoSourceName } from './clientconfig.js';

// Live read of the peerdist kill switch. The flag is operator-toggled in the
// Settings UI (writes service.yaml); re-reading it here with a short TTL means
// enabling/disabling peer caching takes effect within a few seconds WITHOUT a
// container restart. Falls back to the boot-time config value on read error.
let _peerdistCache = { at: 0, val: config.installers?.peerdist?.enabled === true };
function peerdistEnabledLive() {
  const now = Date.now();
  if (now - _peerdistCache.at < 3000) return _peerdistCache.val;
  _peerdistCache.at = now;
  try {
    const svc = yaml.load(fs.readFileSync(config.paths.serviceYaml, 'utf8')) || {};
    _peerdistCache.val = svc?.installers?.peerdist?.enabled === true;
  } catch { /* keep last good value */ }
  return _peerdistCache.val;
}

export function startInstallerServer(port, installersRoot) {
  const app = express();

  // Trust proxy so X-Forwarded-* headers from NPM (or any operator
  // reverse proxy) get respected for access logging.
  app.set('trust proxy', 1);

  // Health probe (used by docker-compose healthcheck if added later).
  app.get('/healthz', (_req, res) => res.json({ ok: true, service: 'installers' }));

  // Sandbox client bootstrap (plain HTTP). Self-contained .ps1 a client fetches
  // over HTTP -- no cert trust needed to download it -- then runs elevated to
  // trust the embedded sandbox CA and register the WinGet source. Registered
  // before the metrics/peerdist/static layers so it is generated, not statted as
  // a file. Sandbox-only; production never publishes this HTTP port.
  if (config.isSandbox) {
    app.get('/setup.ps1', (_req, res) => {
      try {
        const caPem = fs.readFileSync(path.join(installersRoot, 'sandbox-ca.pem'), 'utf8');
        // publicBaseUrl is winget.<domain>:<https-port>/admin; its origin + /api/
        // is the WinGet REST source URL the client registers.
        const sourceUrl = new URL(config.publicBaseUrl).origin + '/api/';
        // The installer host is a different subdomain (installers.<domain>); pass it
        // so the bootstrap maps BOTH the source and installer sites into the Intranet Zone.
        const installerUrl = config.targets?.installerBaseUrl || '';
        const ps1 = buildClientBootstrapScript({
          sourceName: repoSourceName({ RepoId: 'main' }),
          sourceUrl,
          installerUrl,
          caPem,
        });
        res.set('Content-Type', 'text/plain; charset=utf-8');
        res.set('Content-Disposition', 'attachment; filename="repofabric-setup.ps1"');
        res.set('Cache-Control', 'no-store');
        res.send(ps1);
      } catch (err) {
        res.status(503).type('text/plain').send('# RepoFabric setup script unavailable: ' + err.message);
      }
    });
  }

  // Sidecars are server-private. They live next to installer files but
  // must never be served to clients. Reject any GET that targets a path
  // ending in .peerdist (or .peerdist.tmp during atomic writes).
  app.use((req, res, next) => {
    if (req.path.endsWith(PEERDIST_CONSTANTS.SIDECAR_SUFFIX) ||
        req.path.endsWith(PEERDIST_CONSTANTS.SIDECAR_SUFFIX + '.tmp')) {
      return res.status(404).send('Not found');
    }
    next();
  });

  // Bandwidth measurement middleware. Wraps res.write and res.end to
  // accumulate bytes_sent, looks up installer_size from the filesystem,
  // and persists one row to metrics.db on the response finish event.
  // Persistence is wrapped in try/catch so a metrics insert failure
  // never breaks the HTTP response. Runs BEFORE the peerdist middleware
  // so the byte counter is in place before any header negotiation
  // streams data.
  app.use((req, res, next) => {
    const started = Date.now();
    const reqPath = req.path || '/';
    const reqMethod = req.method;

    // Cheap early-out for non-installer traffic (health probe).
    if (reqPath === '/healthz') return next();

    // BITS signals PeerDist support via Accept-Encoding (NOT X-MS-AcceptEncoding
    // as some older docs suggest) plus X-P2P-PeerDist version header.
    // Verified 2026-05-30 via captured BITS request: "accept-encoding:
    // identity, peerdist" and "x-p2p-peerdist: Version=1.1".
    const acceptEnc = (req.headers['accept-encoding'] || '').toLowerCase();
    const p2pHeader = req.headers['x-p2p-peerdist'] || '';
    const peerdistNegotiated = (acceptEnc.includes('peerdist') || p2pHeader) ? 1 : 0;
    const ua = req.headers['user-agent'] || null;
    const clientIp = req.ip || '0.0.0.0';
    const subnet = computeSubnet(clientIp);

    let installerSize = 0;
    try {
      const normalised = path.posix.normalize(decodeURIComponent(reqPath));
      if (!normalised.includes('..')) {
        const filePath = path.join(installersRoot, normalised);
        if (filePath.startsWith(path.resolve(installersRoot))) {
          const stats = fs.statSync(filePath);
          if (stats.isFile()) installerSize = stats.size;
        }
      }
    } catch { /* file may not exist; recorded as size 0 below */ }

    let bytesSent = 0;
    const origWrite = res.write.bind(res);
    const origEnd = res.end.bind(res);
    res.write = function(chunk, ...rest) {
      if (chunk) bytesSent += Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk);
      return origWrite(chunk, ...rest);
    };
    res.end = function(chunk, ...rest) {
      if (chunk) bytesSent += Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk);
      return origEnd(chunk, ...rest);
    };

    res.on('finish', () => {
      // Only record GET/HEAD. Other methods are not expected on the static
      // installer surface; skipping avoids noise from probe scanners.
      if (reqMethod !== 'GET' && reqMethod !== 'HEAD') return;
      // Skip rows that look like nothing (a 404 for a missing file with
      // tiny body). They are noise; the per-installer table would fill
      // with random scanned paths otherwise.
      if (installerSize === 0 && bytesSent < 200) return;

      try {
        recordInstallerRequest({
          ts:                  new Date().toISOString(),
          client_ip:           clientIp,
          client_subnet:       subnet,
          client_ua:           ua,
          installer_path:      reqPath,
          installer_size:      installerSize,
          bytes_sent:          bytesSent,
          peerdist_negotiated: peerdistNegotiated,
          http_status:         res.statusCode,
          duration_ms:         Date.now() - started,
        });
      } catch (err) {
        console.warn(`[installers] metrics insert failed: ${err.message}`);
      }
    });

    next();
  });

  // PeerDist negotiation middleware. Runs BEFORE express.static so the
  // header is attached before the file body streams out. The middleware
  // is a no-op when the kill-switch flag is off, when the client did not
  // request peerdist encoding, when the request is a range read (peerdist
  // hashes describe the full content, not a slice), or when the underlying
  // file is missing or unreasonably large.
  app.use((req, res, next) => {
    if (!peerdistEnabledLive()) return next();
    if (req.method !== 'GET' && req.method !== 'HEAD') return next();
    if (req.headers['range']) return next();

    // See Wave 18 finding (tests/peerdist-lab/FINDINGS.md): real BITS
    // sends Accept-Encoding: identity, peerdist and X-P2P-PeerDist:
    // Version=1.1. The earlier X-MS-AcceptEncoding lookup never fired.
    const acceptEnc = (req.headers['accept-encoding'] || '').toLowerCase();
    const p2pHeader = req.headers['x-p2p-peerdist'] || '';
    if (!acceptEnc.includes('peerdist') && !p2pHeader) return next();

    const normalised = path.posix.normalize(decodeURIComponent(req.path || '/'));
    if (normalised.includes('..')) return next();
    const filePath = path.join(installersRoot, normalised);
    if (!filePath.startsWith(path.resolve(installersRoot))) return next();

    try {
      const stats = fs.statSync(filePath);
      if (!stats.isFile()) return next();
      if (stats.size === 0) return next();
      if (stats.size > PEERDIST_CONSTANTS.MAX_HASHABLE_SIZE) return next();

      const hashes = loadOrCompute(filePath);
      const blob = encodeContentInformation(hashes, getServerSecret());

      // Terminal response: the body IS the Content Information structure.
      // Do NOT fall through to express.static.
      res.statusCode = 200;
      res.setHeader('Content-Encoding', 'peerdist');
      res.setHeader('X-P2P-PeerDist', `Version=1.0, ContentLength=${stats.size}`);
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Content-Length', blob.length);
      if (req.method === 'HEAD') { res.end(); return; }
      res.end(blob);
      return;
    } catch (err) {
      console.warn(`[installers] peerdist negotiation failed for ${req.path}: ${err.message}`);
      // Fall through to a normal file download on any failure.
    }

    next();
  });

  // Static serve with sendfile, range requests (auto), 1-year cache.
  // Installers are immutable per (package_id, version, filename) tuple
  // so aggressive caching is safe; new versions get new filenames.
  app.use('/', express.static(installersRoot, {
    dotfiles:    'deny',
    fallthrough: false,
    immutable:   true,
    index:       false,
    maxAge:      '365d',
    redirect:    false,
  }));

  // 404 catch-all matches nginx's behaviour for missing files.
  app.use((_req, res) => res.status(404).send('Not found'));

  const server = app.listen(port, () => {
    const pd = config.installers?.peerdist?.enabled ? 'on' : 'off';
    console.log(`[repofabric-linux] listening on :${port}  root=${installersRoot}  peerdist=${pd}`);
  });

  return server;
}
