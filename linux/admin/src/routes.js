// Authenticated JSON API mounted at /admin/api. Each handler either
// proxies to the pwsh bridge, or talks directly to Graph for typeahead,
// or reads/writes the YAML config files.

import { Router } from 'express';
import fs from 'node:fs';
import yaml from 'js-yaml';
import { bridge } from './bridge.js';
import { config, reEnterSetupMode } from './config.js';
import { searchUsers, searchGroups, probeGraph } from './graph.js';
import { uploader, discardUpload } from './upload.js';
import {
  getHeadlineSummary,
  getTimeSeries,
  getSubnetEffectiveness,
  getTopInstallers,
} from './metrics.js';
import {
  buildClientConfigScript,
  clientConfigFilename,
  repoSourceName,
} from './clientconfig.js';
import {
  buildIntunePolicyScript,
  intunePolicyScriptFilename,
} from './intunepolicyscript.js';
import {
  buildPeerCacheDiagScript,
  peerCacheDiagFilename,
} from './peercachediag.js';
import { aboutInfo } from './about.js';

export function apiRouter() {
  const r = Router();

  r.get('/me', (req, res) => res.json({
    identity:   req.session.user?.upn || 'unknown',
    name:       req.session.user?.name,
    authReason: req.session.user?.authReason,
    tenant:     req.session.user?.tid,
  }));

  // -- About / licensing (Settings -> About) --------------------------
  // Product identity + running version. The license and third-party notice
  // TEXT is served as static files under static/about/ (see about.js); this
  // endpoint just returns the identity JSON and the URLs the SPA fetches.
  r.get('/about', (_q, s) => s.json(aboutInfo()));

  // -- Virtual repos (Phase C multi-repo) ------------------------------
  r.get('/virtual-repos',         wrap(async (_q, s) => s.json(await bridge.listVirtualRepos())));
  // Phase C.e: reconcile + per-repo container status. Reconcile is
  // declared BEFORE the /:id GET route only out of habit; routing here
  // separates by verb anyway (POST vs GET) so order is moot. The
  // container route uses /:id/container so it doesn't collide.
  r.post('/virtual-repos/reconcile',    wrap(async (_q, s) => s.json(await bridge.reconcileVirtualRepoContainers())));
  r.get('/virtual-repos/:id/container', wrap(async (q, s)  => s.json(await bridge.getVirtualRepoContainer(q.params.id))));
  r.get('/virtual-repos/:id',     wrap(async (q, s)  => s.json(await bridge.getVirtualRepo(q.params.id))));
  r.post('/virtual-repos',        wrap(async (q, s)  => s.status(201).json(await bridge.addVirtualRepo(q.body || {}))));
  r.put('/virtual-repos/:id',     wrap(async (q, s)  => s.json(await bridge.updateVirtualRepo(q.params.id, q.body || {}))));
  r.delete('/virtual-repos/:id',  wrap(async (q, s)  => s.json(await bridge.removeVirtualRepo(q.params.id, { purge: q.query.purge === '1' }))));

  // -- Promotions (Phase C.f) ------------------------------------------
  r.get('/promotions',  wrap(async (_q, s) => s.json(await bridge.listPromotions())));
  r.post('/promotions', wrap(async (q, s)  => s.status(201).json(await bridge.createPromotion(q.body || {}))));

  // -- Publish events ledger (Phase D.1) -------------------------------
  // Read-only view. The ledger itself is written by Invoke-RfPublish /
  // Invoke-RfPromote on success; future revert / restore actions append
  // their own event types here.
  r.get('/publish-events', wrap(async (q, s) => s.json(await bridge.listPublishEvents({
    repoId:    q.query.repoId,
    packageId: q.query.packageId,
    version:   q.query.version,
  }))));

  // -- Subscriptions ---------------------------------------------------
  r.get('/subscriptions',           wrap(async (_q, s) => s.json(await bridge.listSubscriptions())));
  r.get('/subscriptions/:id',       wrap(async (q, s)  => s.json(await bridge.getSubscription(q.params.id))));
  r.post('/subscriptions',          wrap(async (q, s)  => s.status(201).json(await bridge.addSubscription(q.body || {}))));
  r.put('/subscriptions/:id',       wrap(async (q, s)  => s.json(await bridge.updateSubscription(q.params.id, q.body || {}))));
  r.delete('/subscriptions/:id',    wrap(async (q, s)  => s.json(await bridge.removeSubscription(q.params.id, { keepRepoContent: q.query.keep === '1' }))));
  r.post('/subscriptions/:id/sync', wrap(async (q, s)  => s.json(await bridge.forceSyncSubscription(q.params.id))));

  // -- Unified repo view (managed + custom + untracked) ---------------
  r.get('/repo/all',         wrap(async (_q, s) => s.json(await bridge.getRepoAll())));
  r.get('/repo/manifest',    wrap(async (q, s)  => s.json(await bridge.getRepoManifest(q.query.packageId, q.query.version))));
  r.post('/catalog/refresh', wrap(async (_q, s) => s.json(await bridge.refreshCatalog())));

  // Full per-version inventory of one repo, compared against the primary repo.
  r.get('/repo/inventory',   wrap(async (q, s)  => s.json(await bridge.getRepoInventory(q.query.repoId, q.query.primaryRepoId))));
  // Universal delete from the Inventory tab: a whole package or one version,
  // across managed / custom / untracked. ?version=X for one version; ?force=1
  // overrides a denying ConfigFabric lock gate.
  r.delete('/repo/:repoId/package/:packageId', wrap(async (q, s) => s.json(await bridge.removeRepoPackage(q.params.repoId, q.params.packageId, { version: q.query.version, force: q.query.force === '1' }))));

  // Primary (baseline) repo for the Inventory comparison.
  r.get('/settings/primary-repo', wrap(async (_q, s) => s.json(await bridge.getPrimaryRepo())));
  r.put('/settings/primary-repo', wrap(async (q, s)  => s.json(await bridge.setPrimaryRepo(q.body || {}))));

  // -- Custom packages -------------------------------------------------
  r.get('/custom',          wrap(async (_q, s) => s.json(await bridge.listCustomPackages())));
  r.get('/custom/:id',      wrap(async (q, s)  => s.json(await bridge.getCustomPackage(q.params.id))));
  r.put('/custom/:id',      wrap(async (q, s)  => s.json(await bridge.updateCustomPackage(q.params.id, q.body || {}))));
  r.delete('/custom/:id',   wrap(async (q, s)  => s.json(await bridge.removeCustomPackage(q.params.id, { keepRepoContent: q.query.keep === '1' }))));
  r.post('/custom/:id/convert-to-subscription', wrap(async (q, s) => s.status(201).json(await bridge.convertCustomToSubscription(q.params.id, q.body || {}))));
  r.post('/custom/validate',wrap(async (q, s)  => s.json(await bridge.validateManifest(q.body || {}))));
  r.post('/custom/inspect', wrap(async (q, s) => {
    const meta = await bridge.inspectInstaller(q.body || {});
    // Merge the operator-configured PackageIdentifier prefix from
    // service.yaml so the wizard can build <prefix>.<Subject-no-spaces>
    // without a second round-trip. Empty string means "no prefix
    // configured; fall back to Manufacturer / Publisher".
    const svc = readYaml(config.paths.serviceYaml);
    if (meta && typeof meta === 'object') {
      meta.PackageIdentifierPrefix = String(svc?.custom_publish?.package_identifier_prefix || '').trim();
    }
    s.json(meta);
  }));
  r.post('/custom/publish', wrap(async (q, s)  => s.status(201).json(await bridge.publishCustom(q.body || {}))));

  // Installer upload: returns { upload_id, path, sha256, size_bytes }.
  // The publish-custom step references upload ids in its manifest payload.
  r.post('/custom/upload', uploader.single('installer'), wrap(async (q, s) => {
    if (!q.file) return s.status(400).json({ error: 'no installer file in request' });
    s.status(201).json(q.file);
  }));
  r.delete('/custom/upload/:id', wrap(async (q, s) => { discardUpload(q.params.id); s.json({ ok: true }); }));

  // -- Queue / parallelism --------------------------------------------
  r.get('/queue/status',    wrap(async (_q, s) => s.json(await bridge.getQueueStatus())));
  r.put('/queue/pool',      wrap(async (q, s)  => s.json(await bridge.setWorkerPoolSize(Number(q.body?.size) || 4))));

  // -- Publications / Runs --------------------------------------------
  r.get('/publications',        wrap(async (_q, s) => s.json(await bridge.listPublications())));
  r.delete('/publications/:id', wrap(async (q, s)  => s.json(await bridge.removePublication(q.params.id))));
  r.post('/publications/:id/revert', wrap(async (q, s) => s.json(await bridge.revertPublication(q.params.id, q.body || {}))));

  // -- Backup & DR drill (Phase D.6/D.7) ------------------------------
  r.get('/backup/status',    wrap(async (_q, s) => s.json(await bridge.getBackupStatus())));
  r.post('/backup/drill',    wrap(async (q, s) => s.json(await bridge.triggerDrDrill(q.body || {}))));
  r.post('/backup/snapshot', wrap(async (q, s) => s.json(await bridge.triggerSnapshot(q.body || {}))));

  // -- Retention cleanup on demand -------------------------------------
  r.post('/cleanup/run',     wrap(async (q, s) => s.json(await bridge.triggerCleanup(q.body || {}))));
  // Read-only preview (dry run) for the per-repo Reconcile preview-then-apply.
  r.post('/cleanup/preview', wrap(async (q, s) => s.json(await bridge.previewCleanup(q.body || {}))));

  // -- Drift detection (Phase D.5) ------------------------------------
  r.get('/drift',                  wrap(async (q, s) => s.json(await bridge.listDrift({ includeResolved: q.query.include_resolved === '1' }))));
  r.post('/drift/acknowledge-all', wrap(async (_q, s) => s.json(await bridge.acknowledgeAllDrift())));
  r.post('/drift/:id/acknowledge', wrap(async (q, s) => s.json(await bridge.acknowledgeDrift(q.params.id, q.body || {}))));
  r.get('/activity',            wrap(async (q, s)  => s.json(await bridge.listActivity(q.query.last || 50, q.query.type || 'all'))));

  // Bridge service control. Status powers the Activity tab's nav indicator
  // and banner; restart is wired to the banner button when the indicator
  // is red. A 'stop' route used to live here too but it was a no-op alias
  // for restart (single-container, supervisord autorestart=true).
  r.get('/service/status',  wrap(async (_q, s) => s.json(await bridge.serviceStatus())));
  r.post('/service/restart',wrap(async (_q, s) => s.status(202).json(await bridge.serviceRestart())));

  // -- Intune Settings Catalog export (no Graph push) -----------------
  r.post('/intune/policy', wrap(async (q, s) => s.json(await bridge.buildIntunePolicy(q.body || {}))));

  // -- Per-repo client configuration scripts (non-Intune deploy path) --
  // For each winget repo, a standalone PS 5/7 script that registers the
  // source, applies silent defaults, and (when peerdist is on) configures
  // BranchCache/BITS/DO peer caching. The peerdist default and installer
  // host are read fresh from service.yaml so they track the Settings tab.
  r.get('/client-config', wrap(async (_q, s) => {
    const repos = await resolveRepoTargets();
    s.json({
      peerdistEnabled: clientConfigPeerdistEnabled(),
      installerHost:   clientConfigInstallerHost(),
      targets:         buildClientConfigTargetList(repos),
    });
  }));
  r.get('/client-config/:repoId/script', wrap(async (q, s) => {
    const repos = await resolveRepoTargets();
    const repo = (repos || []).find(r0 =>
      String(r0.RepoId || r0.repoId) === String(q.params.repoId));
    if (!repo) { s.status(404).json({ error: `no repo '${q.params.repoId}'` }); return; }
    const { url } = repoSourceInfo(repo);
    if (!url) { s.status(409).json({ error: `repo '${q.params.repoId}' has no resolvable source URL` }); return; }
    const ps = buildClientConfigScript({
      repo,
      sourceUrl:       url,
      sourceName:      repoSourceName(repo),
      peerdistEnabled: clientConfigPeerdistEnabled(),
      installerSite:   clientConfigInstallerSite(),
    });
    s.setHeader('Content-Type', 'text/plain; charset=utf-8');
    s.setHeader('Content-Disposition', `attachment; filename="${clientConfigFilename(repo)}"`);
    s.send(ps);
  }));

  // Separate artifact: applies the DesktopAppInstaller POLICY stack locally
  // (the Intune Settings Catalog equivalent, written to the GP registry).
  // Deliberately NOT combined with the client-config script above.
  r.get('/intune-policy-script/:repoId/script', wrap(async (q, s) => {
    const repos = await resolveRepoTargets();
    const repo = (repos || []).find(r0 =>
      String(r0.RepoId || r0.repoId) === String(q.params.repoId));
    if (!repo) { s.status(404).json({ error: `no repo '${q.params.repoId}'` }); return; }
    const { url } = repoSourceInfo(repo);
    if (!url) { s.status(409).json({ error: `repo '${q.params.repoId}' has no resolvable source URL` }); return; }
    const ps = buildIntunePolicyScript({
      repo,
      sourceUrl:        url,
      sourceName:       repoSourceName(repo),
      sourceIdentifier: `RfPrivate.${String(repo.RepoId || repo.repoId)}`,
    });
    s.setHeader('Content-Type', 'text/plain; charset=utf-8');
    s.setHeader('Content-Disposition', `attachment; filename="${intunePolicyScriptFilename(repo)}"`);
    s.send(ps);
  }));

  // Read-only client diagnostic: proves where installer bytes actually came
  // from (LAN peers / cache vs origin server) via BranchCache + DO counters,
  // with an optional live A/B download test against this repo's source.
  r.get('/peer-cache-script/:repoId/script', wrap(async (q, s) => {
    const repos = await resolveRepoTargets();
    const repo = (repos || []).find(r0 =>
      String(r0.RepoId || r0.repoId) === String(q.params.repoId));
    if (!repo) { s.status(404).json({ error: `no repo '${q.params.repoId}'` }); return; }
    const ps = buildPeerCacheDiagScript({ repo, sourceName: repoSourceName(repo) });
    s.setHeader('Content-Type', 'text/plain; charset=utf-8');
    s.setHeader('Content-Disposition', `attachment; filename="${peerCacheDiagFilename(repo)}"`);
    s.send(ps);
  }));

  // -- Operations ------------------------------------------------------
  r.post('/sync',                wrap(async (q, s) => s.json(await bridge.syncAll(q.body || {}))));
  r.post('/index/refresh',       wrap(async (_q, s) => s.json(await bridge.refreshIndex())));
  r.get('/index/refresh/status', wrap(async (_q, s) => s.json(await bridge.refreshIndexStatus())));
  r.post('/operations/cancel',   wrap(async (q, s) => s.json(await bridge.cancelOperation(q.body?.reason))));

  // -- Upstream index (Add Subscription typeahead) --------------------
  r.get('/upstream/search',  wrap(async (q, s) => s.json(await bridge.searchUpstream(q.query.q, Number(q.query.limit) || 25))));
  r.get('/upstream/package', wrap(async (q, s) => s.json(await bridge.getUpstreamPackage(q.query.id))));
  // Operator picked a result; tells the publisher which package_id the
  // last query resolved to so tier 1 of the popularity cron can promote
  // it. Best-effort; never blocks the UI.
  r.post('/upstream/search/resolved', wrap(async (q, s) => s.status(204).json(await bridge.resolveUpstreamSearch(q.body || {}))));

  // -- Popularity index (Search popularity card in Settings) ----------
  r.get('/popularity/status',  wrap(async (_q, s) => s.json(await bridge.getPopularityStatus())));
  r.post('/popularity/refresh', wrap(async (_q, s) => s.status(202).json(await bridge.refreshPopularity())));

  // -- Unified config endpoint (admin Settings tab) -------------------
  r.get('/config', wrap(async (q, s) => {
    const raw = q.query.raw === '1';
    s.json(await bridge.getConfig(raw));
  }));
  r.put('/config', wrap(async (q, s) => s.json(await bridge.putConfig(q.body || {}))));

  // -- Solution-only GET (used by intune-deploy.js for the Entra/Gitea
  //    target fields) ------------------------------------------------
  r.get('/config/solution', wrap(async (_q, s) => {
    const v = readYaml(config.paths.solutionYaml);
    if (v?.auth?.client_secret) delete v.auth.client_secret;
    s.json(v);
  }));

  // -- Graph helpers for the Solution Configuration tab ---------------
  r.get('/graph/users/search',  wrap(async (q, s) => s.json(await searchUsers(q.query.q, Number(q.query.top) || 10))));
  r.get('/graph/groups/search', wrap(async (q, s) => s.json(await searchGroups(q.query.q, Number(q.query.top) || 10))));
  r.get('/graph/probe',         wrap(async (_q, s) => s.json(await probeGraph())));

  // -- Bandwidth dashboard (0.8.0 Wave 16) ----------------------------
  // Reads from the Node-owned metrics.db. Bypasses the pwsh bridge so
  // dashboard rendering does not contend with the queue / publish path.
  // Window defaults: 30 days for headline numbers, 90 days for time
  // series. Operators can override via ?days= but the kill switch on
  // the input is the 90-day raw retention upstream.
  r.get('/bandwidth/summary', wrap(async (q, s) => {
    const days = Math.max(1, Math.min(90, Number(q.query.days) || 30));
    s.json(getHeadlineSummary({ windowDays: days }));
  }));
  r.get('/bandwidth/timeseries', wrap(async (q, s) => {
    const days = Math.max(1, Math.min(90, Number(q.query.days) || 90));
    s.json(getTimeSeries({ windowDays: days }));
  }));
  r.get('/bandwidth/subnets', wrap(async (q, s) => {
    const days = Math.max(1, Math.min(90, Number(q.query.days) || 30));
    s.json(getSubnetEffectiveness({ windowDays: days }));
  }));
  r.get('/bandwidth/installers', wrap(async (q, s) => {
    const days  = Math.max(1, Math.min(90, Number(q.query.days)  || 30));
    const limit = Math.max(1, Math.min(100, Number(q.query.limit) || 20));
    s.json(getTopInstallers({ windowDays: days, limit }));
  }));

  // -- Health ---------------------------------------------------------
  r.get('/health',           wrap(async (_q, s) => s.json(await bridge.health())));

  // Re-enter the first-run wizard. Touches the setup-mode flag and
  // generates a fresh setup token (printed to the container console
  // so the operator picks it up the same way as on first boot).
  // Authenticated route -- the operator must already be in the admin
  // session, which is the right gate: anyone who can hit this endpoint
  // has already passed Entra. Returns the token in the JSON response
  // for convenience; the UI shows it inside the modal that pops up.
  r.post('/setup/re-enter', wrap(async (_q, s) => {
    const { token } = reEnterSetupMode();
    s.json({ ok: true, token });
  }));

  return r;
}

