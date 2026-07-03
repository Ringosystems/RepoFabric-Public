// repofabric-linux-admin Node entry point. Two surfaces:
//   /setup/*  active only when /var/lib/repofabric/setup-mode exists.
//   /admin/*  active in normal mode.
//
// Liveness probe at /healthz is always available (used by docker healthcheck).

import express from 'express';
import session from 'express-session';
import helmet from 'helmet';
import morgan from 'morgan';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import { config, m2mReadiness, m2mFatals, currentTimezone } from './config.js';
import { setupRouter } from './setup.js';
import { startLogin, handleCallback, handleLocalLogin, renderLocalLogin, logout, logoutCallback, requireAuth, requireIngestToken, requireBoltOnToken } from './auth.js';
import { apiRouter } from './routes.js';
import { entraConnectRouter } from './entra-connect.js';
import { upgradeRouter } from './upgrade.js';
import { isEntraConfigured } from './entra-helper.js';
import { requestContext } from './bridge.js';
import { cfApiRouter } from './cf-routes.js';
import { cfBridge, cfRequestContext } from './cf-bridge.js';
import { docsRouter, docsRoot } from './docs.js';
import { startInstallerServer } from './installers.js';
import { initMetrics, startRollupSchedule, closeMetrics } from './metrics.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();

app.set('trust proxy', 1);

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc:  ["'self'"],
      styleSrc:   ["'self'", "'unsafe-inline'"],
      imgSrc:     ["'self'", 'data:'],
      connectSrc: ["'self'"],
    },
  },
}));
app.use(morgan('combined'));
// Capture the EXACT request bytes alongside the parsed JSON. The cross-host M2M
// bridge legs (see below) carry an RFC 9421 Content-Digest the peer signed over
// the raw body; re-serialising the parsed object can reorder keys / change
// whitespace and break that digest, so the forwarder must replay the original
// bytes verbatim. Harmless for every other route.
// The audit-write forward leg must replay the EXACT bytes the peer signed, for
// ANY content-type and up to the proxy's body limit. Capture the raw body for
// that one route BEFORE express.json (which only handles application/json under
// 512kb and would otherwise forward an empty body, breaking the peer's
// Content-Digest). express.raw sets req._body so express.json then skips it.
// RepoFabric#35 M2.
if (config.bridgeLegs?.auditWrite) {
  app.post('/api/audit/events', express.raw({ type: '*/*', limit: '2mb', verify: (req, _res, buf) => { req.rawBody = buf; } }));
}
app.use(express.json({ limit: '512kb', verify: (req, _res, buf) => { req.rawBody = buf; } }));

app.use(session({
  name: 'repofabric.sid',
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    secure: config.cookieSecure,
    maxAge: 8 * 60 * 60 * 1000,
    path: '/',
  },
}));

// Always-on liveness for docker healthcheck.
// /healthz also publishes the solution timezone (FD-026): RepoFabric is the
// authority, and this is the read-only field a co-hosted or cross-host peer
// consumes so the whole solution renders in one zone instead of assuming a
// locale-specific default. Non-secret, so it rides the always-available probe.
app.get('/healthz', (_req, res) => res.json({ ok: true, setup_mode: config.inSetupMode, timezone: currentTimezone() }));

