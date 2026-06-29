// ConfigFabric absorption: loopback bridge to CF's pwsh listener inside this
// same container (default 127.0.0.1:8089, distinct from RepoFabric's 8085).
// Ported verbatim from ConfigFabric's linux/admin/src/bridge.js, rewired to
// read config.configfabric.* and to use its own AsyncLocalStorage so the CF
// operator UPN is forwarded as X-Cf-Operator-Upn independently of RF's context.
// Cron-driven calls (no browser request in scope) leave the UPN absent and the
// CF publisher falls back to SYSTEM.

import { AsyncLocalStorage } from 'node:async_hooks';
import { config } from './config.js';

export const cfRequestContext = new AsyncLocalStorage();

function publisherUrl(p) { return config.configfabric.publisherUrl + p; }

async function pubFetch(p, init = {}) {
  const headers = new Headers(init.headers || {});
  if (config.configfabric.publisherToken) headers.set('Authorization', `Bearer ${config.configfabric.publisherToken}`);
  headers.set('Accept', 'application/json');
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  const ctx = cfRequestContext.getStore();
  if (ctx && ctx.upn) headers.set('X-Cf-Operator-Upn', ctx.upn);
  const res = await fetch(publisherUrl(p), { ...init, headers });
  const ct = res.headers.get('content-type') || '';
  const body = ct.includes('json') ? await res.json() : await res.text();
  if (!res.ok) {
    const msg = body?.error || `${res.status} ${res.statusText}`;
    const err = new Error(`cf-publisher ${init.method || 'GET'} ${p}: ${msg}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

export const cfBridge = {
  // Shell
  health:            ()   => pubFetch('/api/health'),
  getConfig:         ()   => pubFetch('/api/config'),
  listVirtualRepos:  ()   => pubFetch('/api/virtual-repos'),
  getVirtualRepo:    (id) => pubFetch(`/api/virtual-repos/${encodeURIComponent(id)}`),
  createVirtualRepo: (b)      => pubFetch('/api/virtual-repos', { method: 'POST', body: JSON.stringify(b) }),
  updateVirtualRepo: (id, b)  => pubFetch(`/api/virtual-repos/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(b) }),
  listPublishEvents: (opts = {}) => {
    const qs = new URLSearchParams();
    if (opts.repoId)   qs.set('repoId', opts.repoId);
    if (opts.targetId) qs.set('targetId', opts.targetId);
    const tail = qs.toString();
    return pubFetch('/api/publish-events' + (tail ? `?${tail}` : ''));
  },

  // DSC Config Portal
  listConfigs:        (repoId, includeUnlisted) => pubFetch(`/api/configs?repoId=${encodeURIComponent(repoId)}${includeUnlisted ? '&includeUnlisted=1' : ''}`),
  listConfigVersions: (repoId, cid)    => pubFetch(`/api/config-versions?repoId=${encodeURIComponent(repoId)}&configId=${encodeURIComponent(cid)}`),
  validateConfig:     (yaml)           => pubFetch('/api/configs/validate', { method: 'POST', body: JSON.stringify({ yaml }) }),
  publishConfig:      (yaml, repoId)   => pubFetch('/api/configs/publish',  { method: 'POST', body: JSON.stringify({ yaml, repoId }) }),
  exportConfig:       (repoId, cid, v) => pubFetch(`/api/config-export?repoId=${encodeURIComponent(repoId)}&configId=${encodeURIComponent(cid)}&version=${encodeURIComponent(v)}`),
  promoteConfig:      (b)              => pubFetch('/api/configs/promote',  { method: 'POST', body: JSON.stringify(b) }),
  setConfigLifecycle: (b)              => pubFetch('/api/configs/lifecycle', { method: 'POST', body: JSON.stringify(b) }),
  revertConfig:       (b)              => pubFetch('/api/configs/revert',   { method: 'POST', body: JSON.stringify(b) }),

  // Module Portal
  listModules:        ()         => pubFetch('/api/modules'),
  listModuleVersions: (mid)      => pubFetch(`/api/module-versions?moduleId=${encodeURIComponent(mid)}`),
  gallerySearch:      (q, limit) => pubFetch(`/api/gallery/search?q=${encodeURIComponent(q)}&limit=${encodeURIComponent(limit || 25)}`),
  importGallery:      (b)        => pubFetch('/api/modules/import-gallery', { method: 'POST', body: JSON.stringify(b) }),
  importModuleFile:   (stagedPath) => pubFetch('/api/modules/import-file', { method: 'POST', body: JSON.stringify({ path: stagedPath }) }),

  // Assignments (config -> Entra group)
  listAssignments:  (repoId, cid) => pubFetch(`/api/assignments?repoId=${encodeURIComponent(repoId)}${cid ? `&configId=${encodeURIComponent(cid)}` : ''}`),
  addAssignment:    (b) => pubFetch('/api/assignments',        { method: 'POST', body: JSON.stringify(b) }),
  setAssignment:    (b) => pubFetch('/api/assignments/set',    { method: 'POST', body: JSON.stringify(b) }),
  removeAssignment: (b) => pubFetch('/api/assignments/remove', { method: 'POST', body: JSON.stringify(b) }),

  // Scheduled config bundles
  listScheduledBundles: (repoId)   => pubFetch(`/api/scheduled-bundles?repoId=${encodeURIComponent(repoId)}`),
  getScheduledBundle:   (bundleId) => pubFetch(`/api/scheduled-bundles?bundleId=${encodeURIComponent(bundleId)}`),
  createScheduledBundle: (b)            => pubFetch('/api/scheduled-bundles', { method: 'POST', body: JSON.stringify(b) }),
  updateScheduledBundle: (bundleId, b)  => pubFetch(`/api/scheduled-bundles/${encodeURIComponent(bundleId)}`, { method: 'PATCH', body: JSON.stringify(b) }),
  removeScheduledBundle: (bundleId)     => pubFetch(`/api/scheduled-bundles/${encodeURIComponent(bundleId)}`, { method: 'DELETE' }),

  // Compliance reporting (UI reads + machine-to-machine ingest)
  listComplianceState: (opts = {}) => {
    const qs = new URLSearchParams();
    if (opts.repoId)   qs.set('repoId', opts.repoId);
    if (opts.configId) qs.set('configId', opts.configId);
    if (opts.deviceId) qs.set('deviceId', opts.deviceId);
    if (opts.state)    qs.set('state', opts.state);
    const tail = qs.toString();
    return pubFetch('/api/compliance/state' + (tail ? `?${tail}` : ''));
  },
  listComplianceEvents: (opts = {}) => {
    const qs = new URLSearchParams();
    if (opts.repoId)   qs.set('repoId', opts.repoId);
    if (opts.configId) qs.set('configId', opts.configId);
    if (opts.deviceId) qs.set('deviceId', opts.deviceId);
    if (opts.limit)    qs.set('limit', opts.limit);
    const tail = qs.toString();
    return pubFetch('/api/compliance/events' + (tail ? `?${tail}` : ''));
  },
  ingestCompliance: (report) => pubFetch('/api/compliance/ingest', { method: 'POST', body: JSON.stringify(report) }),

  // Bolt-on lock deletion-evaluation gate (CF#2)
  evaluateDeletion: (body) => pubFetch('/api/v1/locks/evaluate-deletion', { method: 'POST', body: JSON.stringify(body) }),
  overrideDeletion: (body) => pubFetch('/api/v1/locks/override-deletion', { method: 'POST', body: JSON.stringify(body) }),

  // Reporting registry
  listReports: () => pubFetch('/api/reports'),
  runReport: (name, opts = {}) => {
    const qs = new URLSearchParams();
    if (opts.repoId)   qs.set('repoId', opts.repoId);
    if (opts.configId) qs.set('configId', opts.configId);
    if (opts.deviceId) qs.set('deviceId', opts.deviceId);
    if (opts.since)    qs.set('since', opts.since);
    if (opts.limit)    qs.set('limit', opts.limit);
    const tail = qs.toString();
    return pubFetch(`/api/reports/${encodeURIComponent(name)}/data` + (tail ? `?${tail}` : ''));
  },

  // Upstream-update review
  listUpdates:   (all) => pubFetch('/api/updates' + (all ? '?all=1' : '')),
  checkUpdates:  ()    => pubFetch('/api/updates/check',   { method: 'POST' }),
  approveUpdate: (b)   => pubFetch('/api/updates/approve', { method: 'POST', body: JSON.stringify(b) }),

  // Import sources
  listImportSources:    ()      => pubFetch('/api/import-sources'),
  listSourceCandidates: (name)  => pubFetch(`/api/import-sources/${encodeURIComponent(name)}/candidates`),
  importFromSource:     (name, b) => pubFetch(`/api/import-sources/${encodeURIComponent(name)}/import`, { method: 'POST', body: JSON.stringify(b) }),
};
