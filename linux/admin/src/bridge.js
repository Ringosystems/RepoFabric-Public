// Loopback bridge to the pwsh listener at 127.0.0.1:8085. Same shared-secret
// envelope as the v0.6 repofabric-admin, retained for code parity and to keep the
// pwsh side identical to the Windows version. Token surface inside one
// container is theatre, but harmless.

import { AsyncLocalStorage } from 'node:async_hooks';
import { config } from './config.js';

// Per-request actor context. Express middleware in server.js wraps each
// incoming request so any bridge call made while handling the request
// can read the operator UPN, and pubFetch forwards it to the publisher
// as X-Rf-Operator-Upn. The publisher's WebRouter stores this for
// the lifetime of the request so Get-RfCurrentIdentity returns the
// browser-authenticated operator -- not the container's repofabric uid --
// when stamping audit fields on subscriptions / runs / custom events.
export const requestContext = new AsyncLocalStorage();

function publisherUrl(p) { return config.publisherUrl + p; }

async function pubFetch(p, init = {}) {
  const headers = new Headers(init.headers || {});
  if (config.publisherToken) headers.set('Authorization', `Bearer ${config.publisherToken}`);
  headers.set('Accept', 'application/json');
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  // Stamp the operator's UPN onto every loopback call when available.
  // Cron-driven calls (no browser request in scope) leave it absent
  // and the publisher falls back to SYSTEM.
  const ctx = requestContext.getStore();
  if (ctx && ctx.upn) headers.set('X-Rf-Operator-Upn', ctx.upn);
  const res = await fetch(publisherUrl(p), { ...init, headers });
  const ct = res.headers.get('content-type') || '';
  const body = ct.includes('json') ? await res.json() : await res.text();
  if (!res.ok) {
    const msg = body?.error || `${res.status} ${res.statusText}`;
    const err = new Error(`publisher ${init.method || 'GET'} ${p}: ${msg}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

export const bridge = {
  // Virtual repos (Phase C multi-repo)
  listVirtualRepos:   ()        => pubFetch('/api/virtual-repos'),
  getVirtualRepo:     (id)      => pubFetch(`/api/virtual-repos/${id}`),
  addVirtualRepo:     (b)       => pubFetch('/api/virtual-repos',         { method: 'POST', body: JSON.stringify(b) }),
  updateVirtualRepo:  (id, b)   => pubFetch(`/api/virtual-repos/${id}`,   { method: 'PUT',  body: JSON.stringify(b) }),
  removeVirtualRepo:  (id, opts = {}) => pubFetch(
    `/api/virtual-repos/${id}${opts.purge ? '?purge=1' : ''}`, { method: 'DELETE' }),

  // Phase C.e: docker-driver. Reconcile every non-main virtual repo so
  // the live Rewinged containers match the DB state. Returns a per-repo
  // outcome array the UI surfaces in a toast / status banner.
  reconcileVirtualRepoContainers: () =>
    pubFetch('/api/virtual-repos/reconcile', { method: 'POST' }),

  // Phase C.e: live Rewinged container state for one repo. Used by the
  // virtual-repos table to enrich the DB-side status with the runtime
  // state docker reports.
  getVirtualRepoContainer: (id) =>
    pubFetch(`/api/virtual-repos/${id}/container`),

  // Promotions (Phase C.f). List returns the most recent 200 events;
  // create runs Invoke-RfPromote synchronously and returns the outcome.
  listPromotions:  ()  => pubFetch('/api/promotions'),
  createPromotion: (b) => pubFetch('/api/promotions', {
    method: 'POST', body: JSON.stringify(b),
  }),

  // Publish events ledger (Phase D.1). Filter by ?repoId, ?packageId,
  // and/or ?version. Returns the most recent 200 matching rows.
  listPublishEvents: (opts = {}) => {
    const qs = new URLSearchParams();
    if (opts.repoId)    qs.set('repoId',    opts.repoId);
    if (opts.packageId) qs.set('packageId', opts.packageId);
    if (opts.version)   qs.set('version',   opts.version);
    const tail = qs.toString();
    return pubFetch('/api/publish-events' + (tail ? `?${tail}` : ''));
  },

  // Subscriptions (managed)
  listSubscriptions:    ()      => pubFetch('/api/subscriptions'),
  getSubscription:      (id)    => pubFetch(`/api/subscriptions/${id}`),
  addSubscription:      (b)     => pubFetch('/api/subscriptions',       { method: 'POST', body: JSON.stringify(b) }),
  updateSubscription:   (id, b) => pubFetch(`/api/subscriptions/${id}`, { method: 'PUT',  body: JSON.stringify(b) }),
  removeSubscription:   (id, opts = {}) => pubFetch(
    `/api/subscriptions/${id}${opts.keepRepoContent ? '?keep=1' : ''}`, { method: 'DELETE' }),
  forceSyncSubscription: (id)    => pubFetch(`/api/subscriptions/${id}/sync`, { method: 'POST' }),

  // Queue (introspection + control)
  getQueueStatus:    ()        => pubFetch('/api/queue/status'),
  setWorkerPoolSize: (size)    => pubFetch('/api/queue/pool', { method: 'PUT', body: JSON.stringify({ size }) }),

  // Repo catalog (managed + custom + untracked rollup)
  getRepoAll:        ()        => pubFetch('/api/repo/all'),
  refreshCatalog:    ()        => pubFetch('/api/catalog/refresh', { method: 'POST' }),

  // Full per-version inventory of ONE repo, compared against the primary repo
  // (ahead / behind / in-sync per package). Powers the Inventory tab. repoId
  // defaults to primary; primaryRepoId defaults to the configured primary.
  getRepoInventory:  (repoId, primaryRepoId) => {
    const qs = new URLSearchParams();
    if (repoId)        qs.set('repoId', repoId);
    if (primaryRepoId) qs.set('primaryRepoId', primaryRepoId);
    const q = qs.toString();
    return pubFetch('/api/repo/inventory' + (q ? `?${q}` : ''));
  },

  // Universal package/version delete for the Inventory tab. Handles managed,
  // custom, and untracked/orphaned packages via Remove-RfRepoPackage.
  removeRepoPackage: (repoId, packageId, opts = {}) => {
    const qs = [];
    if (opts.version) qs.push('version=' + encodeURIComponent(opts.version));
    if (opts.force)   qs.push('force=1');
    return pubFetch(`/api/repo/${encodeURIComponent(repoId)}/package/${encodeURIComponent(packageId)}${qs.length ? '?' + qs.join('&') : ''}`, { method: 'DELETE' });
  },

  // Primary (baseline) repo for the Inventory comparison.
  getPrimaryRepo:    ()    => pubFetch('/api/settings/primary-repo'),
  setPrimaryRepo:    (b)   => pubFetch('/api/settings/primary-repo', { method: 'PUT', body: JSON.stringify(b || {}) }),

  // Legacy single-config endpoint (Settings tab). Back-compat for the
  // unsplit SPA. /api/config?raw=1 returns { yaml: '...' }; without raw
  // returns the merged config object.
  getConfig:        (raw) => pubFetch('/api/config' + (raw ? '?raw=1' : '')),
  putConfig:        (body) => pubFetch('/api/config', { method: 'PUT', body: JSON.stringify(body) }),

  // Custom packages
  // Unified activity feed (sync runs + admin events) for the Activity tab.
  listActivity:       (last, type) => pubFetch(`/api/activity?last=${encodeURIComponent(last || 50)}&type=${encodeURIComponent(type || 'all')}`),

  // Repo manifest detail (parsed YAML tree) for the Subscriptions tab's
  // structured detail drawer. Used by Managed / Custom / Untracked
  // alike; the cmdlet probes the manifest mount + the upstream sparse
  // clone so untracked rows (which exist only in the upstream cache)
  // still resolve.
  getRepoManifest:    (pkg, ver) => pubFetch(`/api/repo/manifest?packageId=${encodeURIComponent(pkg)}&version=${encodeURIComponent(ver)}`),

  // Bridge service control. The pwsh side exposes these under
  // /api/service/{status,stop,restart} (see WebRouter.ps1). The Node
  // admin never proxied them before phase 2; the legacy 'Operations'
  // tab's Refresh / Restart buttons were 404ing silently. The Activity
  // tab uses status for the periodic probe and restart for the banner
  // recovery button. Stop is wired for parity in case a future UI
  // surfaces it; the action is the same as restart under supervisord.
  // Backup & DR (Phase D.6/D.7). status returns per-repo snapshot
  // counts plus latest snapshot and drill rollups; drill triggers a
  // verify-from-archive end-to-end; snapshot triggers a manual
  // snapshot of the chosen repo (or all if RepoId omitted).
  getBackupStatus:   ()    => pubFetch('/api/backup/status'),
  triggerDrDrill:    (b)   => pubFetch('/api/backup/drill',    { method: 'POST', body: JSON.stringify(b || {}) }),
  triggerSnapshot:   (b)   => pubFetch('/api/backup/snapshot', { method: 'POST', body: JSON.stringify(b || {}) }),

  // Retention cleanup on demand (mirrors the nightly cron). Returns
  // { runId, status, removed, skipped, failed }. Lets operators converge the
  // live version count on each subscription's Retention without waiting for
  // the 02:30 sweep, and surfaces why a version was kept (skipped/failed).
  triggerCleanup:    (b)   => pubFetch('/api/cleanup/run', { method: 'POST', body: JSON.stringify(b || {}) }),

  // Retention cleanup PREVIEW (read-only dry run). Returns the versions
  // retention would evict and the orphaned publication rows it would reconcile,
  // WITHOUT removing anything. Powers the per-repo Reconcile preview-then-apply.
  previewCleanup:    (b)   => pubFetch('/api/cleanup/preview', { method: 'POST', body: JSON.stringify(b || {}) }),

  // Drift detection ledger (Phase D.5). Listing returns pending events
  // plus a pending_count rollup the UI uses for the banner. Acknowledge
  // marks an event resolved without modifying Gitea.
  listDrift:           (opts = {}) => pubFetch('/api/drift' + (opts.includeResolved ? '?include_resolved=1' : '')),
  acknowledgeDrift:    (id, body)  => pubFetch(`/api/drift/${id}/acknowledge`, { method: 'POST', body: JSON.stringify(body || {}) }),
  acknowledgeAllDrift: ()          => pubFetch('/api/drift/acknowledge-all', { method: 'POST' }),

  // Revert a publication (Phase D.4). Removes the manifest from Gitea,
  // marks the publication row rolled_back, appends a 'revert' ledger
  // event. Operator-supplied reason is required and recorded in both.
  revertPublication: (id, body) => pubFetch(`/api/publications/${id}/revert`, { method: 'POST', body: JSON.stringify(body || {}) }),

  // Popularity index (daily winget.run cron). Status is read-only; the
  // refresh button kicks off an async tier 1 run on the publisher and
  // returns 202. resolveUpstreamSearch patches a search_log row when
  // the operator picks a result from the typeahead, so tier 1 of the
  // next cron pass knows to refresh that package's popularity.
  getPopularityStatus:    ()  => pubFetch('/api/popularity/status'),
  refreshPopularity:      ()  => pubFetch('/api/popularity/refresh',         { method: 'POST' }),
  resolveUpstreamSearch:  (b) => pubFetch('/api/upstream/search/resolved',   { method: 'POST', body: JSON.stringify(b) }),

  serviceStatus:      ()       => pubFetch('/api/service/status'),
  serviceRestart:     ()       => pubFetch('/api/service/restart', { method: 'POST' }),

  listCustomPackages: ()       => pubFetch('/api/custom'),
  getCustomPackage:   (id)     => pubFetch(`/api/custom/${id}`),
  updateCustomPackage:(id, body)=> pubFetch(`/api/custom/${id}`, { method: 'PUT',  body: JSON.stringify(body || {}) }),
  // One-click: subscribe to the upstream PackageId that hash-matches
  // this custom row, then remove the custom row + its repo content.
  // Body is optional: { TargetPackageId?, SyncNow? }.
  convertCustomToSubscription: (id, body) => pubFetch(
    `/api/custom/${id}/convert-to-subscription`,
    { method: 'POST', body: JSON.stringify(body || {}) }
  ),
  publishCustom:      (body)   => pubFetch('/api/custom/publish', { method: 'POST', body: JSON.stringify(body) }),
  removeCustomPackage:(id, opts = {}) => pubFetch(
    `/api/custom/${id}${opts.keepRepoContent ? '?keep=1' : ''}`, { method: 'DELETE' }),

  // Schema validation (server-side belt-and-braces before publishing custom)
  validateManifest: (body)     => pubFetch('/api/custom/validate', { method: 'POST', body: JSON.stringify(body) }),

  // Intune Settings Catalog export. Returns { Json, OmaUri, Summary }. The
  // wizard hands Json to the browser as a download; OmaUri populates the
  // optional "show your work" table for operators on the Custom OMA-URI route.
  buildIntunePolicy: (body)    => pubFetch('/api/intune/policy', { method: 'POST', body: JSON.stringify(body) }),

  // Inspect a staged installer and return heuristic metadata (InstallerType,
  // Architecture, default switches, MSI ProductCode etc.) the wizard uses
  // to pre-populate form fields. Called by publish-custom.js after upload.
  inspectInstaller: (body)     => pubFetch('/api/custom/inspect',  { method: 'POST', body: JSON.stringify(body) }),

  // Publications
  listPublications: ()         => pubFetch('/api/publications'),
  removePublication:(id)       => pubFetch(`/api/publications/${id}`, { method: 'DELETE' }),

  // Operations
  syncAll:          (opts)     => pubFetch('/api/sync', { method: 'POST', body: JSON.stringify(opts || {}) }),
  refreshIndex:     ()         => pubFetch('/api/index/refresh', { method: 'POST' }),
  refreshIndexStatus:()        => pubFetch('/api/index/refresh/status'),
  cancelOperation:  (reason)   => pubFetch('/api/operations/cancel', { method: 'POST', body: JSON.stringify({ reason: reason || 'Operator cancelled' }) }),

  // Upstream index (Add Subscription typeahead)
  searchUpstream:     (q, limit = 25) => pubFetch(`/api/upstream/search?q=${encodeURIComponent(q || '')}&limit=${limit}`),
  getUpstreamPackage: (id) => pubFetch(`/api/upstream/package?id=${encodeURIComponent(id)}`),

  // Health
  health: () => pubFetch('/api/health'),
};