// /docs/* is the deployment walkthrough -- the Day 0 guide that
// covers the companion stack, every supported host platform, the
// NPM reverse proxy, the bootstrap script, and the .env reference.
// Lives in BOTH modes because operators need it BEFORE they have
// even reached the setup wizard. Static assets (CSS) come from
// /docs-static; the markdown pages are rendered by docsRouter().
// docs are mounted at THREE paths so they Just Work behind whatever
// reverse-proxy config the operator has:
//   /docs/        -- canonical; requires a third NPM proxy host or
//                    a /docs custom location alongside /admin
//   /admin/docs/  -- works through the /admin custom location every
//                    operator already has. Mounted BEFORE the
//                    requireAuth middleware below so it stays
//                    unauthenticated (docs should be readable
//                    without a session).
//   /setup/docs/  -- works through the /setup proxy in setup mode so
//                    the wizard's docs link is reachable before any
//                    auth surface exists.
// Same docsRouter handles all three; the asset CSS is mounted on the
// matching -static prefix for each.
function mountDocs(prefix) {
  const leaf = prefix.split('/').pop(); // 'docs' for every mount
  app.use(`${prefix}-static`, express.static(path.join(__dirname, '..', 'static', 'docs-static'), {
    setHeaders(res) { res.setHeader('Cache-Control', 'public, max-age=600'); },
  }));
  // Add a trailing slash ONLY when it is missing, so the page's relative asset
  // and nav URLs resolve against <mount>/. The redirect target is RELATIVE
  // (leaf + '/') so it is correct whether or not the reverse proxy strips the
  // mount prefix. Express routing is non-strict, so app.get(prefix) also matches
  // '<mount>/'; without the endsWith guard it would redirect '<mount>/' to
  // itself and loop (ERR_TOO_MANY_REDIRECTS behind the /admin proxy). docsRouter
  // serves the index at '<mount>/' directly, so there is no second /index hop.
  app.get(prefix, (req, res, next) => {
    if (req.path.endsWith('/')) return next();
    res.redirect(`${leaf}/`);
  });
  app.use(prefix, docsRouter());
}
mountDocs('/docs');
mountDocs('/admin/docs');
mountDocs('/setup/docs');

// /setup/* is mounted in BOTH modes:
//  * In first-run setup mode it is the only surface available; /admin
//    redirects to it.
//  * In normal mode it stays mounted (gated by the runtime setup-mode
//    flag + token check inside setupRouter) so an authenticated admin
//    can re-enter the wizard via Settings -> Advanced -> System ->
//    Re-enter setup wizard, without needing a container restart.
app.use('/setup', express.static(path.join(__dirname, '..', 'static', 'setup'), {
  setHeaders(res, filepath) {
    if (filepath.endsWith('.html')) res.setHeader('Cache-Control', 'no-store');
  },
}));
app.get('/setup', (_req, res) => res.redirect('/setup/'));
app.use('/setup/api', setupRouter());
app.get('/setup/', (_req, res) => res.sendFile(path.join(__dirname, '..', 'static', 'setup', 'index.html')));

