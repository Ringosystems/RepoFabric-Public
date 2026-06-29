// Post-setup "Connect Microsoft Entra" wizard backend (sandbox profile only).
//
// A sandbox deployment starts with a LOCAL admin account and no Entra. This
// router lets an authenticated admin connect organizational sign-in AFTER the
// fact, without re-running the whole first-run wizard or hand-editing YAML.
//
// The flow mirrors the first-run Entra step: the server hands the operator a
// pre-filled Azure CLI script (the redirect URI derived the SAME way auth.js
// derives it, so the two can never drift), the operator runs it in their own
// Azure Cloud Shell session -- THAT is the interactive Azure login, and no
// secret ever touches this server -- then pastes the three printed values back.
// /connect MERGES them into solution.yaml (preserving the local-admin
// break-glass account and every other setting) and restarts node-admin so the
// new credentials load and sign-in flips from local to Entra.
//
// Mounted only when REPOFABRIC_DEPLOYMENT_PROFILE=sandbox and behind requireAuth,
// so only an already-authenticated admin can drive it.

import { Router } from 'express';
import fs from 'node:fs';
import yaml from 'js-yaml';
import { config, writeYamlAtomic } from './config.js';
import { buildAzScripts, redirectUriFor, isEntraConfigured, mergeEntraAuth } from './entra-helper.js';

// Read the current solution.yaml so /connect can MERGE rather than overwrite.
// Returns { solution, corrupt }. A MISSING file is safe (a fresh {} base). A file
// that is PRESENT but unparseable is NOT safe to overwrite: collapsing it to {}
// here would make the subsequent merge write an auth-only object, destroying
// every other key including the local-admin break-glass hash. So we flag corrupt
// and /connect aborts instead of writing.
function readSolution() {
  if (!fs.existsSync(config.paths.solutionYaml)) return { solution: {}, corrupt: false };
  try {
    return { solution: yaml.load(fs.readFileSync(config.paths.solutionYaml, 'utf8')) || {}, corrupt: false };
  } catch (err) {
    console.error('[entra-connect] solution.yaml is present but unparseable:', err.message);
    return { solution: {}, corrupt: true };
  }
}

// Validate a tenant/client/secret triple with a client-credentials token request.
// Returns { ok, status, body }; throws only on a network/transport failure so the
// caller can distinguish "Entra rejected the creds" (fail the operator) from
// "could not reach Entra" (fail closed, do not commit). Shared by /probe and the
// fail-closed check inside /connect.
async function probeEntra({ tenant_id, client_id, client_secret }) {
  const tokenUrl = `https://login.microsoftonline.com/${encodeURIComponent(String(tenant_id))}/oauth2/v2.0/token`;
  const params = new URLSearchParams();
  params.set('client_id', String(client_id));
  params.set('client_secret', String(client_secret));
  params.set('scope', 'https://graph.microsoft.com/.default');
  params.set('grant_type', 'client_credentials');
  // Bound the request: undici's global fetch has no total-request timeout, so a
  // stalled login.microsoftonline.com would otherwise hang /connect (which awaits
  // this before committing) indefinitely. A timeout rejects the fetch, which the
  // callers turn into a 502 -- fail closed, nothing is written.
  const r = await fetch(tokenUrl, { method: 'POST', body: params, signal: AbortSignal.timeout(10000) });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, body };
}

