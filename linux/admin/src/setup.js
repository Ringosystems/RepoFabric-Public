// First-run setup wizard. Active only while /var/lib/repofabric/setup-mode exists.
// The wizard is gated by a one-time setup token (printed to docker logs and
// written to /var/lib/repofabric/setup-token.txt on first boot). The token sets
// a short-lived cookie scoped to /setup; once verified, the operator walks
// the steps and saves. The save handler writes service.yaml + solution.yaml,
// marks setup complete, deletes the token, and instructs supervisord to
// start cron. The operator is then redirected to /admin/.

import { Router } from 'express';
import fs from 'node:fs';
import path from 'node:path';
import { exec } from 'node:child_process';
import { config, writeYamlAtomic, readSetupToken, markSetupComplete } from './config.js';
import { buildAzScripts, redirectUriFor } from './entra-helper.js';
import { hashPassword } from './local-auth.js';

const SETUP_COOKIE = 'repofabric.setup';

function tokenOk(req) {
  return req.session && req.session.setupAuth === true;
}

// The headless gitea-provision service writes the auto-minted access token to
// REPOFABRIC_GITEA_PAT_FILE. The wizard falls back to it so the operator never
// has to create a token in Gitea or paste one.
function readGiteaPatFile() {
  const f = process.env.REPOFABRIC_GITEA_PAT_FILE;
  if (!f) return '';
  try { return fs.readFileSync(f, 'utf8').trim(); } catch { return ''; }
}

function requireToken(req, res, next) {
  if (tokenOk(req)) return next();
  res.status(401).json({ error: 'setup token required' });
}