if (config.inSetupMode) {
  console.log('[server] SETUP MODE — /setup/* is the only surface; /admin/* redirects to it until first-run completes');
  // /admin is intentionally unmounted in setup mode. Any hit redirects to setup.
  app.use('/admin', (_req, res) => res.redirect('/setup/'));
} else {
  console.log('[server] NORMAL MODE — /admin/* mounted, Entra auth active');

  // Unauthenticated auth routes
  app.get('/admin/healthz', (_q, s) => s.json({ status: 'ok' }));
  app.get('/admin/auth/login',           startLogin);
  app.get('/admin/auth/callback',        handleCallback);
  app.get('/admin/auth/logout',          logout);
  app.get('/admin/auth/logout-callback', logoutCallback);

  // Sandbox profile: local-admin sign-in (form posts urlencoded, not JSON, so
  // it needs its own body parser). Mounted only in the sandbox deployment;
  // production never exposes a password login surface.
  if (config.isSandbox) {
    console.log('[server] SANDBOX PROFILE — local-admin sign-in enabled at /admin/auth/local-login');
    // GET renders the local form DIRECTLY (not via startLogin) so it stays a
    // true break-glass: reachable even after Entra has been connected and
    // startLogin therefore redirects /admin/auth/login to Microsoft.
    app.get('/admin/auth/local-login',  (req, res) => renderLocalLogin(req, res, null));
    app.post('/admin/auth/local-login', express.urlencoded({ extended: false }), handleLocalLogin);
  }

  // --- ConfigFabric absorption: machine-to-machine seams (pre-auth) -------
  // These three paths are server-to-server (no operator session) and so are
  // mounted AHEAD of requireAuth, each guarded only by a shared bearer. They
  // proxy to ConfigFabric's loopback pwsh bridge on :8089. Flag-gated: a
  // standalone RepoFabric never mounts them. Paths match the frozen
  // ConfigFabric contract verbatim so RepoFabric's prune gate and the Azure
  // Function dual-write reach them unchanged.
  if (config.configfabric.enabled) {
    app.post('/admin/api/compliance/ingest', requireIngestToken, async (req, res) => {
      try { res.status(202).json(await cfBridge.ingestCompliance(req.body || {})); }
      catch (err) { res.status(err.status || 502).json({ error: err.message, detail: err.body || null }); }
    });
    // Fail-closed lock deletion-evaluation (CF#2). When the CF bridge is
    // unreachable (err.status undefined) synthesize the all-deny answer the
    // CF publisher would have produced rather than leaking a bare 502.
    app.post('/admin/api/v1/locks/evaluate-deletion', requireBoltOnToken, async (req, res) => {
      try { res.status(200).json(await cfBridge.evaluateDeletion(req.body || {})); }
      catch (err) {
        if (err.status === undefined) {
          return res.status(503).json({
            request_id: req.body?.request_id ?? null,
            ledger_state: 'unreachable',
            decisions: (req.body?.candidates || []).filter(Boolean).map(c => ({
              app_id: c.app_id ?? null, version: c.version ?? null,
              decision: 'deny', reason: 'ledger_unavailable', gating_locks: [],
            })),
            orphaned_locks: [], error: 'ledger_unavailable',
          });
        }
        res.status(err.status).json(err.body || { error: err.message });
      }
    });
    app.post('/admin/api/v1/locks/override-deletion', requireBoltOnToken, async (req, res) => {
      try { res.status(200).json(await cfBridge.overrideDeletion(req.body || {})); }
      catch (err) {
        if (err.status === undefined) {
          return res.status(409).json({ error: 'ledger_unreachable_override_forbidden', request_id: req.body?.request_id ?? null });
        }
        res.status(err.status).json(err.body || { error: err.message });
      }
    });
  }

  // --- Cross-host M2M bridge legs: catalog:read / audit:write (pre-auth) ---
  // DSCForge reads GET /api/v1/catalog/* and peers POST /api/audit/events with
  // their per-leg scoped Bearer. Those routes live only on the loopback pwsh
  // listener (:8085); the operator's reverse proxy forwards the public paths
  // here, and this forwarder relays them to the publisher WITHOUT substituting
  // the full publisher token — the caller's scoped Bearer + any RFC 9421
  // signature headers + the raw body all pass through verbatim, so the pwsh
  // RfBridgeCapability gate stays the sole authority on catalog:read vs
  // audit:write (M6 least-privilege), and the inbound signature verifier sees
  // exactly what the peer signed. X-Forwarded-Host/Proto are passed through so
  // the verifier can reconstruct @authority / @target-uri as the PUBLIC URL the
  // peer signed, not this loopback hop. Mounted ONLY when the matching scoped
  // token is provisioned (the opt-in), and never under /admin, so requireAuth
  // (operator OIDC) does not gate these server-to-server calls.
  const forwardToPublisher = async (req, res) => {
    const headers = { Accept: 'application/json' };
    // Pass the caller's credentials + signature material + proxy context through
    // verbatim. Host header is intentionally NOT copied (fetch sets it for the
    // loopback target); X-Forwarded-* carry the public authority instead.
    for (const h of ['Authorization', 'Content-Type', 'Content-Digest',
                     'Signature', 'Signature-Input',
                     'X-Forwarded-Host', 'X-Forwarded-Proto']) {
      const v = req.get(h);
      if (v) headers[h] = v;
    }
    // NPM may not have set X-Forwarded-* (e.g. a same-host caller); synthesize
    // them from this request so the publisher always reconstructs the public URL.
    if (!headers['X-Forwarded-Host'])  headers['X-Forwarded-Host']  = req.get('Host') || '';
    if (!headers['X-Forwarded-Proto']) headers['X-Forwarded-Proto'] = req.protocol || 'https';
    const init = { method: req.method, headers };
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      init.body = req.rawBody && req.rawBody.length ? req.rawBody : undefined;
    }
    try {
      const r = await fetch(config.publisherUrl + req.originalUrl, init);
      const buf = Buffer.from(await r.arrayBuffer());
      const ct = r.headers.get('content-type');
      res.status(r.status);
      if (ct) res.set('Content-Type', ct);
      res.send(buf);
    } catch (err) {
      // The loopback publisher being unreachable is a 502 to the peer, who then
      // applies its own fallback (catalog: degrade-open; audit: queue + retry).
      res.status(502).json({ error: 'publisher_unreachable', detail: String(err?.message || err) });
    }
  };
  if (config.bridgeLegs.catalogRead) {
    app.get('/api/v1/catalog/*', forwardToPublisher);
  }
  if (config.bridgeLegs.auditWrite) {
    app.post('/api/audit/events', forwardToPublisher);
  }

  // Everything below requires an authenticated session
  app.use('/admin', requireAuth);

  // Read-only role gate. An operator matched via auth.readonly_users /
  // auth.readonly_groups at sign-in may view but not change anything: every
  // mutating method under /admin is refused (fail-closed -- anything that is
  // not a plain read is blocked). GET SPA assets and the auth routes mounted
  // above this line are unaffected.
  app.use('/admin', (req, res, next) => {
    if (req.session?.user?.role === 'readonly' && !['GET', 'HEAD', 'OPTIONS'].includes(req.method)) {
      return res.status(403).json({ error: 'read-only access: this account can view RepoFabric but not change it.' });
    }
    next();
  });

  // Static SPA assets (the main admin UI; the setup wizard's static tree
  // is intentionally unmounted in normal mode)
  app.use('/admin', express.static(path.join(__dirname, '..', 'static'), {
    setHeaders(res, filepath) {
      // index.html and the SPA bundle are no-store so a redeploy is picked up
      // immediately without a hard refresh. The page references app.js / app.css
      // with no cache-busting query, so without this a stale bundle could hide
      // newly shipped UI. Other assets keep express.static's default revalidation.
      if (filepath.endsWith('index.html') ||
          filepath.endsWith('app.js') ||
          filepath.endsWith('app.css')) {
        res.setHeader('Cache-Control', 'no-store');
      }
    },
  }));

  // Wrap every /admin/api request in a per-request AsyncLocalStorage so
  // pubFetch can forward the operator UPN to the publisher as the
  // X-Rf-Operator-Upn header. Without this the audit fields default
  // to the container's repofabric uid, which is useless for "who did this".
  app.use('/admin/api', (req, _res, next) => {
    const upn = req.session?.user?.upn || null;
    requestContext.run({ upn }, next);
  });

  // Feature flags for the SPA (drives conditional ConfigFabric tab injection).
  // Mounted before apiRouter so the dedicated route wins.
  // docker_socket reports whether per-repo Rewinged spawning is possible (the
  // Docker socket is mounted). The SPA gates the multi-repo controls (add repo,
  // reconcile containers) on this capability rather than on the deployment
  // profile, so a sandbox that opts into the socket gets the controls too.
  app.get('/admin/api/features', (q, s) => s.json({ configfabric: config.configfabric.enabled === true, timezone: currentTimezone(), deployment_profile: config.deploymentProfile, sandbox: config.isSandbox, entra_configured: isEntraConfigured(config.entra), docker_socket: fs.existsSync('/var/run/docker.sock'), http_port: config.publicHttpPort, role: q.session?.user?.role || 'admin' }));

  // Post-setup "Connect Microsoft Entra" wizard (sandbox profile only). Lets an
  // authenticated local admin connect organizational sign-in after first boot.
  // Mounted before apiRouter so these dedicated routes win, and only in the
  // sandbox profile -- a production deploy already runs on Entra.
  if (config.isSandbox) {
    app.use('/admin/api/entra', entraConnectRouter());
    // Settings "Upgrade to Recommended" graduation panel (sandbox profile only;
    // disappears once graduated, since config.isSandbox then flips false).
    app.use('/admin/api/upgrade', upgradeRouter());
  }

  // M2M wiring self-check (RepoFabric#16): booleans + warnings, never secret
  // values. Lets the operator confirm the bolt-on bearer is actually loaded
  // over HTTP instead of grepping logs — the exact silent-401 this would catch.
  app.get('/admin/api/m2m-status', (_q, s) => s.json(m2mReadiness()));

  app.use('/admin/api', apiRouter());

  // --- ConfigFabric absorption: operator API + SPA (post-auth) ------------
  // The CF SPA static assets are vendored under static/cf/ and already served
  // by the /admin static mount above. We add the CF operator API at
  // /admin/cf/api (so the CF SPA's relative `api/...` calls resolve there) with
  // its own per-request UPN context, and a directory redirect for /admin/cf.
  // All flag-gated and behind requireAuth, so one RepoFabric login covers it.
  if (config.configfabric.enabled) {
    app.use('/admin/cf/api', (req, _res, next) => {
      const upn = req.session?.user?.upn || null;
      cfRequestContext.run({ upn }, next);
    });
    app.use('/admin/cf/api', cfApiRouter());
    app.get('/admin/cf', (_req, res) => res.redirect('/admin/cf/'));
  }

  app.get('/admin', (_req, res) => res.redirect('/admin/'));
  app.get('/admin/', (_req, res) => res.sendFile(path.join(__dirname, '..', 'static', 'index.html')));

  app.use('/admin', (req, res) => {
    if (req.path.startsWith('/api/')) return res.status(404).json({ error: `no route ${req.method} ${req.path}` });
    res.status(404).send('Not found');
  });
}