export function entraConnectRouter() {
  const r = Router();

  // Where the wizard stands: is this a sandbox (local-admin) deployment, is
  // Entra already connected, and what redirect URI must the app registration
  // trust. The redirect URI is derived server-side so the operator cannot get
  // it wrong.
  r.get('/status', (_req, res) => {
    res.json({
      sandbox: config.isSandbox,
      entra_configured: isEntraConfigured(config.entra),
      public_base_url: config.publicBaseUrl,
      redirect_uri: redirectUriFor(config.publicBaseUrl),
      local_admin_username: config.sandbox?.localAdmin?.username || '',
    });
  });

  // Pre-filled Azure CLI bootstrap script. No Azure call happens here; this only
  // returns text the operator pastes into Azure Cloud Shell. Identical generator
  // to the first-run wizard's /setup/api/entra/az-script.
  r.get('/az-script', (_req, res) => {
    try {
      const { redirectUri, displayName, permissions, bash, powershell } = buildAzScripts(config.publicBaseUrl);
      res.json({ ok: true, redirect_uri: redirectUri, display_name: displayName, permissions, bash, powershell });
    } catch (err) {
      res.status(500).json({ ok: false, error: err.message });
    }
  });

  // Validate the three values BEFORE committing them: a client-credentials token
  // request against the tenant. A 200 with an access token proves the
  // tenant/client/secret triple is real and the secret is not mistyped. It does
  // NOT prove admin consent was granted (that surfaces later as 403 on the
  // user/group lookups), which the UI explains.
  r.post('/probe', async (req, res) => {
    const { tenant_id, client_id, client_secret } = req.body || {};
    if (!tenant_id || !client_id || !client_secret) {
      return res.status(400).json({ ok: false, error: 'tenant_id, client_id, and client_secret are all required' });
    }
    try {
      const p = await probeEntra({ tenant_id, client_id, client_secret });
      res.json({ ok: p.ok, status: p.status, expires_in: p.body.expires_in, error: p.ok ? null : p.body });
    } catch (err) {
      res.status(502).json({ ok: false, error: err.message });
    }
  });

  // Commit: merge the credentials into solution.yaml, then restart node-admin so
  // the new config loads and sign-in flips to Entra. The local-admin account is
  // intentionally PRESERVED (mergeEntraAuth never touches solution.sandbox) so it
  // stays available at /admin/auth/local-login as a break-glass fallback.
  r.post('/connect', async (req, res) => {
    const body = req.body || {};
    const tenant_id = String(body.tenant_id || '').trim();
    const client_id = String(body.client_id || '').trim();
    const client_secret = String(body.client_secret || '').trim();
    if (!tenant_id || !client_id || !client_secret) {
      return res.status(400).json({ ok: false, error: 'tenant_id, client_id, and client_secret are all required' });
    }
    try {
      // (1) Refuse to overwrite a present-but-corrupt solution.yaml: doing so
      // would drop every other key, including the local-admin break-glass hash.
      const { solution, corrupt } = readSolution();
      if (corrupt) {
        return res.status(409).json({ ok: false, error: 'solution.yaml is present but could not be parsed. Refusing to overwrite it (that would drop the local-admin break-glass account and other settings). Fix or restore the file, or re-run the first-run setup wizard, then try again.' });
      }

      // (2) Fail closed: validate the credentials with Entra BEFORE committing
      // them. A mistyped secret or wrong tenant must never flip the deployment to
      // a broken Entra sign-in. A non-200 fails the operator (422); an unreachable
      // Entra also aborts (502) rather than committing unproven credentials.
      let probe;
      try {
        probe = await probeEntra({ tenant_id, client_id, client_secret });
      } catch (err) {
        return res.status(502).json({ ok: false, error: `Could not reach Microsoft Entra to validate the credentials, so nothing was changed: ${err.message}` });
      }
      if (!probe.ok) {
        const detail = probe.body?.error_description || probe.body?.error || `HTTP ${probe.status}`;
        return res.status(422).json({ ok: false, error: 'Microsoft Entra rejected these credentials, so nothing was changed. Re-check the tenant, client id, and that you copied the whole client secret.', detail, status: probe.status });
      }

      // (3) Merge into the existing solution (preserves targets, notifications,
      // container, and crucially sandbox.local_admin) and write at 0600 since the
      // file now carries the Entra client secret.
      const merged = mergeEntraAuth(solution, {
        tenant_id,
        client_id,
        client_secret,
        redirect_uri: redirectUriFor(config.publicBaseUrl),
        allowed_users: Array.isArray(body.allowed_users) ? body.allowed_users : [],
        allowed_groups: Array.isArray(body.allowed_groups) ? body.allowed_groups : [],
      });

      // (4) Defense in depth: never write a merge that would drop the break-glass
      // account when it existed at boot. This should be impossible given (1) and
      // mergeEntraAuth preserving solution.sandbox, but the cost of being wrong is
      // a lockout, so guard it explicitly.
      const hadBreakGlass = config.isSandbox && Boolean(config.sandbox?.localAdmin?.passwordHash);
      if (hadBreakGlass && !merged.sandbox?.local_admin?.password_hash) {
        console.error('[entra-connect] aborting: the merge would drop the local-admin break-glass account');
        return res.status(500).json({ ok: false, error: 'Internal safety check failed: refusing to write a configuration that would remove the local-admin break-glass account. Nothing was changed.' });
      }

      writeYamlAtomic(config.paths.solutionYaml, merged, 0o600);
      console.log('[entra-connect] credentials validated and written to solution.yaml; restarting node-admin so sign-in flips to Entra (local-admin retained as break-glass)');
      // Respond BEFORE exiting so the browser receives the OK and can redirect,
      // mirroring the first-run wizard's save handler. supervisord respawns
      // node-admin (autorestart) within a few seconds, reloading config.
      res.json({ ok: true, restarting: true, redirect_to: '/admin/' });
      res.on('finish', () => {
        setTimeout(() => {
          console.log('[entra-connect] exiting now; supervisord will respawn node-admin in Entra mode');
          process.exit(0);
        }, 1500);
      });
    } catch (err) {
      console.error('[entra-connect] connect failed:', err);
      res.status(500).json({ ok: false, error: err.message });
    }
  });

  return r;
}
