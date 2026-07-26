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

// Break-glass pointer appended to Entra sign-in failure pages, but ONLY on a
// sandbox deployment (production has no local account). If Entra is even slightly
// misconfigured after the Connect Entra wizard runs, this is how the operator
// finds their way back in without having memorised the URL.
function breakGlassHint() {
  if (!config.isSandbox) return '';
  return `
      <p class="note">Can't sign in? Use the local break-glass admin account at
        <a href="/admin/auth/local-login"><code>/admin/auth/local-login</code></a>.</p>`;
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

// --- Entry-surface presentation: RingoSystems Graphite Forge v1.0 --------
// RingoSystems Heavy Industries.
//
// These pages are SELF-CONTAINED on purpose. They render before a session
// exists and, in the "Entra is not configured" case, before the operator has
// any reason to believe /admin/*.css is reachable, so the handful of tokens
// they need is inlined here rather than linked. Every value below MIRRORS
// static/graphite-forge.css — if the foundation moves, move these with it.
// Inline <style> passes the strict CSP (styleSrc allows 'unsafe-inline');
// inline <script> does NOT, so there is none, and there must never be one.
//
// Dark-native only. Do not add a light mode. Copper is identity and the single
// primary commitment; everything else is charcoal and 1px borders.
const AUTH_STYLES = `
:root{
  color-scheme:dark;
  --gf-bg-base:#101113; --gf-bg-shell:#14171B; --gf-surface-well:#0D0E10;
  --gf-text-primary:#F7F9FB; --gf-text-secondary:#A7B0BE; --gf-text-muted:#75808E; --gf-text-disabled:#505965;
  --gf-accent:#C97A40; --gf-accent-hi:#DE8B4B; --gf-success:#52B788;
  --gf-warning:#F6C85F; --gf-danger:#D65A4A; --gf-data:#6BD6E8;
  --gf-on-accent:#101113;
  --gf-border:rgba(255,255,255,.07); --gf-border-strong:rgba(255,255,255,.12);
  --gf-glass:rgba(255,255,255,.045); --gf-glass-hover:rgba(255,255,255,.065);
  --gf-glow-copper:0 0 80px rgba(201,122,64,.18);
  --gf-shadow-frame:0 34px 100px rgba(0,0,0,.42);
  --gf-font-ui:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
  --gf-font-data:Consolas,"Cascadia Mono","SF Mono",ui-monospace,monospace;
  --gf-weight-display:760; --gf-tracking-title:-.045em;
  --s-1:4px; --s-2:8px; --s-3:12px; --s-4:16px; --s-5:22px; --s-6:32px;
  --r-sm:8px; --r-md:11px; --r-lg:18px;
  --gf-ease:.18s cubic-bezier(.4,0,.2,1);
}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{
  margin:0;min-height:100vh;
  display:flex;align-items:center;justify-content:center;
  padding:var(--s-6) var(--s-4);
  background:
    radial-gradient(circle at 12% 0%, rgba(201,122,64,.18), transparent 30%),
    radial-gradient(circle at 88% 7%, rgba(123,97,255,.11), transparent 24%),
    linear-gradient(180deg,var(--gf-bg-shell),var(--gf-bg-base));
  background-attachment:fixed;
  color:var(--gf-text-primary);
  font-family:var(--gf-font-ui);font-size:14px;line-height:1.55;
  -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
}
.auth{width:100%;max-width:432px;display:flex;flex-direction:column;gap:var(--s-5)}
.auth.is-wide{max-width:560px}

/* ---- Brand mark. Placeholder glyph per the standard. ---- */
.brand{display:flex;align-items:center;gap:var(--s-3);padding-left:2px}
.brand-mark{
  width:38px;height:38px;flex:none;display:grid;place-items:center;
  border-radius:11px;background:linear-gradient(135deg,var(--gf-accent),var(--gf-success));
  color:var(--gf-on-accent);font-weight:900;font-size:18px;line-height:1;
  box-shadow:0 0 38px rgba(201,122,64,.18);
}
.brand-text{display:flex;flex-direction:column;line-height:1.2;min-width:0}
.brand-name{font-weight:var(--gf-weight-display);letter-spacing:-.04em;font-size:16px}
.brand-sub{color:var(--gf-text-muted);font-size:11px;letter-spacing:.04em;text-transform:uppercase}

/* ---- Card: border-led, 18px, ambient copper only. ---- */
.card{
  position:relative;overflow:hidden;
  border:1px solid var(--gf-border);border-radius:var(--r-lg);
  background:linear-gradient(180deg,rgba(28,32,39,.75),rgba(15,18,22,.78));
  padding:var(--s-6);margin:0;
  box-shadow:var(--gf-shadow-frame),var(--gf-glow-copper);
}
.card::after{
  content:"";position:absolute;pointer-events:none;
  width:360px;height:360px;right:-170px;top:-165px;
  background:radial-gradient(circle,rgba(201,122,64,.18),transparent 65%);
}
.card>*{position:relative}

/* ---- Type ---- */
h1{margin:0;font-size:clamp(26px,4.6vw,32px);line-height:1.05;
   font-weight:var(--gf-weight-display);letter-spacing:var(--gf-tracking-title)}
.lede{margin:var(--s-2) 0 0;color:var(--gf-text-secondary);font-size:15px;line-height:1.55}

/* ---- Eyebrow: state as a word plus a lit dot, never colour alone. ---- */
.eyebrow{
  display:inline-flex;align-items:center;gap:var(--s-2);flex-wrap:wrap;
  margin:0 0 var(--s-3);font-size:13px;font-weight:var(--gf-weight-display);
  letter-spacing:.01em;color:var(--gf-accent);
}
.eyebrow::before{content:"";width:8px;height:8px;flex:none;border-radius:50%;
  background:currentColor;box-shadow:0 0 18px currentColor}
.eyebrow.is-danger{color:var(--gf-danger)}
.eyebrow.is-warn{color:var(--gf-warning)}
.eyebrow.is-ok{color:var(--gf-success)}
.eyebrow.is-info{color:var(--gf-data)}
/* Machine value (HTTP status) rides the eyebrow in the data face. */
.chip{font-family:var(--gf-font-data);font-size:11.5px;font-weight:600;letter-spacing:0;
  color:var(--gf-text-muted);border:1px solid rgba(255,255,255,.09);
  background:var(--gf-glass);border-radius:999px;padding:1px 8px}

/* ---- Sandbox badge: copper, sparing, states its own warning in words. ---- */
.badge{
  display:inline-flex;align-items:center;gap:7px;
  margin:0 0 var(--s-4);padding:4px 11px 4px 9px;border-radius:999px;
  border:1px solid rgba(201,122,64,.30);background:rgba(201,122,64,.08);
  color:var(--gf-accent);font-size:11px;font-weight:700;
  letter-spacing:.08em;text-transform:uppercase;line-height:1.45;
}
.badge::before{content:"";width:7px;height:7px;flex:none;border-radius:50%;
  background:currentColor;box-shadow:0 0 10px currentColor}

/* ---- Fields. Labels are human copy; what gets typed is an identifier,
        so the wells are set in the data face. ---- */
.field{margin-top:var(--s-4)}
.field-label{display:block;margin-bottom:6px;font-size:13px;line-height:1.2;
  font-weight:520;color:var(--gf-text-secondary)}
.field-input{
  width:100%;padding:10px 13px;
  border:1px solid rgba(255,255,255,.09);border-radius:var(--r-md);
  background:var(--gf-surface-well);color:var(--gf-text-primary);
  font-family:var(--gf-font-data);font-size:13.5px;line-height:1.4;
  transition:border-color var(--gf-ease),box-shadow var(--gf-ease);
}
.field-input::placeholder{color:var(--gf-text-disabled)}
.field-input:focus{outline:none;border-color:var(--gf-accent);
  box-shadow:0 0 0 3px rgba(201,122,64,.16)}
/* A hint that these are the fields the alert is about — the alert above still
   carries the label, glyph and colour, so this stays deliberately quiet. */
.field-input[aria-invalid="true"]{border-color:rgba(214,90,74,.34)}
/* Chrome's autofill paints a white well; hold the dark surface. */
.field-input:-webkit-autofill,
.field-input:-webkit-autofill:hover,
.field-input:-webkit-autofill:focus{
  -webkit-text-fill-color:var(--gf-text-primary);
  -webkit-box-shadow:0 0 0 1000px var(--gf-surface-well) inset;
  caret-color:var(--gf-text-primary);
  transition:background-color 600000s 0s;
}

/* ---- Buttons. Default is charcoal + border; the copper->green gradient is
        the ONE primary commitment on the view. ---- */
.btn{
  display:inline-flex;align-items:center;justify-content:center;gap:var(--s-2);
  padding:11px 16px;border-radius:var(--r-md);
  border:1px solid rgba(255,255,255,.08);background:var(--gf-glass);
  color:var(--gf-text-primary);font:inherit;font-size:14px;
  text-decoration:none;cursor:pointer;white-space:nowrap;
  transition:background var(--gf-ease),border-color var(--gf-ease),
             transform var(--gf-ease),filter var(--gf-ease);
}
.btn:hover{background:var(--gf-glass-hover);border-color:rgba(201,122,64,.36)}
.btn:active{transform:translateY(1px)}
.btn.primary{border:0;background:linear-gradient(135deg,var(--gf-accent),var(--gf-success));
  color:var(--gf-on-accent);font-weight:var(--gf-weight-display);
  box-shadow:0 18px 55px rgba(201,122,64,.18)}
.btn.primary:hover{filter:brightness(1.07)}
.btn.block{width:100%;margin-top:var(--s-5)}
.actions{display:flex;flex-wrap:wrap;gap:var(--s-3);margin-top:var(--s-5)}
.actions .btn{flex:0 0 auto}

/* Focus is copper, always visible, never removed. */
:where(a,button,input,summary,[tabindex]):focus-visible{
  outline:2px solid var(--gf-accent);outline-offset:2px;border-radius:var(--r-md)}

/* ---- Error state: colour AND a label AND a glyph AND a border. ---- */
.alert{
  display:flex;gap:var(--s-3);align-items:flex-start;
  margin-top:var(--s-4);padding:11px 13px;
  border-radius:var(--r-md);font-size:13px;line-height:1.5;
  background:rgba(214,90,74,.15);border:1px solid rgba(214,90,74,.38);
  color:var(--gf-danger);
}
.alert-mark{flex:none;width:20px;height:20px;display:grid;place-items:center;
  border-radius:6px;background:rgba(214,90,74,.18);
  font-family:var(--gf-font-data);font-size:12px;font-weight:700;line-height:1}
.alert-label{display:block;margin-bottom:1px;font-size:11px;font-weight:700;
  letter-spacing:.08em;text-transform:uppercase}
/* The failure text itself is machine output. */
.alert-body{color:var(--gf-text-secondary);font-family:var(--gf-font-data);font-size:12.5px}

/* ---- Evidence: compact uppercase labels, machine values in the data face. ---- */
.evidence{margin:var(--s-5) 0 0;padding:var(--s-4);display:grid;gap:var(--s-3);
  border:1px solid rgba(255,255,255,.055);border-radius:var(--r-md);
  background:rgba(255,255,255,.028)}
.evidence div{display:grid;gap:2px;min-width:0}
.evidence dt{font-size:10.5px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--gf-text-muted)}
.evidence dd{margin:0;font-family:var(--gf-font-data);font-size:12.5px;line-height:1.45;
  color:var(--gf-text-secondary);word-break:break-word;overflow-wrap:anywhere}

/* ---- Quiet secondary copy under a divider. ---- */
.note{margin:var(--s-5) 0 0;padding-top:var(--s-4);
  border-top:1px solid rgba(255,255,255,.055);
  color:var(--gf-text-muted);font-size:12.5px;line-height:1.55}
.note + .note{margin-top:var(--s-3);padding-top:0;border-top:0}
.note a{color:var(--gf-accent);text-decoration:none;
  border-bottom:1px solid rgba(201,122,64,.36)}
.note a:hover{color:var(--gf-accent-hi);border-bottom-color:var(--gf-accent-hi)}
code{font-family:var(--gf-font-data);font-size:12px;color:inherit}

@media (max-width:480px){
  body{padding:var(--s-4) var(--s-3)}
  .card{padding:var(--s-5)}
  .actions .btn{min-width:0;width:100%}
}
@media (prefers-reduced-motion:reduce){
  *,*::before,*::after{transition-duration:.001ms !important;animation-duration:.001ms !important}
  .btn:active{transform:none}
}`;

// The shared entry-surface document: ambient wash, brand mark, one framed card.
function authDocument({ docTitle, wide = false, cardHtml }) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>${escapeHtml(docTitle)}</title>
<style>${AUTH_STYLES}</style></head>
<body>
  <main class="auth${wide ? ' is-wide' : ''}">
    <div class="brand">
      <span class="brand-mark" aria-hidden="true">R</span>
      <span class="brand-text">
        <span class="brand-name">RepoFabric</span>
        <span class="brand-sub">RingoSystems Heavy Industries</span>
      </span>
    </div>
${cardHtml}
  </main>
</body></html>`;
}

// Every non-form auth outcome — not configured, not authorised, signed out —
// renders through here so they read as one surface. Colour is never the only
// signal: each carries a state word, a lit dot, and (where it helps) the HTTP
// status in the data face.
const NOTICE_TONES = { danger: 'is-danger', warn: 'is-warn', ok: 'is-ok', info: 'is-info' };

function renderAuthNotice(res, {
  status = 500,
  tone = 'danger',
  label,                 // the state, as a word — pairs with the colour
  title,                 // human sentence
  body = '',             // human sentence
  facts = [],            // [[label, machineValue]] — rendered in the data face
  actions = [],          // [{ href, label, primary }] — at most one primary
  breakGlass = false,    // append the sandbox break-glass pointer
  docTitle,
}) {
  const toneClass = NOTICE_TONES[tone] || NOTICE_TONES.danger;
  const factsHtml = facts.length
    ? `\n      <dl class="evidence">${facts
        .map(([k, v]) => `\n        <div><dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd></div>`)
        .join('')}\n      </dl>`
    : '';
  const actionsHtml = actions.length
    ? `\n      <div class="actions">${actions
        .map(a => `\n        <a class="btn${a.primary ? ' primary' : ''}" href="${escapeHtml(a.href)}">${escapeHtml(a.label)}</a>`)
        .join('')}\n      </div>`
    : '';
  const bodyHtml = body ? `\n      <p class="lede">${escapeHtml(body)}</p>` : '';
  // The HTTP status is machine output and belongs in the data face, but only
  // when something actually went wrong — it is noise on a success page.
  const chipHtml = status >= 400 ? ` <span class="chip">HTTP ${escapeHtml(String(status))}</span>` : '';

  const cardHtml = `    <section class="card">
      <p class="eyebrow ${toneClass}">${escapeHtml(label)}${chipHtml}</p>
      <h1>${escapeHtml(title)}</h1>${bodyHtml}${factsHtml}${actionsHtml}${breakGlass ? breakGlassHint() : ''}
    </section>`;

  res.status(status).type('html').send(
    authDocument({ docTitle: docTitle || `RepoFabric — ${label}`, wide: true, cardHtml })
  );
}

export function renderLocalLogin(req, res, error) {
  const returnTo = escapeHtml(safeReturnTo(req.query?.returnTo || req.body?.returnTo));
  // The failure text is emitted by the server, so it is set in the data face
  // and labelled "Sign-in failed" — the red is reinforcement, not the message.
  const err = error ? `
      <div class="alert" role="alert" id="signin-error">
        <span class="alert-mark" aria-hidden="true">!</span>
        <span>
          <strong class="alert-label">Sign-in failed</strong>
          <span class="alert-body">${escapeHtml(error)}</span>
        </span>
      </div>` : '';
  const invalid = error ? ' aria-invalid="true" aria-describedby="signin-error"' : '';

  const cardHtml = `    <form class="card" method="post" action="/admin/auth/local-login">
      <span class="badge">Sandbox &middot; not for extended production use</span>
      <h1>Sign in</h1>
      <p class="lede">Local administrator account for this RepoFabric sandbox.</p>${err}
      <input type="hidden" name="returnTo" value="${returnTo}">
      <div class="field">
        <label class="field-label" for="u">Username</label>
        <input class="field-input" id="u" name="username" autocomplete="username" autofocus required${invalid}>
      </div>
      <div class="field">
        <label class="field-label" for="p">Password</label>
        <input class="field-input" id="p" name="password" type="password" autocomplete="current-password" required${invalid}>
      </div>
      <button class="btn primary block" type="submit">Sign in</button>
      ${isEntraConfigured(config.entra)
        ? `<p class="note">Microsoft Entra sign-in is configured for this deployment.
        <a href="/admin/auth/login">Use Microsoft sign-in instead</a>.
        This local account is a break-glass fallback.</p>`
        : `<p class="note">Local sandbox account. This deployment is throwaway and not the enterprise method.</p>`}
    </form>`;

  res.status(error ? 401 : 200).type('html').send(
    authDocument({ docTitle: 'RepoFabric — Sign in', cardHtml })
  );
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
  req.session.user = { upn: 'local-admin', name: la.username, groups: [], role: 'admin', authReason: 'local password (sandbox)' };
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
  if (!c) {
    return renderAuthNotice(res, {
      status: 503,
      tone: 'warn',
      label: 'Not configured',
      title: 'Microsoft Entra is not configured',
      body: 'RepoFabric cannot start a sign-in until first-run setup has supplied a tenant, client ID and client secret.',
      actions: [{ href: '/setup/', label: 'Complete first-run setup', primary: true }],
      breakGlass: true,
    });
  }
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
    renderAuthNotice(res, {
      status: 500,
      tone: 'danger',
      label: 'Sign-in failed',
      title: 'Could not start sign-in',
      body: 'RepoFabric could not build the Microsoft Entra authorisation request. Check the tenant, client ID and redirect URI, then try again.',
      actions: [{ href: '/admin/auth/login', label: 'Try again', primary: true }],
    });
  }
}

export async function handleCallback(req, res) {
  const c = client();
  if (!c) {
    return renderAuthNotice(res, {
      status: 503,
      tone: 'warn',
      label: 'Not configured',
      title: 'Microsoft Entra is not configured',
      body: 'A sign-in came back to RepoFabric, but this deployment has no Entra configuration to complete it with.',
      actions: [{ href: '/setup/', label: 'Complete first-run setup', primary: true }],
      breakGlass: true,
    });
  }
  if (!req.query.code) {
    return renderAuthNotice(res, {
      status: 400,
      tone: 'danger',
      label: 'Incomplete sign-in',
      title: 'Missing authorization code',
      body: 'Microsoft Entra returned to RepoFabric without an authorization code, so there is nothing to exchange for a session. Start the sign-in again from the beginning.',
      actions: [{ href: '/admin/auth/login', label: 'Restart sign-in', primary: true }],
      breakGlass: true,
    });
  }
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
      return renderAuthNotice(res, {
        status: 403,
        tone: 'danger',
        label: 'Not authorised',
        title: 'This account is not authorised',
        body: 'Microsoft Entra confirmed who you are, but this account is not on any RepoFabric admin or read-only allow-list. An existing administrator can add you under Settings.',
        facts: [
          ['Signed in as', user.upn || 'unknown'],
          ['Reason', decision.reason],
        ],
        actions: [{ href: '/admin/auth/logout', label: 'Sign out and use another account' }],
        breakGlass: true,
      });
    }
    user.authReason = decision.reason;
    user.role = decision.role;
    req.session.user = user;
    const returnTo = req.session.returnTo || '/admin/';
    delete req.session.returnTo;
    res.redirect(returnTo);
  } catch (err) {
    console.error('[auth] acquireTokenByCode failed:', err);
    renderAuthNotice(res, {
      status: 500,
      tone: 'danger',
      label: 'Sign-in failed',
      title: 'Could not exchange the authorization code',
      body: 'Microsoft Entra rejected the token exchange. The client secret may have expired, or the redirect URI registered in Entra may not match this deployment. The server log carries the full error.',
      actions: [{ href: '/admin/auth/login', label: 'Restart sign-in', primary: true }],
      breakGlass: true,
    });
  }
}

// Returns { allowed, role, reason }. role is 'admin' (full access) or
// 'readonly' (view-only; every mutating /admin request is refused by the gate
// in server.js). Admin allow-lists win over read-only, so a user in both is an
// admin. A Graph membership lookup covers the groups-claim overage case.
export async function authorize(user) {
  const allowedGroupIds  = config.auth.allowedGroups.map(g => g.id);
  const readonlyUsers    = config.auth.readonlyUsers || [];
  const readonlyGroupIds = (config.auth.readonlyGroups || []).map(g => g.id);

  const matchesGroups = async (groupIds) => {
    if (groupIds.length === 0) return null;
    if (user.groups.length > 0) {
      const hit = user.groups.find(g => groupIds.includes(g));
      if (hit) return hit;
    }
    // Overage fallback: id_token said "too many groups, see Graph" (_claim_names).
    if (user.groupsOverage && user.oid) {
      for (const gid of groupIds) {
        try { if (await isUserInGroup(user.oid, gid)) return gid; }
        catch (err) { console.warn('[authz] Graph overage check failed for', gid, err.message); }
      }
    }
    return null;
  };

  // 1. Admin: user allow-list, then group (claim or Graph overage).
  if (config.auth.allowedUsers.length > 0 && user.upn && config.auth.allowedUsers.includes(user.upn)) {
    return { allowed: true, role: 'admin', reason: `admin user allow-list match (${user.upn})` };
  }
  const adminGroupHit = await matchesGroups(allowedGroupIds);
  if (adminGroupHit) return { allowed: true, role: 'admin', reason: `admin group match (${adminGroupHit})` };

  // 2. Read-only: user allow-list, then group (claim or Graph overage).
  if (readonlyUsers.length > 0 && user.upn && readonlyUsers.includes(user.upn)) {
    return { allowed: true, role: 'readonly', reason: `read-only user allow-list match (${user.upn})` };
  }
  const roGroupHit = await matchesGroups(readonlyGroupIds);
  if (roGroupHit) return { allowed: true, role: 'readonly', reason: `read-only group match (${roGroupHit})` };

  // 3. Default-allow (admin) when NOTHING is configured (first boot just after
  //    setup or an operator who explicitly cleared every list).
  if (config.auth.allowedUsers.length === 0 && allowedGroupIds.length === 0 &&
      readonlyUsers.length === 0 && readonlyGroupIds.length === 0) {
    return { allowed: true, role: 'admin', reason: 'no authz configured; default-allow (will warn at startup)' };
  }
  return { allowed: false, role: null, reason: 'not in any admin or read-only allow-list or group' };
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
  renderAuthNotice(res, {
    status: 200,
    tone: 'ok',
    label: 'Signed out',
    title: 'You are signed out',
    body: 'Your RepoFabric session has ended and Microsoft Entra has been told to end its session too.',
    actions: [{ href: '/admin/', label: 'Sign in again', primary: true }],
    docTitle: 'RepoFabric — Signed out',
  });
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

// RFIP binary push guard. The per-client 'package:write' bearer is registered
// in the pwsh ingest_client table (the DB is the trust store), so Node cannot
// verify it locally against a shared secret. Instead it validates the presented
// bearer by calling the loopback discovery endpoint, which the pwsh
// RfBridgeCapability gate answers 200 for an ACTIVE client and 401/403
// otherwise. Only then is the (potentially multi-GB) multipart upload accepted;
// the subsequent signed publish call re-authenticates and hash-binds the file,
// so a staged blob alone can never become a published package.
export async function requireIngestClientBearer(req, res, next) {
  const auth = (req.get('Authorization') || '').trim();
  if (!/^Bearer\s+/i.test(auth)) return res.status(401).json({ error: 'bearer token required' });
  try {
    const r = await fetch(config.publisherUrl + '/api/v1/ingest/information', {
      headers: { Authorization: auth, Accept: 'application/json' },
    });
    if (r.status === 200) return next();
    if (r.status === 401 || r.status === 403) {
      return res.status(r.status).json({ error: 'ingest client authentication failed' });
    }
    return res.status(502).json({ error: 'publisher_unreachable' });
  } catch (err) {
    return res.status(502).json({ error: 'publisher_unreachable', detail: String(err?.message || err) });
  }
}