// Default: send unknown paths to /admin or /setup depending on mode
app.get('/', (_req, res) => res.redirect(config.inSetupMode ? '/setup/' : '/admin/'));

// 0.9.0 (FD-031 program): fail fast on a half-set integration. If ConfigFabric
// integration is enabled but a required token is missing, refuse to boot rather
// than silently degrade to 401/503 at runtime. Skipped in setup mode (nothing is
// configured yet). Emergency override: REPOFABRIC_ALLOW_PARTIAL_INTEGRATION=true.
if (!config.inSetupMode) {
  const fatals = m2mFatals();
  if (fatals.length > 0) {
    for (const f of fatals) console.error(`[repofabric-admin] FATAL integration misconfig: ${f}`);
    if (String(process.env.REPOFABRIC_ALLOW_PARTIAL_INTEGRATION || '').trim() === 'true') {
      console.warn('[repofabric-admin] REPOFABRIC_ALLOW_PARTIAL_INTEGRATION=true; booting with a half-set integration (NOT recommended).');
    } else {
      console.error('[repofabric-admin] refusing to start. Set the missing token(s), or CONFIGFABRIC_ENABLED=false, or override with REPOFABRIC_ALLOW_PARTIAL_INTEGRATION=true.');
      process.exit(2);
    }
  }
}

