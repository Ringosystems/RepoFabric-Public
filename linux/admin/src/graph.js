// Microsoft Graph helpers. Two use cases:
//   1. Resolve overage-claim group membership in auth.js when an id_token
//      indicates "too many groups, look at Graph". Requires GroupMember.Read.All.
//   2. Typeahead for the Solution Configuration UI to add users by name
//      and groups by display name without making the operator paste GUIDs.
//      Requires User.Read.All and Group.Read.All.
//
// All calls use the client-credentials flow (app-only token), cached for
// the duration of its lifetime so we don't hit /token on every request.

import * as msal from '@azure/msal-node';
import { config } from './config.js';

const SCOPE = 'https://graph.microsoft.com/.default';
let appClient = null;
let cachedToken = null;
let cachedTokenExpiry = 0;

function appCca() {
  if (appClient) return appClient;
  if (!config.entra.clientId || !config.entra.tenantId || !config.entra.clientSecret) return null;
  appClient = new msal.ConfidentialClientApplication({
    auth: {
      clientId: config.entra.clientId,
      authority: `https://login.microsoftonline.com/${config.entra.tenantId}`,
      clientSecret: config.entra.clientSecret,
    },
    system: { loggerOptions: { loggerCallback() {}, logLevel: msal.LogLevel.Warning } },
  });
  return appClient;
}

async function getAppToken() {
  const now = Date.now();
  if (cachedToken && now < cachedTokenExpiry - 30_000) return cachedToken;
  const c = appCca();
  if (!c) throw new Error('Entra not configured');
  const result = await c.acquireTokenByClientCredential({ scopes: [SCOPE] });
  cachedToken = result.accessToken;
  cachedTokenExpiry = result.expiresOn ? new Date(result.expiresOn).getTime() : now + 30 * 60 * 1000;
  return cachedToken;
}

async function graphFetch(pathAndQuery, init = {}) {
  const token = await getAppToken();
  const url = 'https://graph.microsoft.com/v1.0' + pathAndQuery;
  const headers = new Headers(init.headers || {});
  headers.set('Authorization', `Bearer ${token}`);
  headers.set('Accept', 'application/json');
  if (init.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  const res = await fetch(url, { ...init, headers });
  const ct = res.headers.get('content-type') || '';
  const body = ct.includes('json') ? await res.json() : await res.text();
  if (!res.ok) {
    const msg = body?.error?.message || `${res.status} ${res.statusText}`;
    const err = new Error(`graph ${init.method || 'GET'} ${pathAndQuery}: ${msg}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

// Used by auth.js when a user has groups-claim overage. Returns true when
// the user (by object id) is a transitive member of the named group.
export async function isUserInGroup(userOid, groupId) {
  const body = await graphFetch(`/users/${encodeURIComponent(userOid)}/checkMemberGroups`, {
    method: 'POST',
    body: JSON.stringify({ groupIds: [groupId] }),
  });
  return Array.isArray(body.value) && body.value.includes(groupId);
}

// Typeahead helpers for the Solution Configuration UI.
export async function searchUsers(query, top = 10) {
  const q = String(query || '').trim();
  if (q.length < 2) return [];
  const filter = `startsWith(displayName,'${q.replace(/'/g, "''")}')` +
                 ` or startsWith(userPrincipalName,'${q.replace(/'/g, "''")}')` +
                 ` or startsWith(mail,'${q.replace(/'/g, "''")}')`;
  const body = await graphFetch(
    `/users?$filter=${encodeURIComponent(filter)}&$select=id,displayName,userPrincipalName,mail&$top=${top}`,
    { headers: { ConsistencyLevel: 'eventual' } },
  );
  return (body.value || []).map(u => ({
    id: u.id,
    upn: (u.userPrincipalName || u.mail || '').toLowerCase(),
    display_name: u.displayName,
  }));
}

export async function searchGroups(query, top = 10) {
  const q = String(query || '').trim();
  if (q.length < 2) return [];
  const filter = `startsWith(displayName,'${q.replace(/'/g, "''")}')`;
  const body = await graphFetch(
    `/groups?$filter=${encodeURIComponent(filter)}&$select=id,displayName,description&$top=${top}`,
    { headers: { ConsistencyLevel: 'eventual' } },
  );
  return (body.value || []).map(g => ({
    id: g.id,
    display_name: g.displayName,
    description: g.description || '',
  }));
}

// Connectivity probe used by the setup wizard's identity step. Returns
// { ok: true } when the app can mint a token, otherwise { ok: false, error }.
export async function probeGraph() {
  try {
    await getAppToken();
    return { ok: true };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}
