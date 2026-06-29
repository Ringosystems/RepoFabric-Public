// Sandbox -> Recommended graduation backend (sandbox profile only).
//
// A sandbox is a throwaway single-box trial; "Recommended" is the production
// posture: Microsoft Entra sign-in, a real CA certificate behind an external
// reverse proxy, per-repo containers, and persistent host storage. This router
// powers the Settings "Upgrade to Recommended" panel -- a re-runnable READINESS
// CHECK that tests each gap, and a one-time COMPLETE that flips the deployment
// profile to production once every gap is green.
//
// Multi-visit by design (org changes take scheduling), so the check runs live on
// every call. Gaps that cannot be auto-verified from inside the container (a real
// cert behind an external proxy the container may not even be able to resolve;
// storage backing) are satisfied by an operator confirmation persisted in
// solution.yaml. Entra and the docker socket ARE auto-tested for real.
//
// Mounted only when config.isSandbox (i.e. sandbox profile AND not yet graduated),
// behind requireAuth, so only an authenticated sandbox admin can drive it.

import { Router } from 'express';
import fs from 'node:fs';
import tls from 'node:tls';
import https from 'node:https';
import yaml from 'js-yaml';
import { config, writeYamlAtomic } from './config.js';
import { isEntraConfigured } from './entra-helper.js';

// Live client-credentials token probe of the CONFIGURED Entra creds -- the same
// real test the connect wizard runs on pasted values, but against what is actually
// in config. A 200 proves tenant/client/secret are valid. Throws only on transport
// failure (caller treats that as not-ready, fail closed).
async function probeConfiguredEntra() {
  const { tenantId, clientId, clientSecret } = config.entra;
  const tokenUrl = `https://login.microsoftonline.com/${encodeURIComponent(tenantId)}/oauth2/v2.0/token`;
  const params = new URLSearchParams();
  params.set('client_id', clientId);
  params.set('client_secret', clientSecret);
  params.set('scope', 'https://graph.microsoft.com/.default');
  params.set('grant_type', 'client_credentials');
  const r = await fetch(tokenUrl, { method: 'POST', body: params, signal: AbortSignal.timeout(10000) });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}

// HEAD the public URL validating ONLY against real public root CAs. tls.root
// Certificates ignores NODE_EXTRA_CA_CERTS, so the bundled self-signed sandbox CA
// does NOT count as trusted -- this is what distinguishes a real cert from the
// sandbox's. reachable=false means DNS/connect failed (often the container cannot
// resolve its own public hostname), which we treat as "confirm manually".
function probePublicCert() {
  return new Promise((resolve) => {
    let url;
    try { url = new URL(config.publicBaseUrl); } catch { return resolve({ reachable: false, trusted: false, detail: 'No valid public URL is configured.' }); }
    if (url.protocol !== 'https:') return resolve({ reachable: true, trusted: false, detail: 'The public URL is not HTTPS.' });
    const req = https.request({
      host: url.hostname, port: url.port || 443, method: 'HEAD', path: '/',
      servername: url.hostname, ca: tls.rootCertificates, rejectUnauthorized: true, timeout: 8000,
    }, (res) => { res.resume(); resolve({ reachable: true, trusted: true, detail: `${url.host} presents a certificate trusted by a public CA.` }); });
    req.on('timeout', () => req.destroy(new Error('timed out')));
    req.on('error', (e) => {
      const tag = `${e.message} ${e.code || ''}`;
      const dns = /ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ETIMEDOUT/i.test(tag);
      const selfSigned = /self.signed|unable to (verify|get)|DEPTH_ZERO|ERR_TLS|CERT_/i.test(tag);
      resolve({
        reachable: !dns, trusted: false, selfSigned,
        detail: dns
          ? `Could not reach ${url.host} from the server to verify the certificate (the container may not resolve its own public hostname).`
          : (selfSigned ? `${url.host} presents a self-signed / privately-issued certificate.` : `Could not validate the certificate: ${e.message}`),
      });
    });
    req.end();
  });
}

// Is the state dir backed by a docker NAMED VOLUME (throwaway) vs a host bind mount
// (persistent)? /proc/self/mountinfo shows a named volume's source under
// .../docker/volumes/<name>/. Returns true (named), false (bind), or null (unknown).
function stateOnNamedVolume() {
  try {
    const target = process.env.REPOFABRIC_STATE_DIR || '/var/lib/repofabric';
    const lines = fs.readFileSync('/proc/self/mountinfo', 'utf8').split('\n');
    let best = null;
    for (const ln of lines) {
      const mp = ln.split(' ')[4];
      if (mp && (mp === target || target.startsWith(mp + '/'))) {
        if (!best || mp.length > best.mp.length) best = { mp, line: ln };
      }
    }
    if (!best) return null;
    return /\/docker\/volumes\//.test(best.line);
  } catch { return null; }
}

function readSolution() {
  try { return yaml.load(fs.readFileSync(config.paths.solutionYaml, 'utf8')) || {}; }
  catch { return {}; }
}
function confirmedSet() {
  const s = readSolution();
  return new Set(Array.isArray(s.graduation?.confirmed) ? s.graduation.confirmed.map(String) : []);
}