function readYaml(file) {
  try {
    if (!fs.existsSync(file)) return {};
    return yaml.load(fs.readFileSync(file, 'utf8')) || {};
  } catch (err) {
    console.error('[routes] readYaml failed for', file, err.message);
    return {};
  }
}

// Read the peerdist flag fresh from service.yaml so generated client scripts
// track the Settings tab without needing a process restart.
function clientConfigPeerdistEnabled() {
  const svc = readYaml(config.paths.serviceYaml);
  return svc?.installers?.peerdist?.enabled === true;
}

// Installer endpoint hostname (informational, for the client-config meta UI).
function clientConfigInstallerHost() {
  const base = config.targets?.installerBaseUrl || '';
  try { return base ? new URL(base).hostname : ''; } catch { return ''; }
}

// Installer site origin (scheme://host[:port]) for generated scripts: the value
// mapped into the Intranet Zone. The port is included when non-default, which a
// non-standard-port deployment needs (the per-host zone map cannot express a port).
function clientConfigInstallerSite() {
  const base = config.targets?.installerBaseUrl || '';
  try { const u = new URL(base); return base ? (u.protocol + '//' + u.host) : ''; } catch { return ''; }
}

// Public origin of the deployment. The admin is served at
// <publicBaseUrl> (e.g. https://winget.<domain>/admin/) and the winget REST
// API shares that host, so the shared origin is the source host for
// subdirectory routing.
function publicOrigin() {
  try { return new URL(config.publicBaseUrl).origin; } catch { return null; }
}

