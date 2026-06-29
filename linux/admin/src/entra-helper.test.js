import { test } from 'node:test';
import assert from 'node:assert/strict';
import { redirectUriFor, buildAzScripts, isEntraConfigured, mergeEntraAuth } from './entra-helper.js';

// --- redirectUriFor -------------------------------------------------------
test('redirectUriFor: strips trailing /admin and appends the callback', () => {
  assert.equal(redirectUriFor('https://winget.example.com/admin'), 'https://winget.example.com/admin/auth/callback');
  assert.equal(redirectUriFor('https://winget.example.com/admin/'), 'https://winget.example.com/admin/auth/callback');
  assert.equal(redirectUriFor('https://winget.example.com'), 'https://winget.example.com/admin/auth/callback');
  assert.equal(redirectUriFor('https://winget.example.com/'), 'https://winget.example.com/admin/auth/callback');
});

test('redirectUriFor: no double slash on a single-trailing-slash base, incl. sub-paths (AADSTS50011 guard)', () => {
  // auth.js redirectUri() now calls this same helper, and config.js strips ALL
  // trailing slashes from publicBaseUrl at load (.replace(/\/+$/, '')), so the URI
  // registered in Entra and the URI MSAL sends at sign-in are byte-identical.
  // This locks the helper's half of that contract for the shapes it receives
  // after normalization (no slash, or a single trailing slash).
  const cases = [
    ['https://host/rf/', 'https://host/rf/admin/auth/callback'],
    ['https://host/rf', 'https://host/rf/admin/auth/callback'],
    ['https://host/admin/', 'https://host/admin/auth/callback'],
    ['https://host/admin', 'https://host/admin/auth/callback'],
  ];
  for (const [base, want] of cases) {
    const uri = redirectUriFor(base);
    assert.equal(uri, want);
    assert.ok(!uri.replace(/^https:\/\//, '').includes('//'), `double slash in ${uri} from ${base}`);
  }
});

// --- buildAzScripts -------------------------------------------------------
test('buildAzScripts: returns both shells, the exact redirect URI, and all four permissions', () => {
  const out = buildAzScripts('https://winget.example.com/admin');
  assert.equal(out.redirectUri, 'https://winget.example.com/admin/auth/callback');
  assert.equal(out.permissions.length, 4);
  assert.ok(out.bash.includes('https://winget.example.com/admin/auth/callback'));
  assert.ok(out.powershell.includes('https://winget.example.com/admin/auth/callback'));
  // The three values the wizard parses must be printed by both scripts.
  for (const s of [out.bash, out.powershell]) {
    assert.ok(s.includes('TENANT_ID='));
    assert.ok(s.includes('CLIENT_ID='));
    assert.ok(s.includes('CLIENT_SECRET='));
  }
});

test('buildAzScripts: single quotes in the display name cannot break out of the shell literal', () => {
  const out = buildAzScripts('https://winget.example.com/admin', "Evil' ; rm -rf / #");
  // The injected single quote is stripped, so no stray quote survives in the literal.
  assert.ok(out.bash.includes("DISPLAY_NAME='Evil ; rm -rf / #'"));
  assert.ok(!out.displayName.includes("'"));
});

// --- isEntraConfigured ----------------------------------------------------
test('isEntraConfigured: true only when all three credentials are present', () => {
  assert.equal(isEntraConfigured({ tenantId: 't', clientId: 'c', clientSecret: 's' }), true);
  assert.equal(isEntraConfigured({ tenantId: 't', clientId: 'c', clientSecret: '' }), false);
  assert.equal(isEntraConfigured({ tenantId: 't', clientId: '', clientSecret: 's' }), false);
  assert.equal(isEntraConfigured({ tenantId: '', clientId: 'c', clientSecret: 's' }), false);
  assert.equal(isEntraConfigured({}), false);
  assert.equal(isEntraConfigured(null), false);
  assert.equal(isEntraConfigured(undefined), false);
});

// --- mergeEntraAuth -------------------------------------------------------
test('mergeEntraAuth: writes the auth block while preserving everything else', () => {
  const existing = {
    targets: { gitea_repo: 'repofabric/winget-manifests' },
    notifications: { smtp: { host: 'mail' } },
    sandbox: { local_admin: { username: 'admin', password_hash: 'scrypt$abc' } },
  };
  const merged = mergeEntraAuth(existing, {
    tenant_id: 'TID', client_id: 'CID', client_secret: 'SEC',
    redirect_uri: 'https://x/admin/auth/callback',
    allowed_users: [], allowed_groups: [],
  });
  // Auth block set.
  assert.equal(merged.auth.tenant_id, 'TID');
  assert.equal(merged.auth.client_id, 'CID');
  assert.equal(merged.auth.client_secret, 'SEC');
  assert.equal(merged.auth.redirect_uri, 'https://x/admin/auth/callback');
  // Crucially, the break-glass local admin and other settings are untouched.
  assert.equal(merged.sandbox.local_admin.username, 'admin');
  assert.equal(merged.sandbox.local_admin.password_hash, 'scrypt$abc');
  assert.equal(merged.targets.gitea_repo, 'repofabric/winget-manifests');
  assert.equal(merged.notifications.smtp.host, 'mail');
});

test('mergeEntraAuth: does not mutate the input object', () => {
  const existing = { auth: { tenant_id: 'old' }, sandbox: { local_admin: { username: 'admin' } } };
  const merged = mergeEntraAuth(existing, { tenant_id: 'new', client_id: 'c', client_secret: 's' });
  assert.equal(existing.auth.tenant_id, 'old');
  assert.equal(merged.auth.tenant_id, 'new');
  assert.notEqual(existing, merged);
});

test('mergeEntraAuth: allowed lists overwrite only when non-empty; users are lowercased', () => {
  const withLists = mergeEntraAuth({ auth: { allowed_users: ['keep@x.com'] } }, {
    tenant_id: 't', client_id: 'c', client_secret: 's',
    allowed_users: ['You@Contoso.com', ' '], allowed_groups: [{ id: 'g1' }, { id: '' }],
  });
  assert.deepEqual(withLists.auth.allowed_users, ['you@contoso.com']);
  assert.deepEqual(withLists.auth.allowed_groups, [{ id: 'g1', display_name: 'g1' }]);

  // Empty lists leave any previous values intact.
  const kept = mergeEntraAuth({ auth: { allowed_users: ['keep@x.com'] } }, {
    tenant_id: 't', client_id: 'c', client_secret: 's', allowed_users: [], allowed_groups: [],
  });
  assert.deepEqual(kept.auth.allowed_users, ['keep@x.com']);
});

test('mergeEntraAuth: tolerates a missing/blank existing solution', () => {
  const merged = mergeEntraAuth(null, { tenant_id: 't', client_id: 'c', client_secret: 's', redirect_uri: 'r' });
  assert.equal(merged.auth.tenant_id, 't');
  assert.equal(merged.auth.redirect_uri, 'r');
});
