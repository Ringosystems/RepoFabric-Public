// Entra OAuth2 (auth-code with PKCE) plus a users-OR-groups authorisation
// model. A user is admitted when their UPN appears in allowed_users OR
// when any group claim matches allowed_groups[].id. When the id_token
// indicates groups-claim overage (_claim_names.groups), we fall back to
// a Microsoft Graph membership lookup so users in many groups still work.

import crypto from 'node:crypto';
import * as msal from '@azure/msal-node';
import { config } from './config.js';
import { isUserInGroup } from './graph.js';
import { verifyPassword } from './local-auth.js';
import { isEntraConfigured, redirectUriFor } from './entra-helper.js';

const REDIRECT_PATH = '/admin/auth/callback';
const POST_LOGOUT_PATH = '/admin/auth/logout-callback';

// Break-glass pointer appended to Entra sign-in failure responses, but ONLY on a
// sandbox deployment (production has no local account). If Entra is even slightly
// misconfigured after the Connect Entra wizard runs, this is how the operator
// finds their way back in without having memorised the URL.
function breakGlassHint() {
  return config.isSandbox
    ? '\n\nCan\'t sign in? Use the local break-glass admin account: /admin/auth/local-login'
    : '';
}

let cca = null;
function client() {
  if (cca) return cca;
  if (!config.entra.clientId || !config.entra.tenantId || !config.entra.clientSecret) {
    return null;
  }
  cca = new msal.ConfidentialClientApplication({
    auth: {
      clientId: config.entra.clientId,
      authority: `https://login.microsoftonline.com/${config.entra.tenantId}`,
      clientSecret: config.entra.clientSecret,
    },
    system: { loggerOptions: { loggerCallback() {}, logLevel: msal.LogLevel.Warning } },
  });
  return cca;
}

function redirectUri() {
  // Single source of truth shared with entra-helper.buildAzScripts so the URI
  // RepoFabric registers in Entra and the URI MSAL sends at sign-in are identical.
  return redirectUriFor(config.publicBaseUrl);
}

// --- Sandbox local-admin sign-in -----------------------------------------
// Only wired when REPOFABRIC_DEPLOYMENT_PROFILE=sandbox. Renders a plain HTML
// form (no inline script, so it passes the strict CSP) that POSTs to
// /admin/auth/local-login. Production never reaches this path.
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function safeReturnTo(v) {
  const s = String(v || '');
  // Only allow same-site absolute paths; reject protocol-relative (//host).
  return (s.startsWith('/') && !s.startsWith('//')) ? s : '/admin/';
}