// Resolve a repo's public winget REST source URL.
//   - FQDN mode: if the repo has an explicit Hostname, use
//     https://<Hostname>/api/ (a dedicated host for the repo).
//   - Subdirectory mode (default): serve EVERY repo from the shared public
//     host under a uniform per-repo path /<repoId>/api/ (including the default
//     'main' repo, at /main/api/). The repoId is unique, so the path is
//     unique. The reverse proxy must route /<repoId>/ to that repo's Rewinged
//     container.
function repoSourceInfo(repo) {
  const host = repo.Hostname || repo.hostname;
  if (host) {
    const scheme = /^https?:\/\//i.test(host) ? '' : 'https://';
    return { url: (scheme + String(host)).replace(/\/+$/, '') + '/api/', mode: 'fqdn' };
  }
  const origin = publicOrigin();
  if (!origin) return { url: null, mode: 'none' };
  const id = String(repo.RepoId || repo.repoId || '');
  if (!id) return { url: null, mode: 'none' };
  return { url: `${origin}/${id}/api/`, mode: 'subdir' };
}

// Repos to generate client scripts for. The bridge wraps them as
// { virtualRepos: [...] }.
async function resolveRepoTargets() {
  let resp = null;
  try { resp = await bridge.listVirtualRepos(); } catch { resp = null; }
  return Array.isArray(resp) ? resp : (resp?.virtualRepos || resp?.repos || []);
}

// Build the per-repo descriptor list the UI card renders.
function buildClientConfigTargetList(repos) {
  return repos.map(repo => {
    const { url, mode } = repoSourceInfo(repo);
    return {
      repoId:      repo.RepoId || repo.repoId || null,
      displayName: repo.DisplayName || repo.displayName || repo.RepoId || repo.repoId || 'repo',
      sourceUrl:   url,
      sourceName:  repoSourceName(repo),
      filename:    clientConfigFilename(repo),
      mode,
      ready:       !!url,
      note:        url
        ? (mode === 'subdir' ? 'subdirectory route — your reverse proxy must map this path to the repo' : null)
        : 'no public base URL configured and no Hostname set',
    };
  });
}

function wrap(handler) {
  return async (req, res) => {
    try { await handler(req, res); }
    catch (err) {
      const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
      res.status(status).json({ error: err.message, detail: err.body || null });
    }
  };
}