export function setupRouter() {
  const r = Router();

  r.get('/state', (_req, res) => {
    // Re-check the setup-mode flag at request time. `config.inSetupMode`
    // is a process-start snapshot; after the operator hits 'Re-enter
    // setup wizard' from the admin Settings tab the flag exists but the
    // snapshot is stale until the container restarts. Reading the
    // filesystem each time keeps the wizard honest.
    const flagExists = fs.existsSync(config.paths.setupModeFlag);
    res.json({
      in_setup_mode: flagExists,
      token_present: Boolean(readSetupToken()),
      entra_seeded: Boolean(config.entra.tenantId && config.entra.clientId && config.entra.clientSecret),
    });
  });

  r.post('/verify-token', (req, res) => {
    const want = readSetupToken();
    const got = String(req.body?.token || '').trim();
    if (!want) return res.status(409).json({ error: 'no setup token exists; container is not in setup mode' });
    if (!got || got !== want) return res.status(403).json({ error: 'invalid token' });
    req.session.setupAuth = true;
    res.json({ ok: true });
  });

  // Probes used by the wizard to validate each step before letting the
  // operator advance. The bridge endpoints used here all run on loopback,
  // so they are reachable even before Entra is configured.
  r.post('/probe/gitea', requireToken, async (req, res) => {
    let { base_url, pat } = req.body || {};
    base_url = base_url || process.env.REPOFABRIC_GITEA_BASE_URL || 'http://repofabric-gitea:3000';
    // No pasted PAT? Fall back to the auto-provisioned token (Layer 2). The
    // operator can leave the field blank.
    if (!pat) pat = readGiteaPatFile();
    if (!pat) return res.status(400).json({ ok: false, error: 'No Gitea token available yet. Leave the field blank to use the auto-provisioned token (it may still be minting on first start), or paste your own.' });
    try {
      // Verify the TOKEN (who-am-I), not a specific repo: the winget-manifests
      // repo is created by the publisher on first publish, so it may not exist
      // at setup time.
      const r2 = await fetch(`${String(base_url).replace(/\/$/, '')}/api/v1/user`, { headers: { Authorization: `token ${pat}` } });
      const body = r2.ok ? await r2.json() : await r2.text();
      res.json({ ok: r2.ok, status: r2.status, user: r2.ok ? body.login : null, detail: r2.ok ? null : body });
    } catch (err) { res.status(502).json({ ok: false, error: err.message }); }
  });

  r.post('/probe/rewinged', requireToken, async (req, res) => {
    const { url } = req.body || {};
    if (!url) return res.status(400).json({ ok: false, error: 'url required' });
    try {
      const r2 = await fetch(String(url).replace(/\/$/, '') + '/information');
      const body = r2.ok ? await r2.json() : await r2.text();
      res.json({ ok: r2.ok, status: r2.status, source_identifier: r2.ok ? body?.Data?.SourceIdentifier : null, detail: r2.ok ? null : body });
    } catch (err) { res.status(502).json({ ok: false, error: err.message }); }
  });

  // Generate the pre-filled Azure CLI bootstrap script the operator runs to
  // create RepoFabric's Entra app registration. The redirect URI is derived
  // server-side from the public base URL (same derivation auth.js uses) so it
  // is always exact. No Azure call happens here -- this only returns text the
  // operator pastes into Azure Cloud Shell. Creating + admin-consenting the app
  // fundamentally requires a Privileged Role Administrator, so there is no
  // server-driven flow that avoids that human step.
  r.get('/entra/az-script', requireToken, (_req, res) => {
    try {
      const { redirectUri, displayName, permissions, bash, powershell } = buildAzScripts(config.publicBaseUrl);
      res.json({ ok: true, redirect_uri: redirectUri, display_name: displayName, permissions, bash, powershell });
    } catch (err) {
      res.status(500).json({ ok: false, error: err.message });
    }
  });

  r.post('/probe/entra', requireToken, async (req, res) => {
    const { tenant_id, client_id, client_secret } = req.body || {};
    if (!tenant_id || !client_id || !client_secret) return res.status(400).json({ ok: false, error: 'tenant_id, client_id, client_secret required' });
    try {
      const tokenUrl = `https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/token`;
      const params = new URLSearchParams();
      params.set('client_id', client_id);
      params.set('client_secret', client_secret);
      params.set('scope', 'https://graph.microsoft.com/.default');
      params.set('grant_type', 'client_credentials');
      const r2 = await fetch(tokenUrl, { method: 'POST', body: params });
      const body = await r2.json();
      res.json({ ok: r2.ok, status: r2.status, expires_in: body.expires_in, error: r2.ok ? null : body });
    } catch (err) { res.status(502).json({ ok: false, error: err.message }); }
  });

  r.post('/save', requireToken, (req, res) => {
    const body = req.body || {};
    try {
      const service = {
        defaults: {
          preferred_architectures: arr(body.defaults?.preferred_architectures, ['x64', 'x86', 'arm64']),
          locales: arr(body.defaults?.locales, ['en-US']),
          retention_count: int(body.defaults?.retention_count, 3),
          scope: str(body.defaults?.scope, 'machine'),
        },
        sync: {
          worker_pool_size: clamp(int(body.sync?.worker_pool_size, 4), 1, 32),
          schedule_cron: str(body.sync?.schedule_cron, '0 */6 * * *'),
          index_refresh_threshold_hours: int(body.sync?.index_refresh_threshold_hours, 6),
        },
        cache: {
          cleanup_threshold_gb: int(body.cache?.cleanup_threshold_gb, 50),
          staging_max_age_days: int(body.cache?.staging_max_age_days, 7),
        },
        notifications: { heartbeat_cron: str(body.notifications?.heartbeat_cron, '0 8 * * *') },
        logging: { level: str(body.logging?.level, 'info') },
      };

      const solution = {
        auth: {
          tenant_id:     str(body.auth?.tenant_id, ''),
          client_id:     str(body.auth?.client_id, ''),
          client_secret: str(body.auth?.client_secret, ''),
          redirect_uri:  str(body.auth?.redirect_uri, redirectUriFor(config.publicBaseUrl)),
          allowed_users:  arr(body.auth?.allowed_users, []).map(String).map(s => s.toLowerCase()),
          allowed_groups: arr(body.auth?.allowed_groups, []).map(g => ({ id: String(g.id), display_name: String(g.display_name || g.id) })),
          readonly_users:  arr(body.auth?.readonly_users, []).map(String).map(s => s.toLowerCase()),
          readonly_groups: arr(body.auth?.readonly_groups, []).map(g => ({ id: String(g.id), display_name: String(g.display_name || g.id) })),
        },
        targets: {
          gitea_base_url:      str(body.targets?.gitea_base_url, ''),
          gitea_repo:          str(body.targets?.gitea_repo, 'repofabric-publisher/winget-manifests'),
          gitea_pat:           str(body.targets?.gitea_pat, ''),
          rewinged_url:        str(body.targets?.rewinged_url, ''),
          installer_base_url:  str(body.targets?.installer_base_url, ''),
          manifest_mount_path: str(body.targets?.manifest_mount_path, '/var/cache/repofabric/manifests'),
        },
        notifications: {
          smtp: {
            host: str(body.notifications?.smtp?.host, ''),
            port: int(body.notifications?.smtp?.port, 25),
            from: str(body.notifications?.smtp?.from, ''),
            to:   arr(body.notifications?.smtp?.to, []).map(String),
          },
        },
        container: {
          public_url: config.publicBaseUrl,
          upload_max_bytes: int(body.container?.upload_max_bytes, 2147483648),
        },
      };

      // Sandbox profile only: persist the local-admin credential as a scrypt
      // hash (never plaintext) under solution.sandbox.local_admin. Written only
      // when a password is supplied, so a production solution.yaml never grows a
      // `sandbox` key. The deployment profile itself comes from the env var, not
      // from here.
      const localPw = str(body.sandbox?.local_admin?.password, '');
      if (config.isSandbox && localPw) {
        solution.sandbox = {
          local_admin: {
            username: str(body.sandbox?.local_admin?.username, 'admin'),
            password_hash: hashPassword(localPw),
          },
        };
      }

      writeYamlAtomic(config.paths.serviceYaml, service);
      // solution.yaml carries the Gitea PAT and the Entra client secret; 0600.
      writeYamlAtomic(config.paths.solutionYaml, solution, 0o600);
      markSetupComplete();

      // Tell supervisord to start cron and respawn node-admin so the new
      // /admin/* routes mount and Entra auth picks up the secrets we just
      // wrote. We must send the response BEFORE the exit, otherwise the
      // client never sees the OK and the wizard SPA cannot redirect.
      // supervisord groups programs under repofabric:* so the program must be
      // referenced with its group qualifier; bare 'cron' returns "no such
      // process". See repofabric.conf [group:repofabric].
      exec('supervisorctl -c /etc/supervisor/conf.d/repofabric.conf start repofabric:cron', err => {
        if (err) console.warn('[setup] supervisorctl start repofabric:cron warning:', err.message);
      });

      console.log('[setup] setup.complete written; exiting to let supervisord respawn node-admin in normal mode');
      res.json({ ok: true, restarting: true });
      res.on('finish', () => {
        // 1.5 second grace so the browser actually receives the OK before
        // we exit. supervisord respawns us within 3 seconds (startsecs).
        setTimeout(() => {
          console.log('[setup] exiting now, supervisord will respawn');
          process.exit(0);
        }, 1500);
      });
    } catch (err) {
      console.error('[setup] save failed:', err);
      res.status(500).json({ ok: false, error: err.message });
    }
  });

  return r;
}

function str(v, dflt) { const s = (v === undefined || v === null) ? '' : String(v); return s || dflt; }
function int(v, dflt) { const n = parseInt(v, 10); return Number.isFinite(n) ? n : dflt; }
function arr(v, dflt) { return Array.isArray(v) ? v : dflt; }
function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)); }