export function renderLocalLogin(req, res, error) {
  const returnTo = escapeHtml(safeReturnTo(req.query?.returnTo || req.body?.returnTo));
  const err = error ? `<p class="err">${escapeHtml(error)}</p>` : '';
  res.status(error ? 401 : 200).type('html').send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RepoFabric Sandbox sign-in</title>
<style>
  body { font-family: system-ui, sans-serif; background:#0f1115; color:#e6e6e6; display:flex; min-height:100vh; align-items:center; justify-content:center; margin:0; }
  .card { background:#1a1d24; padding:2rem 2.25rem; border-radius:10px; width:320px; box-shadow:0 8px 30px rgba(0,0,0,.4); }
  .badge { display:inline-block; background:#a6601c; color:#fff; font-size:.7rem; font-weight:700; letter-spacing:.05em; padding:.2rem .5rem; border-radius:4px; margin-bottom:.75rem; }
  h1 { font-size:1.15rem; margin:.25rem 0 1rem; }
  label { display:block; font-size:.8rem; margin:.6rem 0 .2rem; color:#aab; }
  input { width:100%; box-sizing:border-box; padding:.55rem .6rem; border:1px solid #333a48; border-radius:6px; background:#0f1115; color:#e6e6e6; }
  button { margin-top:1.1rem; width:100%; padding:.6rem; border:0; border-radius:6px; background:#3b82f6; color:#fff; font-weight:600; cursor:pointer; }
  .err { color:#f87171; font-size:.8rem; margin:.5rem 0 0; }
  .note { color:#778; font-size:.72rem; margin-top:1rem; }
</style></head>
<body><form class="card" method="post" action="/admin/auth/local-login">
  <span class="badge">SANDBOX &middot; NOT FOR EXTENDED PRODUCTION USE</span>
  <h1>RepoFabric Sandbox</h1>
  <input type="hidden" name="returnTo" value="${returnTo}">
  <label for="u">Username</label>
  <input id="u" name="username" autocomplete="username" autofocus required>
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" required>
  ${err}
  <button type="submit">Sign in</button>
  ${isEntraConfigured(config.entra)
    ? `<p class="note">Microsoft Entra sign-in is configured for this deployment. <a href="/admin/auth/login" style="color:#4fa3ff;">Use Microsoft sign-in instead</a>. This local account is a break-glass fallback.</p>`
    : `<p class="note">Local sandbox account. This deployment is throwaway and not the enterprise method.</p>`}
</form></body></html>`);
}

export async function handleLocalLogin(req, res) {
  if (!config.isSandbox) return res.status(404).send('Not found');
  const username = String(req.body?.username || '').trim();
  const password = String(req.body?.password || '');
  const la = config.sandbox?.localAdmin || {};
  const ok = la.username && la.passwordHash &&
    username.toLowerCase() === String(la.username).toLowerCase() &&
    verifyPassword(password, la.passwordHash);
  if (!ok) {
    console.warn('[auth] sandbox local-login failed for', username || '(empty)');
    return renderLocalLogin(req, res, 'Invalid username or password.');
  }
  req.session.user = { upn: 'local-admin', name: la.username, groups: [], authReason: 'local password (sandbox)' };
  res.redirect(safeReturnTo(req.body?.returnTo));
}

export async function startLogin(req, res) {
  // Entra wins when it has been configured -- even under the sandbox profile,
  // once the operator connected Entra after first boot via the Connect Entra
  // wizard. Only a sandbox that has NOT connected Entra serves the local-admin
  // form here; the local form always stays reachable at /admin/auth/local-login
  // as a break-glass fallback regardless.
  if (config.isSandbox && !isEntraConfigured(config.entra)) return renderLocalLogin(req, res, null);
  const c = client();
  if (!c) return res.status(503).send('Entra is not configured. Complete first-run setup.' + breakGlassHint());
  req.session.returnTo = req.query.returnTo || '/admin/';
  try {
    const url = await c.getAuthCodeUrl({
      scopes: ['openid', 'profile', 'email', 'User.Read'],
      redirectUri: redirectUri(),
      prompt: 'select_account',
    });
    res.redirect(url);
  } catch (err) {
    console.error('[auth] getAuthCodeUrl failed:', err);
    res.status(500).send('Failed to start sign-in.');
  }
}

export async function handleCallback(req, res) {
  const c = client();
  if (!c) return res.status(503).send('Entra is not configured.' + breakGlassHint());
  if (!req.query.code) return res.status(400).send('Missing authorization code.' + breakGlassHint());
  try {
    const tokens = await c.acquireTokenByCode({
      code: String(req.query.code),
      scopes: ['openid', 'profile', 'email', 'User.Read'],
      redirectUri: redirectUri(),
    });
    const account = tokens.account || {};
    const claims = tokens.idTokenClaims || {};
    const user = {
      oid: claims.oid,
      tid: claims.tid,
      upn: (claims.preferred_username || claims.upn || account.username || '').toLowerCase(),
      name: claims.name || account.name,
      groups: Array.isArray(claims.groups) ? claims.groups : [],
      groupsOverage: Boolean(claims._claim_names && claims._claim_names.groups),
    };

    const decision = await authorize(user);
    if (!decision.allowed) {
      console.warn('[authz] denied for', user.upn, 'reason:', decision.reason);
      return res.status(403).send(
        `Signed in as ${user.upn || 'unknown'}, but your account is not authorised.\nReason: ${decision.reason}` + breakGlassHint()
      );
    }
    user.authReason = decision.reason;
    req.session.user = user;
    const returnTo = req.session.returnTo || '/admin/';
    delete req.session.returnTo;
    res.redirect(returnTo);
  } catch (err) {
    console.error('[auth] acquireTokenByCode failed:', err);
    res.status(500).send('Failed to exchange auth code.' + breakGlassHint());
  }
}

export async function authorize(user) {
  // 1. User allow-list match.
  if (config.auth.allowedUsers.length > 0 && user.upn && config.auth.allowedUsers.includes(user.upn)) {
    return { allowed: true, reason: `user allow-list match (${user.upn})` };
  }

  const allowedGroupIds = config.auth.allowedGroups.map(g => g.id);

  // 2. Group claim match (id_token contained the groups).
  if (allowedGroupIds.length > 0 && user.groups.length > 0) {
    const hit = user.groups.find(g => allowedGroupIds.includes(g));
    if (hit) return { allowed: true, reason: `group claim match (${hit})` };
  }

  // 3. Overage fallback: Microsoft Graph membership lookup. Only fires when
  //    the id_token told us "too many groups, see Graph" via _claim_names.
  if (allowedGroupIds.length > 0 && user.groupsOverage && user.oid) {
    for (const gid of allowedGroupIds) {
      try {
        if (await isUserInGroup(user.oid, gid)) {
          return { allowed: true, reason: `Graph overage match (${gid})` };
        }
      } catch (err) {
        console.warn('[authz] Graph overage check failed for', gid, err.message);
      }
    }
  }

  // 4. Default-allow when nothing is configured (first boot just after setup
  //    or an operator who explicitly cleared both lists).
  if (config.auth.allowedUsers.length === 0 && allowedGroupIds.length === 0) {
    return { allowed: true, reason: 'no authz configured; default-allow (will warn at startup)' };
  }
  return { allowed: false, reason: 'not in allowed users and not in any allowed group' };
}

export function logout(req, res) {
  // A sandbox WITHOUT Entra has no Entra session to end; just drop the local
  // session. Once Entra is connected (even in the sandbox) end it properly so
  // the browser is signed out of Microsoft too.
  if (config.isSandbox && !isEntraConfigured(config.entra)) {
    return req.session.destroy(() => res.redirect('/admin/auth/login'));
  }
  const base = config.publicBaseUrl.replace(/\/admin\/?$/, '');
  const url = `https://login.microsoftonline.com/${config.entra.tenantId}/oauth2/v2.0/logout?post_logout_redirect_uri=${encodeURIComponent(base + POST_LOGOUT_PATH)}`;
  req.session.destroy(() => res.redirect(url));
}

export function logoutCallback(_req, res) {
  res.send('<p>Signed out. <a href="/admin/">Sign in again</a>.</p>');
}

export function requireAuth(req, res, next) {
  if (req.session && req.session.user) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ error: 'authentication required' });
  res.redirect(`/admin/auth/login?returnTo=${encodeURIComponent(req.originalUrl)}`);
}

export function currentUser(req) {
  return (req.session && req.session.user) ? req.session.user : null;
}

// --- ConfigFabric absorption: machine-to-machine token gates -------------
// The ConfigFabric tabs add two server-to-server seams that BYPASS the Entra
// user gate (no operator session): the Azure Function's compliance-ingest
// dual-write, and RepoFabric's own prune gate calling CF's lock
// evaluate/override. Each is guarded narrowly by a shared bearer; everything
// else under /admin stays Entra-gated. Timing-safe compare avoids leaking the
// token by response timing. Mirrors ConfigFabric's auth.js verbatim so the
// absorbed behaviour is identical to standalone CF.
function tokenMatches(presented, expected) {
  if (!expected || !presented) return false;
  const a = Buffer.from(String(presented));
  const b = Buffer.from(String(expected));
  if (a.length !== b.length) return false;
  try { return crypto.timingSafeEqual(a, b); } catch { return false; }
}

function bearerFrom(req) {
  const m = /^Bearer\s+(.+)$/i.exec((req.get('Authorization') || '').trim());
  return m ? m[1].trim() : '';
}

export function requireIngestToken(req, res, next) {
  const expected = config.configfabric.ingestToken;
  if (!expected) return res.status(503).json({ error: 'compliance ingest is not configured (no ingest token set)' });
  if (!tokenMatches(bearerFrom(req), expected)) return res.status(401).json({ error: 'invalid or missing ingest bearer token' });
  next();
}

export function requireBoltOnToken(req, res, next) {
  const expected = config.configfabric.boltOnToken;
  if (!expected) return res.status(401).json({ error: 'invalid or missing bolt-on bearer token' });
  if (!tokenMatches(bearerFrom(req), expected)) return res.status(401).json({ error: 'invalid or missing bolt-on bearer token' });
  next();
}