// Run all checks once. Returns the array the UI renders and the /complete gate uses.
async function runChecks() {
  const confirmed = confirmedSet();
  const checks = [];

  // 1. Microsoft Entra sign-in (auto, real token probe).
  if (!isEntraConfigured(config.entra)) {
    checks.push({ key: 'entra', label: 'Microsoft Entra sign-in', status: 'fail', detail: 'Entra is not connected; sign-in is still the local admin account.', remediation: 'Connect Microsoft Entra (the local admin stays as break-glass).', link: './connect-entra.html' });
  } else {
    try {
      const p = await probeConfiguredEntra();
      if (p.ok) checks.push({ key: 'entra', label: 'Microsoft Entra sign-in', status: 'pass', detail: 'Connected, and a live token request to Entra succeeded.' });
      else { const d = p.body?.error_description || p.body?.error || `HTTP ${p.status}`; checks.push({ key: 'entra', label: 'Microsoft Entra sign-in', status: 'fail', detail: `Connected, but Entra rejected the credentials: ${d}`, remediation: 'Re-connect Microsoft Entra with a valid client secret.', link: './connect-entra.html' }); }
    } catch (e) { checks.push({ key: 'entra', label: 'Microsoft Entra sign-in', status: 'fail', detail: `Could not reach Entra to validate the connection: ${e.message}`, remediation: 'Check outbound access to login.microsoftonline.com, then re-run.' }); }
  }

  // 2. Trusted TLS certificate (auto where reachable; else operator-confirmed).
  const cert = await probePublicCert();
  if (cert.trusted) checks.push({ key: 'cert', label: 'Trusted TLS certificate', status: 'pass', detail: cert.detail });
  else if (!cert.reachable) checks.push({ key: 'cert', label: 'Trusted TLS certificate', status: confirmed.has('cert') ? 'pass' : 'confirm', detail: cert.detail, remediation: 'Serve a real CA / Let’s Encrypt certificate via your external reverse proxy, then confirm here.', confirmable: true });
  else checks.push({ key: 'cert', label: 'Trusted TLS certificate', status: 'fail', detail: cert.detail, remediation: 'Replace the self-signed certificate with a real CA / Let’s Encrypt certificate (typically via an external reverse proxy).' });

  // 3. Per-repo containers (docker socket, auto).
  if (fs.existsSync('/var/run/docker.sock')) checks.push({ key: 'docker', label: 'Per-repo containers (docker access)', status: 'pass', detail: 'The docker socket is mounted, so per-repo rewinged containers can be managed.' });
  else checks.push({ key: 'docker', label: 'Per-repo containers (docker access)', status: 'fail', detail: 'The docker socket is not mounted; multi-repo / per-repo routing is unavailable.', remediation: 'Mount /var/run/docker.sock into the container in your production compose.' });

  // 4. Persistent host storage (auto via mountinfo; else operator-confirmed).
  const named = stateOnNamedVolume();
  if (named === false) checks.push({ key: 'storage', label: 'Persistent host storage', status: 'pass', detail: 'State is on a host bind mount that survives teardown.' });
  else if (named === true) checks.push({ key: 'storage', label: 'Persistent host storage', status: 'fail', detail: 'State is on a throwaway docker named volume (wiped on teardown).', remediation: 'Move state / manifests / installers to host bind mounts in your production compose.' });
  else checks.push({ key: 'storage', label: 'Persistent host storage', status: confirmed.has('storage') ? 'pass' : 'confirm', detail: 'Could not auto-detect the storage backing from inside the container.', remediation: 'Confirm state / manifests / installers are on persistent host storage.', confirmable: true });

  return checks;
}

export function upgradeRouter() {
  const r = Router();

  r.get('/readiness', async (_req, res) => {
    try {
      const checks = await runChecks();
      res.json({ ready: checks.every(c => c.status === 'pass'), profile: config.deploymentProfile, checks });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  // Persist an operator confirmation for a gap that cannot be auto-verified.
  r.post('/confirm', (req, res) => {
    const key = String((req.body || {}).key || '');
    const on = (req.body || {}).confirmed !== false;
    if (!['cert', 'storage'].includes(key)) return res.status(400).json({ ok: false, error: 'unknown or non-confirmable check' });
    const sol = readSolution();
    const set = new Set(Array.isArray(sol.graduation?.confirmed) ? sol.graduation.confirmed.map(String) : []);
    if (on) set.add(key); else set.delete(key);
    sol.graduation = { ...(sol.graduation || {}), confirmed: [...set] };
    try { writeYamlAtomic(config.paths.solutionYaml, sol, 0o600); res.json({ ok: true, confirmed: [...set] }); }
    catch (e) { res.status(500).json({ ok: false, error: e.message }); }
  });

  // One-time completion: re-verify EVERY check server-side, then flip the profile
  // to production in solution.yaml and restart node-admin so sign-in becomes
  // Entra-only and the sandbox affordances disappear. Refuses unless all green.
  r.post('/complete', async (_req, res) => {
    let checks;
    try { checks = await runChecks(); } catch (e) { return res.status(500).json({ ok: false, error: e.message }); }
    const failing = checks.filter(c => c.status !== 'pass');
    if (failing.length) {
      return res.status(409).json({ ok: false, error: `Not ready to convert: ${failing.map(c => c.label).join('; ')}. Run the readiness check and resolve every gap first.` });
    }
    try {
      const sol = readSolution();
      sol.deployment_profile = 'production';
      writeYamlAtomic(config.paths.solutionYaml, sol, 0o600);
      console.log('[upgrade] readiness all green; deployment_profile -> production; restarting node-admin (sign-in becomes Entra-only).');
      res.json({ ok: true, restarting: true, redirect_to: '/admin/' });
      res.on('finish', () => setTimeout(() => process.exit(0), 1500));
    } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
  });

  return r;
}