const server = app.listen(config.port, () => {
  console.log(`[repofabric-admin] listening on :${config.port} (setup_mode=${config.inSetupMode})`);
  console.log(`[repofabric-admin] public base URL: ${config.publicBaseUrl}`);
  console.log(`[repofabric-admin] publisher: ${config.publisherUrl}`);
  if (!config.inSetupMode) {
    console.log(`[repofabric-admin] authz: users=${config.auth.allowedUsers.length} groups=${config.auth.allowedGroups.length}`);
    const m = m2mReadiness();
    console.log(`[repofabric-admin] M2M bolt-on: token=${m.boltOnTokenSet ? 'set' : 'UNSET'} configfabric=${m.configfabricEnabled ? 'enabled' : 'disabled'}`);
    console.log(`[repofabric-admin] M2M bridge legs: catalog:read=${m.catalogReadLeg ? 'on' : 'off'} audit:write=${m.auditWriteLeg ? 'on' : 'off'}`);
    for (const w of m.warnings) console.warn(`[repofabric-admin] M2M WARNING: ${w}`);
  }
});

// Installer static server on a separate port. Serves installer binaries on
// host port 8091 so the operator's reverse-proxy host config does not need
// to change. Disabled when REPOFABRIC_INSTALLERS_PORT is set to 0 (testing
// only).
const installersPort = parseInt(process.env.REPOFABRIC_INSTALLERS_PORT || '8091', 10);
const installersRoot = process.env.REPOFABRIC_INSTALLERS_ROOT || '/var/cache/repofabric/installers';
let installerServer = null;
if (installersPort > 0) {
  // Bandwidth measurement layer. Opens (or creates) the metrics SQLite
  // database before the installer server starts taking traffic so the
  // first request can record its row. The nightly rollup scheduler
  // fires at 03:30 UTC, aggregating raw rows older than 90 days into
  // the summary table.
  try {
    initMetrics();
    startRollupSchedule();
  } catch (e) {
    console.error(`[repofabric-admin] failed to initialise metrics layer: ${e.message}`);
  }

  try {
    installerServer = startInstallerServer(installersPort, installersRoot);
  } catch (e) {
    console.error(`[repofabric-admin] failed to start installer server on :${installersPort}: ${e.message}`);
  }
}

function shutdown(sig) {
  console.log(`[repofabric-admin] ${sig} received; shutting down`);
  if (installerServer) {
    installerServer.close(() => {});
  }
  try { closeMetrics(); } catch {}
  server.close(() => process.exit(0));
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
