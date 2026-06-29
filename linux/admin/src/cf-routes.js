// ConfigFabric absorption: the CF operator API, ported from ConfigFabric's
// linux/admin/src/routes.js and rewired into RepoFabric's Node process. Mounted
// at /admin/cf/api (so the vendored CF SPA served at /admin/cf/ resolves its
// relative `api/...` calls here) BEHIND RepoFabric's existing requireAuth gate,
// so one RepoFabric login covers it. Node-side bits (Entra group type-ahead,
// upload staging) reuse RepoFabric's own graph.js / upload.js; everything else
// proxies to CF's loopback pwsh bridge on :8089 via cf-bridge.js.

import { Router } from 'express';
import { cfBridge as bridge } from './cf-bridge.js';
import { currentUser } from './auth.js';
import { searchGroups } from './graph.js';
import { config } from './config.js';
import { uploader, discardUpload } from './upload.js';

function wrap(fn) {
  return async (req, res) => {
    try { await fn(req, res); }
    catch (err) {
      const status = err.status || 500;
      res.status(status).json({ error: err.message, detail: err.body || null });
    }
  };
}

export function cfApiRouter() {
  const r = Router();

  r.get('/me', (req, res) => {
    const u = currentUser(req);
    res.json({ upn: u?.upn || null, name: u?.name || null, authReason: u?.authReason || null });
  });

  r.get('/health',          wrap(async (_q, s) => s.json(await bridge.health())));
  // Merge the CF publisher's redacted config with absorbed admin-side settings.
  // Under absorption RepoFabric carries no CF admin settings block, so expose an
  // empty settings object for UI parity; the ingest token is never surfaced.
  r.get('/config',          wrap(async (_q, s) => {
    const upstream = await bridge.getConfig();
    const merged = { ...(upstream.config || {}), settings: {} };
    s.json({ ...upstream, config: merged });
  }));
  r.get('/virtual-repos',   wrap(async (_q, s) => s.json(await bridge.listVirtualRepos())));
  r.post('/virtual-repos',  wrap(async (q, s) => s.status(201).json(await bridge.createVirtualRepo(q.body || {}))));
  r.get('/virtual-repos/:id', wrap(async (q, s) => s.json(await bridge.getVirtualRepo(q.params.id))));
  r.patch('/virtual-repos/:id', wrap(async (q, s) => s.json(await bridge.updateVirtualRepo(q.params.id, q.body || {}))));
  r.get('/publish-events',  wrap(async (q, s) => s.json(await bridge.listPublishEvents({
    repoId: q.query.repoId, targetId: q.query.targetId,
  }))));

  // DSC Config Portal
  r.get('/configs',          wrap(async (q, s) => s.json(await bridge.listConfigs(q.query.repoId, q.query.includeUnlisted === '1'))));
  r.get('/config-versions',  wrap(async (q, s) => s.json(await bridge.listConfigVersions(q.query.repoId, q.query.configId))));
  r.post('/configs/validate', wrap(async (q, s) => s.json(await bridge.validateConfig(q.body?.yaml || ''))));
  r.post('/configs/publish',  wrap(async (q, s) => s.json(await bridge.publishConfig(q.body?.yaml || '', q.body?.repoId))));
  r.get('/config-export',    wrap(async (q, s) => s.json(await bridge.exportConfig(q.query.repoId, q.query.configId, q.query.version))));
  r.post('/configs/promote',  wrap(async (q, s) => s.json(await bridge.promoteConfig(q.body || {}))));
  r.post('/configs/lifecycle', wrap(async (q, s) => s.json(await bridge.setConfigLifecycle(q.body || {}))));
  r.post('/configs/revert',   wrap(async (q, s) => s.json(await bridge.revertConfig(q.body || {}))));

  // Module Portal
  r.get('/modules',          wrap(async (_q, s) => s.json(await bridge.listModules())));
  r.get('/module-versions',  wrap(async (q, s) => s.json(await bridge.listModuleVersions(q.query.moduleId))));
  r.get('/gallery/search',   wrap(async (q, s) => s.json(await bridge.gallerySearch(q.query.q, q.query.limit))));
  r.post('/modules/import-gallery', wrap(async (q, s) => s.json(await bridge.importGallery(q.body || {}))));
  r.post('/modules/upload', uploader.single('package'), wrap(async (q, s) => {
    if (!q.file) return s.status(400).json({ error: 'no package file in request' });
    try { s.status(201).json(await bridge.importModuleFile(q.file.path)); }
    finally { discardUpload(q.file.upload_id); }
  }));

  // Assignments + Entra group type-ahead (reuses RepoFabric's graph.js)
  r.get('/entra/groups', wrap(async (q, s) => {
    const prefix = config.configfabric.groupPrefix || '';
    const term = (q.query.q || '').trim();
    const groups = await searchGroups(prefix + term);
    s.json({ prefix, groups });
  }));
  r.get('/assignments',          wrap(async (q, s) => s.json(await bridge.listAssignments(q.query.repoId, q.query.configId))));
  r.post('/assignments',         wrap(async (q, s) => s.json(await bridge.addAssignment(q.body || {}))));
  r.post('/assignments/set',     wrap(async (q, s) => s.json(await bridge.setAssignment(q.body || {}))));
  r.post('/assignments/remove',  wrap(async (q, s) => s.json(await bridge.removeAssignment(q.body || {}))));

  // Scheduled config bundles
  r.get('/scheduled-bundles', wrap(async (q, s) => {
    if (q.query.bundleId) return s.json(await bridge.getScheduledBundle(q.query.bundleId));
    s.json(await bridge.listScheduledBundles(q.query.repoId));
  }));
  r.post('/scheduled-bundles',           wrap(async (q, s) => s.status(201).json(await bridge.createScheduledBundle(q.body || {}))));
  r.patch('/scheduled-bundles/:id',      wrap(async (q, s) => s.json(await bridge.updateScheduledBundle(q.params.id, q.body || {}))));
  r.delete('/scheduled-bundles/:id',     wrap(async (q, s) => s.json(await bridge.removeScheduledBundle(q.params.id))));

  // Compliance reporting (operator-facing reads; M2M ingest is in server.js)
  r.get('/compliance/state',  wrap(async (q, s) => s.json(await bridge.listComplianceState({
    repoId: q.query.repoId, configId: q.query.configId, deviceId: q.query.deviceId, state: q.query.state,
  }))));
  r.get('/compliance/events', wrap(async (q, s) => s.json(await bridge.listComplianceEvents({
    repoId: q.query.repoId, configId: q.query.configId, deviceId: q.query.deviceId, limit: q.query.limit,
  }))));

  // Reporting registry
  r.get('/reports',           wrap(async (_q, s) => s.json(await bridge.listReports())));
  r.get('/reports/:name/data', wrap(async (q, s) => s.json(await bridge.runReport(q.params.name, {
    repoId: q.query.repoId, configId: q.query.configId, deviceId: q.query.deviceId,
    since: q.query.since, limit: q.query.limit,
  }))));

  // Upstream-update review
  r.get('/updates',          wrap(async (q, s) => s.json(await bridge.listUpdates(q.query.all === '1'))));
  r.post('/updates/check',   wrap(async (_q, s) => s.json(await bridge.checkUpdates())));
  r.post('/updates/approve', wrap(async (q, s) => s.json(await bridge.approveUpdate(q.body || {}))));

  // Import sources
  r.get('/import-sources',                  wrap(async (_q, s) => s.json(await bridge.listImportSources())));
  r.get('/import-sources/:name/candidates', wrap(async (q, s) => s.json(await bridge.listSourceCandidates(q.params.name))));
  r.post('/import-sources/:name/import',    wrap(async (q, s) => s.json(await bridge.importFromSource(q.params.name, q.body || {}))));

  return r;
}
