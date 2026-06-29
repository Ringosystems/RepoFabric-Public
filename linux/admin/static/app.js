"use strict";

// All paths are relative; the SPA is served at /admin/ so api lives at
// /admin/api/. By using relative URLs the same code would also work if the
// container is ever remounted under a different path.
const API = 'api';

const $  = sel => document.querySelector(sel);
const $$ = sel => Array.from(document.querySelectorAll(sel));

let state = {
  subs: [], selectedSubId: null, pubs: [], runs: [],
  cfg: null, health: [], me: null,
};

function toast(msg, kind = '') {
  const t = $('#toast');
  t.textContent = msg;
  t.className = kind;
  t.hidden = false;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.hidden = true, 5000);
}

async function api(path, init = {}) {
  const res = await fetch(`${API}/${path}`, {
    headers: { 'content-type': 'application/json', ...(init.headers || {}) },
    credentials: 'same-origin',
    ...init
  });
  if (res.status === 401) {
    // Session expired; bounce through Entra again.
    window.location.href = `auth/login?returnTo=${encodeURIComponent(location.pathname)}`;
    throw new Error('signed out');
  }
  const ct = res.headers.get('content-type') || '';
  const body = ct.includes('json') ? await res.json() : await res.text();
  if (!res.ok) {
    const msg = (body && body.error) || `${res.status} ${res.statusText}`;
    throw new Error(msg);
  }
  return body;
}

// --- tabs ---
// Valid tab names. Used by activateTab + initFromHash so a typo'd or
// stale URL hash falls back to the default tab instead of leaving the
// page blank.
const VALID_TABS = ['subscriptions', 'inventory', 'activity', 'bandwidth', 'settings', 'about'];

function activateTab(name) {
  if (!VALID_TABS.includes(name)) name = 'subscriptions';
  $$('nav#tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  $$('main .tab').forEach(s => s.classList.toggle('active', s.id === `tab-${name}`));
  // Reflect the current tab in the URL hash so a browser refresh /
  // bookmark / shared link comes back to the same tab. Using
  // history.replaceState avoids littering the back-button stack with
  // tab clicks.
  const wantHash = `#${name}`;
  if (location.hash !== wantHash) {
    history.replaceState(null, '', wantHash);
  }
  switch (name) {
    // Subscriptions tab is the unified view: managed subscriptions
    // + operator-added custom packages + untracked repo entries. The
    // old separate Publications tab was removed; clicking a managed
    // row's Pubs count is the drill-in path.
    case 'subscriptions':  loadCatalog(); break;
    case 'inventory':      loadInventory(); break;
    case 'activity':       loadActivity(); break;
    case 'bandwidth':      loadBandwidth(); break;
    case 'settings':       loadCfg(); loadHealth(); loadPopularityStatus(); loadBackupStatus(); break;
    case 'about':          loadAbout(); break;
    case 'configfabric':   loadCfFrame(); break;
  }
}
$$('nav#tabs button').forEach(b => b.addEventListener('click', () => activateTab(b.dataset.tab)));

// Browser back/forward across tabs also restores state.
window.addEventListener('hashchange', () => {
  const name = (location.hash || '').replace(/^#/, '');
  if (name && VALID_TABS.includes(name)) activateTab(name);
});

// --- banner ---
async function loadMe() {
  try {
    state.me = await api('me');
    const reason = state.me.authReason ? ` (${state.me.authReason})` : '';
    $('#meta').textContent = `${state.me.identity}${reason}`;
  } catch (e) { $('#meta').textContent = '(identity probe failed)'; }
}

// --- about ---
// Settings -> About: product identity + version from api/about, plus the MIT
// license and third-party notices fetched once from the static about/ tree
// (same-origin, served from the admin static root). The notice text is the
// in-product surface for the open-source attributions; the authoritative copy
// ships with the source as THIRD-PARTY-NOTICES.md.
let aboutTextLoaded = false;
async function loadAbout() {
  try {
    const info = await api('about');
    $('#about-product').textContent  = info.product || 'RepoFabric';
    $('#about-version').textContent  = info.version ? `Version ${info.version}` : '';
    $('#about-copyright').textContent = info.copyright || '';
    const repo = $('#about-repo');
    if (repo && info.repoUrl) {
      repo.href = info.repoUrl;
      repo.textContent = info.repoUrl.replace(/^https?:\/\//, '');
    }
    if (!aboutTextLoaded) {
      aboutTextLoaded = true;  // fetch the (immutable) text bundles once
      fetchTextInto(info.licenseUrl || 'about/LICENSE.txt',          '#about-license');
      fetchTextInto(info.noticesUrl || 'about/THIRD-PARTY-NOTICES.md', '#about-notices');
    }
  } catch (e) {
    $('#about-version').textContent = '(failed to load About info)';
  }
}

async function fetchTextInto(url, sel) {
  const el = $(sel);
  if (!el) return;
  try {
    const res = await fetch(url, { credentials: 'same-origin' });
    el.textContent = res.ok ? await res.text() : `(failed to load ${url}: ${res.status})`;
  } catch (e) {
    el.textContent = `(failed to load ${url})`;
  }
}

// --- combined view (subscriptions + custom + untracked) -----------------

// Backwards-compat alias: many existing handlers still call loadSubs().
async function loadSubs() { return loadCombinedView(); }

async function loadCombinedView() {
  try {
    // Pull every source feed for the combined tab in parallel.
    //   subscriptions + publications + queue : managed section
    //   custom                                : operator-added section
    //   repo_catalog                          : untracked section
    const [subBody, pubBody, queueBody, customBody, catalogBody] = await Promise.all([
      api('subscriptions'),
      api('publications'),
      api('queue/status').catch(() => null),
      api('custom').catch(() => null),
      api('repo/all').catch(() => null)   // returns managed/custom/untracked split
    ]);
    // Filter null/undefined entries everywhere. PowerShell-to-JSON
    // serialization occasionally emits a null array element (e.g. when
    // a pipeline yields $null among objects). Without the filter the
    // renderers crash on c.PackageId access.
    state.subs = (subBody.subscriptions || []).filter(Boolean);
    const pubs = (pubBody.publications || []).filter(Boolean);
    const bySid = {};
    const sizeBySid = {};
    // Most-recent published version per subscription, tracked via max
    // publication_id (monotonic, immune to clock skew across runs).
    // For pinned subscriptions this matches sub.PinnedVersion; for
    // latest subscriptions it surfaces whatever version was actually
    // published last, which is what 'currently in the repo' means.
    const latestVerBySid = {};
    const latestPidBySid = {};
    pubs.forEach(p => {
      bySid[p.subscription_id]    = (bySid[p.subscription_id]    || 0) + 1;
      sizeBySid[p.subscription_id] = (sizeBySid[p.subscription_id] || 0) + (Number(p.total_size_bytes) || 0);
      const pid = Number(p.publication_id) || 0;
      if (!latestPidBySid[p.subscription_id] || pid > latestPidBySid[p.subscription_id]) {
        latestPidBySid[p.subscription_id] = pid;
        latestVerBySid[p.subscription_id] = p.version;
      }
    });
    state.pubsBySid = bySid;
    state.sizeBySid = sizeBySid;
    state.latestVerBySid = latestVerBySid;
    state.pubs = pubs;

    const queueState = {};
    const items = (queueBody && queueBody.Items) || [];
    items.forEach(it => {
      const sid = it.subscription_id;
      const st  = it.state;
      if (st === 'running')      queueState[sid] = 'running';
      else if (st === 'pending' && queueState[sid] !== 'running') queueState[sid] = 'pending';
    });
    state.queueState = queueState;

    state.customPkgs    = ((customBody && customBody.custom) || []).filter(Boolean);
    // /api/repo/all returns PascalCase keys (PSCustomObject -> JSON).
    state.untrackedPkgs = ((catalogBody && catalogBody.Untracked) || []).filter(Boolean);

    renderSubs();
    renderCustomPackages();
    renderUntracked();
    // Refresh sidebar package counts now that fresh data is in state.
    // No-op if the sidebar isn't in DOM (e.g., Activity tab active).
    if (typeof renderCatalogSidebar === 'function') renderCatalogSidebar();
    schedulePollIfBusy();
  } catch (e) { toast(`Load subscriptions: ${e.message}`, 'bad'); }
}

function renderCustomPackages() {
  const tbody = $('#custom-table tbody');
  if (!tbody) return;
  tbody.innerHTML = '';
  const visible = customsForCurrentRepo(state.customPkgs);
  if (!visible.length) {
    tbody.innerHTML = `<tr><td colspan="10" class="muted">No operator-published apps in <code>${escapeHtml(state.selectedRepoId)}</code>. ${
      state.selectedRepoId === 'main' ? 'Use "+ Publish custom app" to add one.' : 'Custom apps in non-main repos require the publisher refactor (planned); for now, promote from main.'
    }</td></tr>`;
    return;
  }
  visible.forEach(c => {
    const tr = document.createElement('tr');
    tr.dataset.customId = c.CustomId;
    const lastAtCell = c.LastPublishedAt
      ? `<td title="${escAttr(c.LastPublishedAt)}">${formatLocalTime(c.LastPublishedAt)}</td>`
      : '<td class="muted"></td>';
    const sizeCell = c.TotalSizeBytes
      ? `<td>${(c.TotalSizeBytes / 1048576).toFixed(1)}</td>`
      : '<td class="muted" title="Size for custom packages is not tracked yet"></td>';
    // Upstream-match cell: three states.
    //   NULL UpstreamMatches      -> not scanned yet (grey "?")
    //   empty array               -> scanned and clean (green ✓)
    //   non-empty array           -> overlap with public WinGet repo (red ✗)
    let upstreamCell;
    if (c.UpstreamMatches === null || c.UpstreamMatches === undefined) {
      upstreamCell = `<td class="muted" title="Not yet scanned. The weekly cron job runs every Sunday 03:15 UTC.">?</td>`;
    } else if (Array.isArray(c.UpstreamMatches) && c.UpstreamMatches.length === 0) {
      upstreamCell = `<td class="status-ok" title="Scanned ${c.UpstreamMatchCheckedAt || ''}; no overlap with the public WinGet repo.">clean</td>`;
    } else {
      // Defensive against case-variant property names: ConvertFrom-Json
      // preserves whatever case is in the stored JSON, and older rows
      // may have been written with lowercase keys before the
      // Find-RfUpstreamHashMatches helper standardised on PascalCase.
      // Fall back to ManifestPath when present so the operator at least
      // sees something identifying the colliding manifest.
      const labels = c.UpstreamMatches.map(m => {
        if (!m || typeof m !== 'object') return String(m);
        const pid = m.PackageId || m.packageId || m.package_id || null;
        const ver = m.Version   || m.version   || null;
        if (pid && ver) return `${pid}@${ver}`;
        if (pid)        return pid;
        const mp = m.ManifestPath || m.manifestPath || m.manifest_path;
        if (mp)         return mp;
        return '(unparseable match -- see upstream_match_json in the database)';
      }).join(', ');
      upstreamCell = `<td class="status-fail" title="Same binary exists in the public WinGet repo: ${escAttr(labels)}. Consider a managed subscription.">match</td>`;
    }
    tr.innerHTML = `
      <td>${c.CustomId}</td>
      <td>${escHtml(c.PackageId)}</td>
      <td>${escHtml(c.PackageName || '')}</td>
      <td>${escHtml(c.Publisher || '')}</td>
      <td>${escHtml(c.LastPublishedVersion || '')}</td>
      ${sizeCell}
      ${upstreamCell}
      ${lastAtCell}
      <td class="muted">${escHtml((c.Notes || '').slice(0, 80))}</td>
      <td class="custom-actions">
        <button type="button" class="ghost" data-custom-action="edit"  title="Edit this custom app in the publish wizard.">Edit</button>
        ${hasUpstreamMatch(c) ? `<button type="button" class="primary" data-custom-action="convert" title="This binary already exists in the public WinGet repo. Convert this custom row to a managed subscription tracking the upstream package, and clear the custom artefacts from Gitea + nginx.">Convert to subscription</button>` : ''}
      </td>`;
    // Row click opens the structured detail drawer. Action buttons in
    // the Actions column stop propagation so clicking Edit / Remove
    // does not also open the drawer.
    tr.addEventListener('click', (ev) => {
      if (ev.target.closest('button')) return;
      $$('#sub-table tbody tr, #untracked-table tbody tr').forEach(other => other.classList.remove('selected'));
      $$('#custom-table tbody tr').forEach(other => other.classList.toggle('selected', other === tr));
      state.selectedSubId = null;
      updateSubButtons();
      renderDetailDrawer({
        source:    'custom',
        packageId: c.PackageId,
        version:   c.LastPublishedVersion || c.LatestVersion || null,
        row:       c,
      });
    });
    tbody.appendChild(tr);
  });
}

// Look up the row in state by id rather than parsing the rendered text,
// so a stale DOM after async refresh can't return mismatched data.
function findCustomById(cid) {
  return (state.customPkgs || []).find(c => String(c.CustomId) === String(cid));
}

// True when the custom row has been scanned AND has at least one
// upstream-hash collision. Drives the row's "Convert to subscription"
// action visibility. Defensively unwraps a legacy double-wrap shape
// (older Find-RfUpstreamHashMatches stored [[{...}]]); the read
// path repairs new responses but cached state may still carry the
// old shape.
function hasUpstreamMatch(c) {
  if (!c || !c.UpstreamMatches) return false;
  let m = c.UpstreamMatches;
  if (Array.isArray(m) && m.length === 1 && Array.isArray(m[0])) m = m[0];
  return Array.isArray(m) && m.length > 0;
}

// Pull the first matched upstream PackageId / Version off a row,
// tolerating the same case variations the render-time helper does.
function firstUpstreamMatch(c) {
  if (!hasUpstreamMatch(c)) return null;
  let m = c.UpstreamMatches;
  if (Array.isArray(m) && m.length === 1 && Array.isArray(m[0])) m = m[0];
  const first = m[0] || {};
  return {
    PackageId: first.PackageId || first.packageId || first.package_id || null,
    Version:   first.Version   || first.version   || null,
  };
}

// Custom-app Edit: route the operator to the publish wizard in edit
// mode. The wizard pre-fills every field from the existing manifest
// (silent switches, install modes, scope, ProductCode, locale fields,
// notes, additional locales -- everything), locks PackageIdentifier +
// PackageVersion (changing either would orphan the repo path), and
// PUTs the edited manifest to /api/custom/<id> on Save. The notes-only
// dialog is retired; full edit is the only edit flow.
function openCustomEditDialog(cid) {
  const c = findCustomById(cid);
  if (!c) return toast(`Custom package ${cid} not in current view; hit Refresh.`, 'bad');
  window.location.href = `./publish-custom.html?edit=${encodeURIComponent(cid)}`;
}

function openCustomRemoveDialog(cid) {
  const c = findCustomById(cid);
  if (!c) return toast(`Custom package ${cid} not in current view; hit Refresh.`, 'bad');
  const dlg = $('#dlg-custom-del');
  $('#dlg-custom-del-target').textContent = `${c.PackageId} @ ${c.LastPublishedVersion || '(no version)'} (#${c.CustomId})`;
  $('#dlg-custom-del-error').hidden = true;
  dlg.dataset.customId = cid;
  // Reset radio to "clear" each time the dialog opens.
  const clearRadio = dlg.querySelector('input[name="custom-del-mode"][value="clear"]');
  if (clearRadio) clearRadio.checked = true;
  dlg.showModal();
}

async function confirmCustomRemove() {
  const dlg = $('#dlg-custom-del');
  const cid = dlg.dataset.customId;
  const mode = (dlg.querySelector('input[name="custom-del-mode"]:checked') || {}).value || 'clear';
  const keep = mode === 'keep' ? '?keep=1' : '';
  try {
    await api(`custom/${cid}${keep}`, { method: 'DELETE' });
    dlg.close();
    toast(`Removed custom #${cid}.`, 'ok');
    await loadCombinedView();
  } catch (e) {
    const err = $('#dlg-custom-del-error');
    err.hidden = false;
    err.textContent = `Remove failed: ${e.message}`;
  }
}

// Convert a colliding custom row into a managed subscription that
// tracks the matched upstream package. The server-side endpoint adds
// the subscription, removes the custom row, and clears the custom
// manifest + installer from Gitea + nginx all in one call -- the
// dialog just confirms intent before the operator pulls the trigger.
function openCustomConvertDialog(cid) {
  const c = findCustomById(cid);
  if (!c) return toast(`Custom package ${cid} not in current view; hit Refresh.`, 'bad');
  const match = firstUpstreamMatch(c);
  if (!match || !match.PackageId) {
    return toast('No upstream match recorded for this row. Refresh the catalog or wait for the weekly collision scan.', 'bad');
  }
  const dlg = $('#dlg-custom-convert');
  $('#dlg-custom-convert-from').textContent = `${c.PackageId} (custom #${c.CustomId})`;
  $('#dlg-custom-convert-to').textContent = match.Version ? `${match.PackageId} @ ${match.Version}` : match.PackageId;
  $('#dlg-custom-convert-error').hidden = true;
  dlg.dataset.customId = cid;
  dlg.dataset.targetPackageId = match.PackageId;
  dlg.showModal();
}

async function confirmCustomConvert() {
  const dlg = $('#dlg-custom-convert');
  const cid = dlg.dataset.customId;
  const targetPid = dlg.dataset.targetPackageId;
  const btn = dlg.querySelector('[data-act="custom-convert-confirm"]');
  if (btn) { btn.disabled = true; btn.textContent = 'Converting...'; }
  try {
    const r = await api(`custom/${cid}/convert-to-subscription`, {
      method: 'POST',
      body: JSON.stringify({ TargetPackageId: targetPid, SyncNow: true }),
    });
    dlg.close();
    const subId = r && r.subscription && r.subscription.SubscriptionId
      ? `#${r.subscription.SubscriptionId}`
      : '';
    toast(`Converted custom #${cid} to subscription ${subId} (${targetPid}).`, 'ok');
    await loadCombinedView();
  } catch (e) {
    const err = $('#dlg-custom-convert-error');
    err.hidden = false;
    err.textContent = `Convert failed: ${e.message}`;
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Convert'; }
  }
}

function renderUntracked() {
  const tbody = $('#untracked-table tbody');
  if (!tbody) return;
  tbody.innerHTML = '';
  const visible = untrackedForCurrentRepo(state.untrackedPkgs);
  if (!visible.length) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No untracked apps in this repo\'s manifest tree.</td></tr>';
    return;
  }
  visible.forEach(u => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${escHtml(u.PackageId)}</td>
      <td>${escHtml(u.Publisher || '')}</td>
      <td>${escHtml(u.PackageName || '')}</td>
      <td>${escHtml(u.LatestVersion || '')}</td>
      <td>${u.VersionCount || ''}</td>
      <td class="muted" title="${escAttr(u.LastSeenAt || '')}">${formatLocalTime(u.LastSeenAt)}</td>`;
    tr.addEventListener('click', () => {
      $$('#sub-table tbody tr, #custom-table tbody tr').forEach(other => other.classList.remove('selected'));
      $$('#untracked-table tbody tr').forEach(other => other.classList.toggle('selected', other === tr));
      state.selectedSubId = null;
      updateSubButtons();
      renderDetailDrawer({
        source:    'untracked',
        packageId: u.PackageId,
        version:   u.LatestVersion || null,
        row:       u,
      });
    });
    tbody.appendChild(tr);
  });
}

// Auto-refresh the subscriptions table while any work is queued or
// running. Stops polling on the first refresh where the queue is idle.
let subPollTimer = null;
function schedulePollIfBusy() {
  if (subPollTimer) { clearTimeout(subPollTimer); subPollTimer = null; }
  const busy = Object.keys(state.queueState || {}).length > 0;
  if (!busy) return;
  subPollTimer = setTimeout(() => {
    // Only poll while the Subscriptions tab is the active tab.
    if ($('#tab-subscriptions') && $('#tab-subscriptions').classList.contains('active')) {
      loadSubs();
    }
  }, 3000);
}
function renderSubs() {
  const tbody = $('#sub-table tbody');
  tbody.innerHTML = '';
  const pubsBySid = state.pubsBySid || {};
  const visible = subsForCurrentRepo(state.subs);
  if (!visible.length) {
    const isMain = state.selectedRepoId === 'main';
    tbody.innerHTML = `<tr><td colspan="10" class="muted">${
      isMain
        ? 'No subscriptions yet. Use "+ Add subscription" to track an upstream WinGet package.'
        : `No subscriptions in <code>${escapeHtml(state.selectedRepoId)}</code> yet. Click "+ Add subscription" while this repo is selected to track a package here, or promote from another repo.`
    }</td></tr>`;
    return;
  }
  visible.forEach(s => {
    const tr = document.createElement('tr');
    tr.dataset.sid = s.SubscriptionId;
    if (s.SubscriptionId === state.selectedSubId) tr.classList.add('selected');
    const pubCount = pubsBySid[s.SubscriptionId] || 0;
    const queueMark = (state.queueState && state.queueState[s.SubscriptionId]) || null;
    let pubCell;
    if (queueMark === 'running') {
      pubCell = `<td class="status-warn" title="Sync is RUNNING right now. Pubs count will update when publish completes.">${pubCount} (syncing)</td>`;
    } else if (queueMark === 'pending') {
      pubCell = `<td class="status-warn" title="Sync is queued and waiting for a worker.">${pubCount} (queued)</td>`;
    } else if (pubCount === 0) {
      pubCell = '<td class="status-warn" title="No published versions. Sync this subscription to materialize one.">0</td>';
    } else {
      pubCell = `<td class="status-ok">${pubCount}</td>`;
    }
    const sizeBytes = (state.sizeBySid && state.sizeBySid[s.SubscriptionId]) || 0;
    const sizeCell = sizeBytes
      ? `<td title="${sizeBytes} bytes summed across this subscription's publications">${(sizeBytes / 1048576).toFixed(1)}</td>`
      : '<td class="muted"></td>';

    // Repo version: the version currently in the virtual repo's manifest
    // tree. For pinned subs this equals PinnedVersion. For latest subs
    // it surfaces the most recent published version (max publication_id).
    // Distinct cell styling when it diverges from the subscription's
    // intent (pinned but a newer publish slipped in is unusual; latest
    // is expected to drift over time).
    const latestVer = (state.latestVerBySid && state.latestVerBySid[s.SubscriptionId]) || null;
    let repoVerCell;
    if (latestVer) {
      const matchesPinned = s.Track === 'pinned' && s.PinnedVersion && latestVer === s.PinnedVersion;
      repoVerCell = matchesPinned
        ? `<td class="status-ok" title="Matches the pinned version exactly.">${escapeHtml(latestVer)}</td>`
        : `<td>${escapeHtml(latestVer)}</td>`;
    } else {
      repoVerCell = '<td class="muted" title="No publication yet. Sync to materialize a version into this repo.">(none)</td>';
    }

    tr.innerHTML = `
      <td>${s.SubscriptionId}</td>
      <td>${s.PackageId}</td>
      <td>${s.Track}</td>
      <td class="muted">${s.PinnedVersion || ''}</td>
      ${repoVerCell}
      <td class="muted">${toArr(s.Arch).join(',')}</td>
      <td class="muted">${toArr(s.Locale).join(',')}</td>
      <td>${s.Retention}</td>
      ${pubCell}
      ${sizeCell}`;
    tr.addEventListener('click', () => selectSub(s.SubscriptionId));
    tbody.appendChild(tr);
  });
  updateSubButtons();
}
function selectSub(sid) {
  state.selectedSubId = sid;
  // Clear selection on the other two tables -- only one row across all
  // three sections is "selected" at a time.
  $$('#sub-table tbody tr').forEach(tr => tr.classList.toggle('selected', Number(tr.dataset.sid) === sid));
  $$('#custom-table tbody tr, #untracked-table tbody tr').forEach(tr => tr.classList.remove('selected'));
  const sub = state.subs.find(x => x.SubscriptionId === sid);
  if (sub) {
    renderDetailDrawer({
      source:    'managed',
      packageId: sub.PackageId,
      version:   sub.PinnedVersion || sub.LatestVersion || null,
      row:       sub,
    });
  }
  updateSubButtons();
}

// Detail drawer renderer. Called by every row in Managed / Custom /
// Untracked tables; takes a uniform `info` envelope and fetches the
// parsed manifest tree from /api/repo/manifest, then paints six
// stacked cards into #sub-detail-body. The drawer auto-expands so
// the operator does not have to click Detail to see what they
// selected.
async function renderDetailDrawer(info) {
  const drawer  = $('#sub-detail');
  const summary = $('#sub-detail-summary');
  const body    = $('#sub-detail-body');
  if (!drawer || !body) return;

  drawer.open = true;
  summary.textContent = `Detail: ${info.packageId}${info.version ? ' @ ' + info.version : ''}`;
  body.innerHTML = `<p class="muted">Loading manifest...</p>`;

  if (!info.version) {
    body.innerHTML = `
      ${renderWingetInstallCard(info)}
      <p class="muted">No published version recorded for this row yet. Trigger a sync first to populate the manifest.</p>
      ${renderSourceCard(info)}`;
    return;
  }

  let m = null;
  try {
    m = await api(`repo/manifest?packageId=${encodeURIComponent(info.packageId)}&version=${encodeURIComponent(info.version)}`);
  } catch (e) {
    body.innerHTML = `
      ${renderWingetInstallCard(info)}
      <div class="detail-card detail-card-err">
        <strong>Manifest unavailable.</strong>
        <p><code>${escHtml(e.message)}</code></p>
        <p class="muted">The package is in the local catalog but the YAML files were not found at the manifest mount. For Managed rows, a sync will fetch them. For Custom rows, the publish wizard renders them on Save.</p>
      </div>
      ${renderSourceCard(info)}`;
    return;
  }

  body.innerHTML = `
    ${renderWingetInstallCard(info)}
    ${renderIdentityCard(m, info)}
    ${renderInstallersCard(m)}
    ${renderDetectionCard(m)}
    ${renderVersionsCard(info)}
    ${renderSourceCard(info)}
    ${renderRawCard(m)}`;
}

// ---- Drawer cards. Each takes the parsed manifest and returns HTML. ----

function renderIdentityCard(m, info) {
  const dl = m.DefaultLocale || {};
  const giteaUrl = state.cfg?.target?.gitea_url
    ? `${state.cfg.target.gitea_url}/${state.cfg.target.gitea_repo || ''}/src/branch/${state.cfg.target.gitea_branch || 'main'}/${m.RepoPath || ''}`
    : null;
  return `
    <div class="detail-card">
      <h4>Identity</h4>
      <dl class="detail-grid">
        <dt>PackageId</dt><dd><code>${escHtml(m.PackageId || info.packageId)}</code></dd>
        <dt>Version</dt><dd><code>${escHtml(m.Version || info.version || '')}</code></dd>
        ${dl.PackageName ? `<dt>PackageName</dt><dd>${escHtml(dl.PackageName)}</dd>` : ''}
        ${dl.Publisher   ? `<dt>Publisher</dt><dd>${escHtml(dl.Publisher)}</dd>` : ''}
        ${dl.License     ? `<dt>License</dt><dd>${escHtml(dl.License)}</dd>` : ''}
        ${dl.ShortDescription ? `<dt>Description</dt><dd>${escHtml(dl.ShortDescription)}</dd>` : ''}
        ${dl.Moniker     ? `<dt>Moniker</dt><dd><code>${escHtml(dl.Moniker)}</code></dd>` : ''}
        ${dl.PublisherUrl ? `<dt>Publisher URL</dt><dd><a href="${escAttr(dl.PublisherUrl)}" target="_blank" rel="noopener">${escHtml(dl.PublisherUrl)}</a></dd>` : ''}
        ${dl.LicenseUrl   ? `<dt>License URL</dt><dd><a href="${escAttr(dl.LicenseUrl)}" target="_blank" rel="noopener">${escHtml(dl.LicenseUrl)}</a></dd>` : ''}
        ${giteaUrl ? `<dt>Manifest in Gitea</dt><dd><a href="${escAttr(giteaUrl)}" target="_blank" rel="noopener">${escHtml(m.RepoPath || '')}</a></dd>` : ''}
      </dl>
    </div>`;
}

function renderInstallersCard(m) {
  const insts = (m.Installer && Array.isArray(m.Installer.Installers)) ? m.Installer.Installers : [];
  if (insts.length === 0) {
    return `<div class="detail-card"><h4>Installers</h4><p class="muted">No installer entries in the manifest.</p></div>`;
  }
  const rows = insts.map(i => {
    const sw = i.InstallerSwitches || {};
    return `
      <div class="detail-installer">
        <div class="detail-installer-head">
          <span class="wg-pill is-info">${escHtml(i.Architecture || 'arch?')}</span>
          <span class="wg-pill is-muted">${escHtml(i.InstallerType || 'type?')}</span>
          ${i.Scope ? `<span class="wg-pill is-muted">scope: ${escHtml(i.Scope)}</span>` : ''}
          ${i.InstallerLocale ? `<span class="wg-pill is-muted">${escHtml(i.InstallerLocale)}</span>` : ''}
        </div>
        <dl class="detail-grid">
          ${sw.Silent             ? `<dt>Silent switch</dt><dd><code>${escHtml(sw.Silent)}</code></dd>` : ''}
          ${sw.SilentWithProgress ? `<dt>SilentWithProgress</dt><dd><code>${escHtml(sw.SilentWithProgress)}</code></dd>` : ''}
          ${sw.Log                ? `<dt>Log switch</dt><dd><code>${escHtml(sw.Log)}</code></dd>` : ''}
          ${sw.InstallLocation    ? `<dt>InstallLocation switch</dt><dd><code>${escHtml(sw.InstallLocation)}</code></dd>` : ''}
          ${sw.Custom             ? `<dt>Custom switch</dt><dd><code>${escHtml(sw.Custom)}</code></dd>` : ''}
          ${Array.isArray(i.InstallModes) && i.InstallModes.length ? `<dt>InstallModes</dt><dd>${i.InstallModes.map(x => `<code>${escHtml(x)}</code>`).join(' ')}</dd>` : ''}
          ${i.UpgradeBehavior ? `<dt>UpgradeBehavior</dt><dd><code>${escHtml(i.UpgradeBehavior)}</code></dd>` : ''}
          ${i.MinimumOSVersion ? `<dt>Min OS version</dt><dd><code>${escHtml(i.MinimumOSVersion)}</code></dd>` : ''}
          ${i.InstallerUrl   ? `<dt>InstallerUrl</dt><dd><a href="${escAttr(i.InstallerUrl)}" target="_blank" rel="noopener"><code>${escHtml(i.InstallerUrl)}</code></a></dd>` : ''}
          ${i.InstallerSha256 ? `<dt>SHA-256</dt><dd><code class="detail-mono">${escHtml(i.InstallerSha256)}</code></dd>` : ''}
          ${i.ProductCode ? `<dt>ProductCode</dt><dd><code>${escHtml(i.ProductCode)}</code></dd>` : ''}
          ${i.UpgradeCode ? `<dt>UpgradeCode</dt><dd><code>${escHtml(i.UpgradeCode)}</code></dd>` : ''}
          ${i.PackageFamilyName ? `<dt>PackageFamilyName</dt><dd><code>${escHtml(i.PackageFamilyName)}</code></dd>` : ''}
        </dl>
      </div>`;
  }).join('');
  return `<div class="detail-card"><h4>Installers <small class="muted">(${insts.length})</small></h4>${rows}</div>`;
}

function renderDetectionCard(m) {
  const insts = (m.Installer && Array.isArray(m.Installer.Installers)) ? m.Installer.Installers : [];
  const aafEntries = [];
  const otherDetection = [];
  for (const i of insts) {
    if (Array.isArray(i.AppsAndFeaturesEntries)) {
      for (const a of i.AppsAndFeaturesEntries) {
        aafEntries.push({ ...a, _arch: i.Architecture });
      }
    }
    if (Array.isArray(i.Commands)       && i.Commands.length)       otherDetection.push(['Commands', i.Commands]);
    if (Array.isArray(i.Protocols)      && i.Protocols.length)      otherDetection.push(['Protocols', i.Protocols]);
    if (Array.isArray(i.FileExtensions) && i.FileExtensions.length) otherDetection.push(['FileExtensions', i.FileExtensions]);
  }
  if (aafEntries.length === 0 && otherDetection.length === 0) {
    return `<div class="detail-card"><h4>Detection</h4><p class="muted">No detection entries in the manifest. Endpoints fall back to ARP scan by ProductCode / UpgradeCode.</p></div>`;
  }
  const aafRows = aafEntries.map(a => `
    <div class="detail-installer">
      <div class="detail-installer-head">
        <span class="wg-pill is-muted">${escHtml(a._arch || '?')}</span>
      </div>
      <dl class="detail-grid">
        ${a.DisplayName    ? `<dt>DisplayName</dt><dd>${escHtml(a.DisplayName)}</dd>` : ''}
        ${a.DisplayVersion ? `<dt>DisplayVersion</dt><dd><code>${escHtml(a.DisplayVersion)}</code></dd>` : ''}
        ${a.Publisher      ? `<dt>Publisher</dt><dd>${escHtml(a.Publisher)}</dd>` : ''}
        ${a.ProductCode    ? `<dt>ProductCode</dt><dd><code>${escHtml(a.ProductCode)}</code></dd>` : ''}
        ${a.UpgradeCode    ? `<dt>UpgradeCode</dt><dd><code>${escHtml(a.UpgradeCode)}</code></dd>` : ''}
        ${a.InstallerType  ? `<dt>InstallerType</dt><dd><code>${escHtml(a.InstallerType)}</code></dd>` : ''}
      </dl>
    </div>`).join('');
  const otherRows = otherDetection.map(([k, v]) => `
    <dl class="detail-grid">
      <dt>${escHtml(k)}</dt><dd>${v.map(x => `<code>${escHtml(x)}</code>`).join(' ')}</dd>
    </dl>`).join('');
  return `<div class="detail-card"><h4>Detection</h4>${aafRows}${otherRows}</div>`;
}

function renderVersionsCard(info) {
  const row = info.row || {};
  const versions = Array.isArray(row.Versions) ? row.Versions : [];
  if (versions.length === 0) {
    return `<div class="detail-card"><h4>Versions</h4><p class="muted">No version history recorded in the local catalog.</p></div>`;
  }
  const items = versions.map(v => {
    if (typeof v === 'string') return `<li><code>${escHtml(v)}</code></li>`;
    const parts = [`<code>${escHtml(v.Version || v)}</code>`];
    if (v.LastSeenAt) parts.push(`<span class="muted">last seen ${escHtml(formatLocalTime(v.LastSeenAt))}</span>`);
    return `<li>${parts.join(' · ')}</li>`;
  }).join('');
  return `<div class="detail-card"><h4>Versions <small class="muted">(${versions.length})</small></h4><ul class="detail-versions">${items}</ul></div>`;
}

// Build the WinGet source name + REST URL for a repo exactly as a client would
// use them. The name matches the backend repoSourceName ("repofabric-<id>") so
// it lines up with the downloadable client-config .ps1. The URL prefers a
// dedicated Hostname; otherwise the repo is served on the shared admin host, so
// we use the BROWSER's current origin -- it carries the exact scheme/host/PORT
// the operator reached the admin on (including the sandbox's :8443, which the
// server-side config does not know about).
function wingetSourceFor(repo) {
  const id = String(repo?.RepoId || repo?.repoId || repo?.DisplayName || '')
    .toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  const name = id ? `repofabric-${id}` : 'repofabric';
  const host = repo?.Hostname || repo?.hostname;
  let url;
  if (host) {
    const scheme = /^https?:\/\//i.test(host) ? '' : 'https://';
    url = (scheme + host).replace(/\/+$/, '') + '/api/';
  } else {
    const base = window.location.origin.replace(/\/+$/, '');
    url = (repo?.RepoId && repo.RepoId !== 'main') ? `${base}/${repo.RepoId}/api/` : `${base}/api/`;
  }
  return { name, url };
}

// VSCode-style copy / "copied" check icons for the install-command copy button.
const WINGET_COPY_ICON = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>';
const WINGET_CHECK_ICON = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="#4ade80" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6L9 17l-5-5"></path></svg>';

// One click-to-copy command line (code + VSCode-style copy icon button).
function wingetCmdLine(cmd) {
  return `
      <div class="winget-install-row">
        <code class="winget-install-cmd" data-detail-action="copy-winget" data-cmd="${escAttr(cmd)}" title="Click to copy">${escHtml(cmd)}</code>
        <button type="button" class="ghost winget-copy-btn" data-detail-action="copy-winget" data-cmd="${escAttr(cmd)}" title="Copy" aria-label="Copy">${WINGET_COPY_ICON}</button>
      </div>`;
}

// Per-package "Install with WinGet" card for the detail drawer. In the SANDBOX
// (self-signed cert) it leads with a one-time client bootstrap: a script served
// over plain HTTP that trusts the CA and registers the source, so the client
// does not hit the untrusted-cert wall. In production (real CA) it is the plain
// source-add + install.
function renderWingetInstallCard(info) {
  const pkgId = info.packageId || '';
  if (!pkgId) return '';
  const repo = (state.virtualRepos || []).find(r => r.RepoId === state.selectedRepoId)
            || { RepoId: state.selectedRepoId };
  const { name, url } = wingetSourceFor(repo);
  const install = `winget install --source ${name} --id ${pkgId}`;

  if (state.isSandbox) {
    const httpPort = state.httpPort || 8080;
    const bootstrap = `irm http://${window.location.hostname}:${httpPort}/setup.ps1 | iex`;
    return `
    <div class="detail-card">
      <h4>Install with WinGet</h4>
      <p class="muted"><strong>One-time client setup</strong> — run once per device in an <strong>elevated</strong> PowerShell. This downloads a script over plain HTTP (so the self-signed certificate is not in the way), trusts the sandbox CA, and registers the source:</p>
      ${wingetCmdLine(bootstrap)}
      <p class="muted">Then install this app — click the command to copy it:</p>
      ${wingetCmdLine(install)}
    </div>`;
  }

  const sourceAdd = `winget source add --name ${name} --arg ${url} --type Microsoft.Rest`;
  return `
    <div class="detail-card">
      <h4>Install with WinGet</h4>
      <p class="muted">Add this repo as a trusted source on the device (run once, in an elevated terminal):</p>
      <pre class="winget-source-cmd">${escHtml(sourceAdd)}</pre>
      <p class="muted">Then install this app — click the command to copy it:</p>
      ${wingetCmdLine(install)}
    </div>`;
}

function renderSourceCard(info) {
  const r = info.row || {};
  // Per-version removal moved to the Inventory tab's delete action (universal
  // across managed / custom / untracked). The Catalog detail "Revert" button was
  // removed; revertControls stays empty so the layout below is unchanged.
  const revertControls = '';
  let body = '';
  if (info.source === 'managed') {
    body = `
      <dl class="detail-grid">
        <dt>Source</dt><dd>Managed subscription</dd>
        ${r.SubscriptionId ? `<dt>Subscription #</dt><dd>${r.SubscriptionId}</dd>` : ''}
        ${r.Track   ? `<dt>Track</dt><dd><code>${escHtml(r.Track)}</code></dd>` : ''}
        ${r.PinnedVersion ? `<dt>Pinned</dt><dd><code>${escHtml(r.PinnedVersion)}</code></dd>` : ''}
        ${Array.isArray(r.Arch)   ? `<dt>Arch</dt><dd>${r.Arch.map(x => `<code>${escHtml(x)}</code>`).join(' ')}</dd>` : ''}
        ${Array.isArray(r.Locale) ? `<dt>Locale</dt><dd>${r.Locale.map(x => `<code>${escHtml(x)}</code>`).join(' ')}</dd>` : ''}
        ${r.Retention ? `<dt>Retention</dt><dd>${r.Retention}</dd>` : ''}
      </dl>${revertControls}`;
  } else if (info.source === 'custom') {
    body = `
      <dl class="detail-grid">
        <dt>Source</dt><dd>Custom (operator-published)</dd>
        ${r.CustomId ? `<dt>Custom #</dt><dd>${r.CustomId}</dd>` : ''}
        ${r.LastPublishedAt ? `<dt>Last published</dt><dd title="${escAttr(r.LastPublishedAt)}">${escHtml(formatLocalTime(r.LastPublishedAt))}</dd>` : ''}
        ${r.LastPublishedVersion ? `<dt>Last version</dt><dd><code>${escHtml(r.LastPublishedVersion)}</code></dd>` : ''}
        ${r.Notes ? `<dt>Notes</dt><dd>${escHtml(r.Notes)}</dd>` : ''}
      </dl>
      <p>
        <a class="btn" href="./publish-custom.html?edit=${encodeURIComponent(r.CustomId || '')}">Edit in wizard</a>
        ${hasUpstreamMatch(r) ? `<button type="button" class="primary u-button-spaced" data-detail-action="convert-custom" data-cid="${escAttr(r.CustomId || '')}">Convert to subscription</button>` : ''}
      </p>`;
  } else {
    // Untracked
    body = `
      <dl class="detail-grid">
        <dt>Source</dt><dd>Untracked (observed in manifests/ mount; neither subscribed nor custom-published)</dd>
        ${r.LastSeenUtc || r.LastSeenAt ? `<dt>Last seen</dt><dd title="${escAttr(r.LastSeenUtc || r.LastSeenAt)}">${escHtml(formatLocalTime(r.LastSeenUtc || r.LastSeenAt))}</dd>` : ''}
      </dl>
      <p class="muted">Untracked rows are observed from the manifest mount. To bring one under management, subscribe to it or republish it as custom.</p>
      <p>
        <button class="ghost" data-detail-action="subscribe" data-pkg="${escAttr(info.packageId)}">Subscribe to this package</button>
        <a class="btn" href="./publish-custom.html">Republish as custom</a>
      </p>`;
  }
  return `<div class="detail-card"><h4>Source</h4>${body}</div>`;
}

// Delegated click handler for the Source card's CTA buttons. Currently
// only "Subscribe to this package" needs JS; the wizard CTA is a
// plain anchor. Lives on the body so card re-renders do not need to
// re-bind.
document.addEventListener('click', (ev) => {
  const btn = ev.target.closest('[data-detail-action]');
  if (!btn) return;
  if (btn.dataset.detailAction === 'copy-winget') {
    const cmd = btn.dataset.cmd || '';
    if (!cmd) return;
    navigator.clipboard.writeText(cmd).then(() => {
      toast('WinGet install command copied', 'ok');
      // VSCode-style: flash a green check on the copy button.
      if (btn.classList.contains('winget-copy-btn') && !btn.dataset.flashing) {
        btn.dataset.flashing = '1';
        btn.innerHTML = WINGET_CHECK_ICON;
        setTimeout(() => { btn.innerHTML = WINGET_COPY_ICON; delete btn.dataset.flashing; }, 1200);
      }
    }, () => toast('Copy failed — select the command and copy manually', 'bad'));
    return;
  }
  if (btn.dataset.detailAction === 'subscribe') {
    const pkg = btn.dataset.pkg || '';
    openSubDialog(null);
    const input = document.getElementById('pkg-search-input');
    if (input && pkg) {
      input.value = pkg;
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
  }
  if (btn.dataset.detailAction === 'convert-custom') {
    const cid = btn.dataset.cid || '';
    if (cid) openCustomConvertDialog(cid);
  }
  if (btn.dataset.detailAction === 'revert') {
    const pid = btn.dataset.pid || '';
    const pkg = btn.dataset.pkg || '';
    const ver = btn.dataset.ver || '';
    if (!pid) return;
    const reason = prompt(`Reason for reverting ${pkg} ${ver}? (required, 3+ chars)`, '');
    if (reason === null) return;
    if (reason.trim().length < 3) {
      toast('Revert needs a reason of at least 3 characters.', 'bad');
      return;
    }
    (async () => {
      try {
        const result = await api(`publications/${pid}/revert`, { method: 'POST', body: JSON.stringify({ Reason: reason.trim() }) });
        toast(`Reverted ${pkg} ${ver} (commit ${(result.GitCommitSha || '').slice(0, 8) || 'no-op'})`, 'ok');
        await loadCatalog();
      } catch (e) {
        toast(`Revert failed: ${e.message}`, 'bad');
      }
    })();
  }
});

function renderRawCard(m) {
  const dump = JSON.stringify({
    PackageId: m.PackageId,
    Version:   m.Version,
    RepoPath:  m.RepoPath,
    Installer: m.Installer,
    DefaultLocale: m.DefaultLocale,
    Locales:   m.Locales,
    Files:     m.Files,
  }, null, 2);
  return `
    <details class="detail-card detail-raw">
      <summary>Raw manifest tree</summary>
      <pre>${escHtml(dump)}</pre>
    </details>`;
}
function updateSubButtons() {
  const has = state.selectedSubId != null;
  ['#btn-sub-edit', '#btn-sub-sync', '#btn-sub-promote'].forEach(s => $(s).disabled = !has);
}
$('#btn-sub-refresh').onclick = loadCatalog;
$('#btn-add-sub').onclick = () => openSubDialog(null);
$('#btn-sub-edit').onclick = () => {
  const sub = state.subs.find(s => s.SubscriptionId === state.selectedSubId);
  if (sub) openSubDialog(sub);
};
// Subscription delete moved to the Inventory tab (universal delete across managed,
// custom, and untracked). The Catalog "Remove selected" control was removed.
// Row-level Edit / Remove for custom apps. Event delegation keeps it
// working across re-renders of the table tbody.
$('#custom-table').addEventListener('click', e => {
  const btn = e.target.closest('button[data-custom-action]');
  if (!btn) return;
  const tr  = btn.closest('tr');
  const cid = tr && tr.dataset.customId;
  if (!cid) return;
  if (btn.dataset.customAction === 'edit')    openCustomEditDialog(cid);
  if (btn.dataset.customAction === 'convert') openCustomConvertDialog(cid);
});

// Notes-only edit dialog is retired in favour of the wizard's edit
// mode. The dialog element stays in index.html for back-compat but
// has no handler -- clicking Edit on a row now navigates instead.

$('#dlg-custom-del').addEventListener('click', e => {
  const act = e.target.dataset.act;
  if (act === 'custom-del-cancel')  { $('#dlg-custom-del').close(); return; }
  if (act === 'custom-del-confirm') confirmCustomRemove();
});

// Convert-to-subscription dialog. Markup lives in index.html.
const dlgCustomConvert = document.getElementById('dlg-custom-convert');
if (dlgCustomConvert) {
  dlgCustomConvert.addEventListener('click', e => {
    const act = e.target.dataset.act;
    if (act === 'custom-convert-cancel')  { dlgCustomConvert.close(); return; }
    if (act === 'custom-convert-confirm') confirmCustomConvert();
  });
}

$('#dlg-sub-del').addEventListener('click', async e => {
  const act = e.target.dataset.act;
  if (act === 'del-cancel') { $('#dlg-sub-del').close(); return; }
  if (act !== 'del-confirm') return;
  const sid = state.selectedSubId; if (!sid) return;
  const mode = $('#dlg-sub-del').querySelector('input[name="del-mode"]:checked').value;
  const keep = mode === 'keep';
  const btn = e.target;
  btn.disabled = true;
  btn.textContent = keep ? 'Removing (keeping repo content)...' : 'Removing + clearing repo...';
  try {
    await api(`subscriptions/${sid}${keep ? '?keep=1' : ''}`, { method: 'DELETE' });
    $('#dlg-sub-del').close();
    toast(`Removed #${sid}${keep ? ' (repo content kept)' : ' (repo content cleared)'}`, 'ok');
    state.selectedSubId = null;
    await loadSubs();
    await loadPubs();
  } catch (err) {
    const eb = $('#dlg-sub-del-error');
    eb.textContent = `Remove failed: ${err.message}`;
    eb.hidden = false;
  } finally {
    btn.disabled = false;
    btn.textContent = 'Remove';
  }
});
$('#btn-sub-sync').onclick = async () => {
  const sid = state.selectedSubId; if (!sid) return;
  toast(`Queuing sync for #${sid}...`);
  try {
    // The endpoint enqueues at priority 0 and returns immediately;
    // the actual acquire+build+publish happens in the worker pool.
    // Watch the Activity tab for the run outcome.
    const result = await api(`subscriptions/${sid}/sync`, { method: 'POST' });
    if (result && result.ok) {
      toast(`Sync queued for #${sid} (queue_id=${result.queue_id}). Watch Activity for the run outcome.`, 'ok');
    } else {
      toast(`Sync enqueue returned an unexpected response`, 'bad');
    }
    await loadSubs();
  } catch (e) { toast(`Sync failed: ${e.message}`, 'bad'); }
};

// --- dialog ---
const dlg = $('#dlg-sub');
// WinGet's architecture vocabulary, sourced from the upstream WinGet
// manifest schema (Installer.Architecture). Operator's preferred set
// (from Settings) drives ordering; only architectures actually present
// in the picked package's upstream manifest become selectable.
const WINGET_ARCHES = ['x64', 'x86', 'arm64', 'arm', 'neutral'];

// Architectures the operator has marked as preferred in Settings.
// Reading the merged config shape that Get-RfConfiguration emits.
function preferredArchList() {
  return state.cfg?.subscription_defaults?.arch
      || state.cfg?.service?.defaults?.preferred_architectures
      || ['x64', 'x86', 'arm64'];
}

// Rebuilds the Architecture dropdown to reflect the currently-picked
// package's available architectures. Called whenever the picked
// package changes (typeahead select) or when the dialog opens on an
// existing subscription. The select is disabled until we know what
// architectures the package supports.
function rebuildArchSelect(availableArches, preselected) {
  const sel = $('#frm-sub-arch');
  const hint = $('#frm-sub-arch-hint');
  if (!sel) return;
  sel.innerHTML = '';

  const available = (availableArches || []).filter(a => typeof a === 'string' && a.length);
  if (!available.length) {
    sel.disabled = true;
    sel.appendChild(new Option('(pick a package first)', ''));
    if (hint) hint.textContent = '(pick a package first to see available architectures)';
    return;
  }

  const preferred = preferredArchList();
  const preferredSet = new Set(preferred);
  const availableSet = new Set(available.map(a => String(a)));

  // Preferred-first ordering, then off-policy at the bottom. Both
  // groups filtered to architectures the package actually ships.
  const headArches = preferred.filter(a => availableSet.has(a));
  const tailArches = available
    .filter(a => !preferredSet.has(a))
    .sort();

  // If the operator is editing a subscription whose currently-saved
  // arch is not in the package's current upstream manifest, surface it
  // anyway so they don't lose the choice silently. The optgroup labels
  // it 'currently saved' so it is visually distinct.
  const orphanArches = [];
  if (preselected && !availableSet.has(preselected)) {
    orphanArches.push(preselected);
  }

  // Flat list ordered preferred-first then off-policy alphabetical.
  // No optgroup labels per operator preference; off-policy options
  // render in italic so the policy intent is still visible without
  // separator chrome.
  for (const a of headArches) {
    const opt = new Option(a, a);
    sel.appendChild(opt);
  }
  for (const a of tailArches) {
    const opt = new Option(a, a);
    opt.classList.add('arch-off-policy');
    sel.appendChild(opt);
  }
  for (const a of orphanArches) {
    const opt = new Option(`${a} (saved; no longer in upstream)`, a);
    opt.classList.add('arch-off-policy');
    sel.appendChild(opt);
  }

  sel.disabled = false;

  // Default selection: explicit preselected first, else most-preferred
  // available, else first available.
  let pick = null;
  if (preselected && [...sel.options].some(o => o.value === preselected)) {
    pick = preselected;
  } else if (headArches.length) {
    pick = headArches[0];
  } else {
    pick = tailArches[0] || available[0];
  }
  sel.value = pick;

  if (hint) {
    hint.textContent = `${available.length} architecture${available.length === 1 ? '' : 's'} available for this package`;
  }
}

// Repopulate the Virtual repo picker from state.virtualRepos. Single
// active repo: hide the row entirely (no choice to make). Multiple:
// show with the currently-viewed repo preselected so the default is
// always "add to where I'm looking". Edit case: lock to the existing
// row's repo because changing repo on an existing subscription is a
// move, not an edit.
function rebuildSubRepoSelect(existing, defaultRepoId) {
  const sel = document.querySelector('#frm-sub-repo');
  const row = document.querySelector('#frm-sub-repo-row');
  if (!sel || !row) return;
  const active = (state.virtualRepos || []).filter(r => r.Status !== 'archived');
  sel.innerHTML = '';
  for (const r of active) {
    const opt = document.createElement('option');
    opt.value = r.RepoId;
    opt.textContent = r.DisplayName ? `${r.DisplayName} (${r.RepoId})` : r.RepoId;
    sel.appendChild(opt);
  }
  if (existing) {
    sel.value = existing.RepoId || 'main';
    sel.disabled = true;
  } else {
    // Prefer an explicitly requested repo (e.g. the Inventory repo being
    // viewed when "Subscribe" is clicked there), then the last-selected
    // Catalog repo, then the first active repo. This keeps the default as
    // "add to where I'm looking" rather than a stale Catalog selection.
    const preferred = defaultRepoId && active.some(r => r.RepoId === defaultRepoId)
      ? defaultRepoId
      : (state.selectedRepoId && active.some(r => r.RepoId === state.selectedRepoId)
          ? state.selectedRepoId
          : (active[0]?.RepoId || 'main'));
    sel.value = preferred;
    sel.disabled = false;
  }
  row.style.display = active.length > 1 ? '' : 'none';
}

async function openSubDialog(existing, defaultRepoId) {
  // The Arch picker needs the operator's preferred_architectures from
  // service.yaml. Load config on demand so the dialog works even before
  // the operator has visited the Settings tab.
  if (!state.cfg) {
    try { state.cfg = await api('config'); } catch { state.cfg = {}; }
  }

  $('#dlg-sub-title').textContent = existing ? `Edit subscription #${existing.SubscriptionId}` : 'Add subscription';
  const f = $('#frm-sub'); f.reset();
  rebuildSubRepoSelect(existing, defaultRepoId);
  state.pickedPackage = null;
  if (existing) {
    f.PackageId.value = existing.PackageId; f.PackageId.readOnly = true;
    f.Track.value = existing.Track;
    f.Version.value = existing.PinnedVersion || '';
    f.Locale.value = toArr(existing.Locale).join(',');
    f.Retention.value = existing.Retention;
    if (f.BinaryMode) f.BinaryMode.value = existing.BinaryMode || '';
    f.Notes.value = existing.Notes || '';
    f.SyncNow.checked = false; f.SyncNow.parentElement.style.display = 'none';
    btnPreview.disabled = false;
    pkgHint.textContent = 'package id is fixed for existing subscriptions';
  } else {
    f.PackageId.readOnly = false; f.SyncNow.parentElement.style.display = '';
    btnPreview.disabled = true;
    pkgHint.textContent = 'type to search the local upstream index';
  }
  // Initial Arch dropdown state: disabled placeholder. Edit case
  // fetches the upstream package below so we can constrain to actually-
  // available architectures.
  rebuildArchSelect(null, null);

  if (existing) {
    // The legacy free-text Arch column may carry a list or single value;
    // we treat the first element as the selected arch (the new dropdown
    // is single-select).
    const existingArch = toArr(existing.Arch)[0] || null;
    try {
      const pkg = await api(`upstream/package?id=${encodeURIComponent(existing.PackageId)}`);
      const arches = pkg?.Matrix ? collectAllArches(pkg) : [];
      state.pickedPackage = pkg;
      rebuildArchSelect(arches, existingArch);
    } catch {
      // Upstream index might not yet have this package (e.g., custom
      // adoption flow); show only the saved arch so the operator can
      // still edit other fields without losing state.
      rebuildArchSelect(existingArch ? [existingArch] : WINGET_ARCHES, existingArch);
    }
  }

  f.dataset.editingId = existing ? existing.SubscriptionId : '';
  setSubError(null);
  syncTrackWithPin();
  dlg.showModal();
}

// Pulls the union of every version's Architectures off a
// Get-RfUpstreamPackage response into a flat string array so the
// Arch dropdown can reflect 'every arch this package has ever shipped'
// rather than only the latest version's set.
function collectAllArches(pkg) {
  if (!pkg) return [];
  const seen = new Set();
  for (const v of pkg.Versions || []) {
    for (const a of toArr(v.Architectures)) {
      if (a) seen.add(String(a));
    }
  }
  return Array.from(seen);
}

function setSubError(msg) {
  const el = $('#dlg-sub-error');
  if (!msg) { el.hidden = true; el.textContent = ''; }
  else { el.hidden = false; el.textContent = msg; }
}

// When the operator types a Pinned version, flip Track to 'pinned' so the
// publisher doesn't silently discard the value. Reverse: clearing the
// version while Track=pinned reverts Track to 'latest'.
function syncTrackWithPin() {
  const f = $('#frm-sub');
  if (!f) return;
  const pinned = (f.Version.value || '').trim();
  if (pinned && f.Track.value !== 'pinned') f.Track.value = 'pinned';
  if (!pinned && f.Track.value === 'pinned') f.Track.value = 'latest';
}
// Wire the version <-> track coupling and clear the error on any edit.
document.addEventListener('input', ev => {
  if (!ev.target.form || ev.target.form.id !== 'frm-sub') return;
  if (ev.target.name === 'Version' || ev.target.name === 'Track') syncTrackWithPin();
  setSubError(null);
});
$('#frm-sub').addEventListener('submit', async ev => {
  ev.preventDefault();
  const f = ev.target;
  const fd = new FormData(f);
  const obj = {};
  for (const [k, v] of fd.entries()) obj[k] = v;
  // Arch is a single-choice dropdown constrained to architectures the
  // picked package actually ships. The API still expects an array, so
  // wrap the single value. ArchPick comes from the <select> control.
  delete obj.ArchPick;
  const archChoice = ($('#frm-sub-arch')?.value || '').trim();
  obj.Arch = archChoice ? [archChoice] : undefined;
  // Falls back to the currently-viewed repo if for some reason the
  // form did not include the field (disabled select on edit case, or
  // a single-repo deployment that hides the row).
  if (!obj.RepoId) {
    obj.RepoId = state.selectedRepoId || 'main';
  }
  obj.Locale = obj.Locale ? obj.Locale.split(',').map(s => s.trim()).filter(Boolean) : undefined;
  obj.Retention = obj.Retention ? Number(obj.Retention) : undefined;
  // Empty BinaryMode means 'inherit repo default'; send null so the API
  // clears the column (don't send '' which would fail the CHECK constraint).
  if (obj.BinaryMode === '') obj.BinaryMode = null;
  if (obj.Track !== 'pinned') delete obj.Version;
  obj.SyncNow = f.SyncNow.checked;
  const editingId = f.dataset.editingId;
  try {
    if (editingId) {
      const update = {
        Track: obj.Track, Version: obj.Version,
        Arch: obj.Arch, Locale: obj.Locale,
        Retention: obj.Retention, Notes: obj.Notes,
        BinaryMode: obj.BinaryMode,
      };
      await api(`subscriptions/${editingId}`, { method: 'PUT', body: JSON.stringify(update) });
      toast(`Updated #${editingId}`, 'ok');
    } else {
      const sub = await api('subscriptions', { method: 'POST', body: JSON.stringify(obj) });
      toast(`Added #${sub.SubscriptionId}`, 'ok');
    }
    dlg.close();
    await loadSubs();
  } catch (e) {
    setSubError(e.message);
    toast(`Save failed: ${e.message}`, 'bad');
  }
});
dlg.querySelector('[data-act=cancel]').onclick = () => dlg.close();

// --- package typeahead (powers Add subscription) ---
const pkgInput   = $('#pkg-search-input');
const pkgResults = $('#pkg-search-results');
const pkgHint    = $('#pkg-search-hint');
const pkgPreview = $('#dlg-pkg-preview');
const btnPreview = $('#btn-pkg-preview');
let pkgSearchTimer = null;
let pkgActiveIndex = -1;
let pkgLastResults = [];

function pkgSetActive(idx) {
  const rows = pkgResults.querySelectorAll('.row');
  rows.forEach((r, i) => r.classList.toggle('active', i === idx));
  pkgActiveIndex = idx;
  const active = rows[idx];
  if (active) active.scrollIntoView({ block: 'nearest' });
}

// Force any value to an array. The publisher serializes single-element arrays
// as a bare scalar (PowerShell ConvertTo-Json flattens them), so PackageName,
// InstallerTypes etc may arrive as null, a string, or an array.
// Render an ISO-8601 UTC string in the operator's local timezone.
// The raw ISO value stays on the cell's title attribute so a hover
// reveals the original UTC, and the visible cell shows local time.
// Falsy input returns an empty string so empty cells stay clean.
// Solution-wide display timezone (FD-026): RepoFabric is the authority for the
// whole fabric. Loaded once at boot from /healthz (config.timezone). Empty until
// loaded; formatLocalTime falls back to the browser zone only then or if it is
// invalid. Never assumes a locale-specific default.
let solutionTimeZone = '';
async function loadSolutionTimeZone() {
  try {
    const r = await fetch('healthz', { credentials: 'same-origin' });
    if (r.ok) { const j = await r.json(); if (j && j.timezone) solutionTimeZone = String(j.timezone); }
  } catch { /* leave empty -> browser-zone fallback */ }
}
function formatLocalTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  // Render in the SOLUTION timezone when known, else the browser zone.
  const opts = {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit',  minute: '2-digit', second: '2-digit',
    hour12: false, timeZoneName: 'short'
  };
  if (solutionTimeZone) opts.timeZone = solutionTimeZone;
  try {
    return d.toLocaleString(undefined, opts);
  } catch {
    // Invalid IANA zone -> fall back to the browser zone rather than throw.
    delete opts.timeZone;
    return d.toLocaleString(undefined, opts);
  }
}

// Normalise a "list-shaped" column from the publication table for display.
// The DB stored shape has evolved through three forms and old rows persist:
//   - JSON array string:  '["x64","x86"]'   (new, current)
//   - JSON scalar string: '"x64"'           (old single-element bug)
//   - Comma-joined:       'x64,x86'         (legacy walker output)
// Returns a human-readable comma-separated string for cell rendering.
function pubListDisplay(raw) {
  if (raw === null || raw === undefined || raw === '') return '';
  const s = String(raw).trim();
  if (s.startsWith('[')) {
    try { const a = JSON.parse(s); return Array.isArray(a) ? a.join(',') : String(a); } catch { return s; }
  }
  if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
    try { return JSON.parse(s); } catch { return s; }
  }
  return s;
}

function toArr(v) {
  if (Array.isArray(v)) return v;
  if (v === null || v === undefined || v === '') return [];
  return [String(v)];
}

function badgesHtml(m) {
  const cells = [
    { key: 'x64',    label: 'x64',    on: !!(m && m.HasX64),       title: 'x64 installer present' },
    { key: 'silent', label: 'silent', on: !!(m && m.HasSilent),    title: 'silent install supported (MSI/MSIX/WIX/APPX/BURN or explicit Silent switch)' },
    { key: 'signed', label: 'signed', on: !!(m && m.HasPublisher), title: 'manifest carries a Publisher value' },
  ];
  let html = cells.map(c => `<span class="badge ${c.on ? 'on' : 'off'}" title="${c.title}">${c.label}</span>`).join('');
  // Archive-wrapper signal lives outside the "all three" set because it is
  // an attribute of the manifest's InstallerType. This badge is
  // informational only.
  if (m && m.HasArchiveWrapper) {
    html += '<span class="badge archive" title="Manifest declares an archive container (zip/7z/gz/rar/tar). Informational.">archive</span>';
  }
  return html;
}

// Common ISO 639 / locale codes that appear as package_id suffixes in
// upstream winget-pkgs (Mozilla.Firefox.de, LibreOffice.LibreOffice.fr, ...).
// Used to filter out non-English variants by default.
const LOCALE_SUFFIX_RE = /\.(de|fr|it|es|pt|pt-BR|ja|ko|zh|zh-CN|zh-TW|ru|pl|nl|tr|cs|sv|da|fi|no|nb|nn|hu|el|ar|he|vi|th|id|hi|uk|ro|sk|sl|hr|bg|et|lv|lt|sr|fa|bn|ms|tl|sw|af|ca|eu|gl|is|mk|sq|am|km|lo|my|si|ne|mr|gu|kn|ml|or|pa|ta|te|ur|az|be|bs|hy|ka|kk|ky|mn|tt|uz)$/i;

function pkgRenderResults(q, items) {
  const showI18n = $('#pkg-search-show-i18n').checked;
  const filtered = showI18n ? items : items.filter(p => !LOCALE_SUFFIX_RE.test(p.PackageId));
  const hidden = items.length - filtered.length;
  pkgLastResults = filtered;
  pkgActiveIndex = -1;
  if (!q) { pkgHint.textContent = 'type to search the local upstream index'; }
  else if (!filtered.length) {
    if (hidden > 0) {
      pkgHint.textContent = `0 results (${hidden} non-English variants hidden)`;
    } else {
      pkgHint.textContent = `no matches for "${q}"`;
    }
    pkgResults.innerHTML = `<div class="empty">${hidden > 0 ? `${hidden} non-English locale variants hidden. Check the box above to show them.` : 'No matches in the local upstream index. Refresh the index from Operations if a package was just added.'}</div>`;
    pkgResults.hidden = false;
    return;
  } else {
    const more = items.length >= 100 ? ', refine your search for more' : '';
    const hiddenNote = hidden > 0 ? `, ${hidden} non-English hidden` : '';
    pkgHint.textContent = `${filtered.length} result${filtered.length === 1 ? '' : 's'}${hiddenNote}${more}`;
  }
  items = filtered;
  // Popularity badge: any non-zero score means winget.run returned
  // real traffic data for the package. The earlier percentile-based
  // threshold required 5+ scored items in the visible set to compute,
  // which silently dropped the badge whenever a focused search like
  // 'ch' surfaced just Google.Chrome above a sea of score-0 results.
  // Simple rule: if winget.run knows about it, show the badge.
  pkgResults.innerHTML = (items || []).map((p, i) => {
    const m = p.Matrix || {};
    const all = m.HasX64 && m.HasPublisher && m.HasSilent;
    const popular = Number(p.PopularityScore || 0) > 0;
    const popBadge = popular ? '<span class="badge badge-popular" title="Frequently requested on winget.run">popular</span>' : '';
    return `
    <div class="row${all ? ' row-fit' : ''}" data-idx="${i}" data-pid="${p.PackageId}">
      <span class="pid">${p.PackageId}</span>
      <span class="badges">${popBadge}${badgesHtml(m)}</span>
      <span class="pname">${p.PackageName || ''}</span>
      <span class="pver">${p.LatestVersion}${p.VersionCount > 1 ? ` (+${p.VersionCount - 1})` : ''}</span>
    </div>`;
  }).join('');
  pkgResults.hidden = !(items && items.length);
  pkgResults.querySelectorAll('.row').forEach(row => {
    row.addEventListener('mouseenter', () => {
      pkgSetActive(Number(row.dataset.idx));
      pkgScheduleHoverPreview(row.dataset.pid, row);
    });
    row.addEventListener('mouseleave', () => pkgScheduleHoverHide());
    row.addEventListener('click', () => pkgPick(row.dataset.pid));
  });
}

// Hover preview: 250ms after the operator parks the mouse on a row, fetch
// the full package detail and float a card next to the dropdown. The card
// stays visible while the row OR the card itself is hovered.
let pkgHoverTimer = null;
let pkgHoverHideTimer = null;
let pkgHoverCurrentPid = null;
function pkgScheduleHoverPreview(pid, anchor) {
  clearTimeout(pkgHoverHideTimer);
  if (pkgHoverCurrentPid === pid && !$('#pkg-hover-card').hidden) return;
  clearTimeout(pkgHoverTimer);
  pkgHoverTimer = setTimeout(() => pkgShowHoverPreview(pid, anchor), 250);
}
function pkgScheduleHoverHide() {
  clearTimeout(pkgHoverHideTimer);
  pkgHoverHideTimer = setTimeout(() => {
    const card = $('#pkg-hover-card');
    if (!card.matches(':hover')) {
      card.hidden = true;
      pkgHoverCurrentPid = null;
    }
  }, 200);
}
async function pkgShowHoverPreview(pid, anchor) {
  const card = $('#pkg-hover-card');
  pkgHoverCurrentPid = pid;
  card.innerHTML = '<div class="empty">loading...</div>';
  card.hidden = false;
  try {
    const pkg = await api(`upstream/package?id=${encodeURIComponent(pid)}`);
    if (pkgHoverCurrentPid !== pid) return; // user moved on
    card.innerHTML = renderHoverCardHtml(pkg);
  } catch (e) {
    if (pkgHoverCurrentPid === pid) card.innerHTML = `<div class="empty">error: ${e.message}</div>`;
  }
}
function renderHoverCardHtml(pkg) {
  const m = pkg.Matrix || {};
  const all = m.HasX64 && m.HasPublisher && m.HasSilent;
  const topVers = toArr(pkg.Versions).slice(0, 6).map(v => `
    <tr>
      <td class="ver">${v.Version}</td>
      <td>${badgesHtml(v.Matrix || {})}</td>
      <td class="muted">${toArr(v.Architectures).join(',') || '-'}</td>
      <td class="muted">${toArr(v.Locales).join(',') || '-'}</td>
      <td class="muted">${toArr(v.InstallerTypes).join(',') || '-'}</td>
    </tr>`).join('');
  const more = pkg.VersionCount > 6 ? `<div class="muted hover-more">+${pkg.VersionCount - 6} more versions, click Preview for full table</div>` : '';
  return `
    <div class="hover-head">
      <div class="hover-title">${pkg.PackageId}</div>
      <div class="hover-fit">${badgesHtml(m)} ${all ? '<span class="fit-all">all three</span>' : '<span class="fit-partial">partial</span>'}</div>
    </div>
    <dl class="hover-meta">
      <dt>Name</dt><dd>${pkg.PackageName || '(not indexed yet, run a re-walk)'}</dd>
      <dt>Publisher</dt><dd>${pkg.Publisher || '(not indexed yet)'}</dd>
      <dt>License</dt><dd>${pkg.License || '(not indexed yet)'}</dd>
      <dt>Latest</dt><dd>${pkg.LatestVersion} <span class="muted">(${pkg.VersionCount} versions)</span></dd>
      <dt>Description</dt><dd>${pkg.ShortDescription || '(not indexed yet)'}</dd>
    </dl>
    <table class="hover-versions">
      <thead><tr><th>Version</th><th>Fitness</th><th>Arch</th><th>Locales</th><th>Installer</th></tr></thead>
      <tbody>${topVers}</tbody>
    </table>
    ${more}`;
}
document.addEventListener('DOMContentLoaded', () => {
  loadSolutionTimeZone();   // FD-026: render timestamps in the solution timezone, not the browser's
  const card = document.getElementById('pkg-hover-card');
  if (card) {
    card.addEventListener('mouseenter', () => clearTimeout(pkgHoverHideTimer));
    card.addEventListener('mouseleave', () => pkgScheduleHoverHide());
  }
});

async function pkgSearch(q) {
  try {
    const body = await api(`upstream/search?q=${encodeURIComponent(q || '')}&limit=100`);
    pkgRenderResults(q, body.results || []);
  } catch (e) {
    pkgHint.textContent = `search failed: ${e.message}`;
    pkgResults.hidden = true;
  }
}

function pkgScheduleSearch(q) {
  clearTimeout(pkgSearchTimer);
  pkgSearchTimer = setTimeout(() => pkgSearch(q), 180);
}

function pkgPick(pid) {
  pkgInput.value = pid;
  pkgResults.hidden = true;
  btnPreview.disabled = false;
  pkgHint.textContent = `picked: ${pid}`;
  // Constrain the Arch dropdown to architectures this package actually
  // ships. pkgLastResults carries the search-row shape from
  // Search-RfUpstreamIndex which has Architectures as a flat array
  // (union across the latest version's installers).
  const picked = (pkgLastResults || []).find(r => r.PackageId === pid);
  state.pickedPackage = picked || null;
  const arches = picked ? toArr(picked.Architectures) : [];
  // Default the new subscription to the operator's most-preferred arch
  // that this package supports, falling back to the first available.
  rebuildArchSelect(arches, null);
  // Tell the backend which package the operator actually chose for the
  // last query so tier 1 of the next popularity refresh can promote it.
  // Best-effort fire-and-forget; never blocks the UI.
  const lastQuery = (pkgInput.dataset.lastQuery || '').trim();
  if (lastQuery) {
    api('upstream/search/resolved', { method: 'POST', body: JSON.stringify({ Query: lastQuery, PackageId: pid }) }).catch(() => {});
  }
}

pkgInput.addEventListener('input', () => {
  btnPreview.disabled = !pkgInput.value.trim();
  const q = pkgInput.value.trim();
  pkgInput.dataset.lastQuery = q;
  pkgScheduleSearch(q);
});
pkgInput.addEventListener('focus', () => {
  if (pkgInput.value.trim()) pkgScheduleSearch(pkgInput.value.trim());
  else pkgSearch('');
});
pkgInput.addEventListener('keydown', ev => {
  if (pkgResults.hidden) return;
  const rows = pkgResults.querySelectorAll('.row');
  if (ev.key === 'ArrowDown') { ev.preventDefault(); pkgSetActive(Math.min(rows.length - 1, pkgActiveIndex + 1)); }
  else if (ev.key === 'ArrowUp') { ev.preventDefault(); pkgSetActive(Math.max(0, pkgActiveIndex - 1)); }
  else if (ev.key === 'Enter' && pkgActiveIndex >= 0) {
    ev.preventDefault();
    pkgPick(rows[pkgActiveIndex].dataset.pid);
  } else if (ev.key === 'Escape') { pkgResults.hidden = true; }
});
document.addEventListener('click', ev => {
  if (!pkgResults.contains(ev.target) && ev.target !== pkgInput) pkgResults.hidden = true;
});
$('#pkg-search-show-i18n').addEventListener('change', () => {
  if (pkgInput.value.trim()) pkgSearch(pkgInput.value.trim());
});

btnPreview.onclick = async () => {
  const pid = pkgInput.value.trim(); if (!pid) return;
  $('#pkg-preview-title').textContent = `Package: ${pid}`;
  $('#pkg-preview-body').innerHTML = '<div class="empty">loading...</div>';
  pkgPreview.showModal();
  try {
    const pkg = await api(`upstream/package?id=${encodeURIComponent(pid)}`);
    renderPkgPreview(pkg);
  } catch (e) {
    $('#pkg-preview-body').innerHTML = `<div class="empty">error: ${e.message}</div>`;
  }
};

function renderPkgPreview(pkg) {
  const m = pkg.Matrix || {};
  const all = m.HasX64 && m.HasPublisher && m.HasSilent;
  const versions = toArr(pkg.Versions).map(v => `
    <tr>
      <td class="ver">${v.Version}</td>
      <td>${badgesHtml(v.Matrix || {})}</td>
      <td>${toArr(v.Architectures).join(',')}</td>
      <td>${toArr(v.Locales).join(',')}</td>
      <td>${toArr(v.InstallerTypes).join(',')}</td>
      <td class="muted" title="${v.LastSeenAt || ''}">${formatLocalTime(v.LastSeenAt)}</td>
    </tr>`).join('');
  $('#pkg-preview-body').innerHTML = `
    <div class="summary"><dl>
      <dt>Package ID</dt><dd>${pkg.PackageId}</dd>
      <dt>Name</dt><dd>${pkg.PackageName || '(none)'}</dd>
      <dt>Publisher</dt><dd>${pkg.Publisher || '(none)'}</dd>
      <dt>License</dt><dd>${pkg.License || '(none)'}</dd>
      <dt>Latest version</dt><dd>${pkg.LatestVersion}</dd>
      <dt>Total versions</dt><dd>${pkg.VersionCount}</dd>
      <dt>Description</dt><dd>${pkg.ShortDescription || ''}</dd>
      <dt>Fitness</dt><dd>${badgesHtml(m)} ${all ? '<span class="fit-all">all three signals present</span>' : '<span class="fit-partial">partial</span>'}</dd>
    </dl></div>
    <table>
      <thead><tr><th>Version</th><th>Fitness</th><th>Architectures</th><th>Locales</th><th>Installer types</th><th>Last seen UTC</th></tr></thead>
      <tbody>${versions}</tbody>
    </table>`;
}

pkgPreview.querySelector('[data-act=pkg-preview-close]').onclick = () => pkgPreview.close();
pkgPreview.querySelector('[data-act=pkg-preview-pick]').onclick = () => {
  // Already in the input. Just close.
  pkgPreview.close();
};

// Reset typeahead state when the dialog opens or closes.
dlg.addEventListener('close', () => {
  pkgResults.hidden = true; pkgResults.innerHTML = '';
  pkgHint.textContent = 'type to search the local upstream index';
  btnPreview.disabled = true;
});

// --- publications (legacy) ----------------------------------------------
// The Publications tab was retired; pub-count rendering happens inline
// in the managed-subscriptions table on the combined Subscriptions tab.
// Keep loadPubs / selectPub as no-ops for any external caller that still
// references the API surface, and guard the (removed) button bindings.
async function loadPubs() { /* combined view loads publications inline */ }
function selectPub() {}
if ($('#btn-pub-refresh')) $('#btn-pub-refresh').onclick = loadPubs;
if ($('#btn-pub-del'))     $('#btn-pub-del').onclick     = () => {};

// --- runs ---
// Activity feed: unified sync runs + admin events from /api/activity. The
// filter chip the operator last selected lives in state.activityFilter so
// switching back to the tab restores the same view.
state.activityFilter = 'all';

async function loadActivity() {
  try {
    const last = $('#activity-last').value || 50;
    const f    = state.activityFilter || 'all';
    const body = await api(`activity?last=${last}&type=${encodeURIComponent(f)}`);
    state.activity = (body && body.activity) || [];
    renderActivity();
  } catch (e) {
    toast(`Load activity: ${e.message}`, 'bad');
  }
}

function renderActivity() {
  const tbody = $('#activity-table tbody');
  if (!tbody) return;
  tbody.innerHTML = '';
  if (!state.activity || state.activity.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No activity in this filter yet. Try the All chip, or trigger a sync from the buttons above.</td></tr>';
    return;
  }
  for (const row of state.activity) {
    const tr = document.createElement('tr');
    const outcomeClass = ({
      succeeded: 'status-ok',
      failed:    'status-fail',
      partial:   'status-warn',
      running:   'status-warn',
    })[row.outcome] || 'status-skip';
    tr.innerHTML = `
      <td class="muted" title="${escAttr(row.ts)}">${formatLocalTime(row.ts)}</td>
      <td><code>${escHtml(renderEventLabel(row))}</code></td>
      <td>${escHtml(row.subject || '')}</td>
      <td class="muted">${escHtml(renderActor(row.actor))}</td>
      <td class="${outcomeClass}">${escHtml(row.outcome || '')}</td>
      <td>${escHtml(renderActivityDetail(row))}</td>`;
    tbody.appendChild(tr);
  }
}

// Event label: short stable token shown in the Event column.
function renderEventLabel(row) {
  return row.event || row.kind || '';
}

// Actor: convert internal container-uid placeholders to a friendlier
// SYSTEM label so the column reads as "who actually did this" rather
// than "what process logged it". Browser-authenticated rows carry the
// operator UPN (e.g. ringo@example.com) and pass through untouched.
function renderActor(actor) {
  if (!actor) return 'SYSTEM';
  if (actor === 'SYSTEM') return 'SYSTEM (scheduled)';
  // Pre-fix rows: container hostname (repofabric@<container-id>), supervisord
  // worker label (worker_1 / worker_2 / ...), or any value matching
  // these patterns. Treat all as SYSTEM-equivalent.
  if (/^repofabric@/.test(actor))     return 'SYSTEM (scheduled)';
  if (/^worker_\d+$/.test(actor)) return 'SYSTEM (worker)';
  return actor;
}

// Per-row detail cell. Each event kind/type gets a hand-written natural-
// language summary explaining what happened, not just a key=value dump.
// Falls back to a compact key=value join when an event type is not
// explicitly mapped, so new event kinds still render something useful.
function renderActivityDetail(row) {
  const d   = row.detail || {};
  const kind = (row.event || row.kind || '').toLowerCase();
  const subj = row.subject || '';

  // Sync / cleanup / index_refresh runs.
  if (row.kind === 'sync' || row.kind === 'cleanup' || row.kind === 'index_refresh' || row.kind === 'index-refresh') {
    const trig = d.trigger || 'manual';
    const trigPhrase = ({
      scheduled: 'Scheduled',
      manual:    'Manual',
      force:     'Operator force-sync',
    })[trig] || trig;
    const summaryWord = ({ sync: 'sync', cleanup: 'cleanup', index_refresh: 'index refresh', 'index-refresh': 'index refresh' })[row.kind] || row.kind;
    const counts = [];
    if (typeof d.changed === 'number' && d.changed > 0) counts.push(`${d.changed} changed`);
    if (typeof d.failed  === 'number' && d.failed  > 0) counts.push(`${d.failed} failed`);
    if (typeof d.skipped === 'number' && d.skipped > 0) counts.push(`${d.skipped} in correct state`);
    if (typeof d.succeeded === 'number' && d.succeeded > 0 && d.changed === 0) {
      counts.push(`${d.succeeded} already current`);
    }
    const tail = counts.length ? ` -- ${counts.join(', ')}` : ' -- no changes';
    return `${trigPhrase} ${summaryWord} (run #${d.run_id ?? '?'})${tail}.`;
  }

  // Admin events: hand-write a sentence per type.
  switch (kind) {
    case 'subscription_added': {
      const track = d.track ? ` (${d.track})` : '';
      const ver   = d.version ? ` pinned to ${d.version}` : '';
      return `Added subscription for ${subj}${track}${ver}.`;
    }
    case 'subscription_modified': {
      const changes = [];
      if (d.pin_state_changed) changes.push('pin');
      if (d.notes_changed)     changes.push('notes');
      const tail = changes.length ? ` (${changes.join(', ')} changed)` : '';
      return `Edited subscription for ${subj}${tail}.`;
    }
    case 'subscription_removed': {
      const tail = d.kept_repo_content
        ? ' -- repo content preserved, row only untracked'
        : ' -- repo content cleared from Gitea';
      const pubs = (typeof d.publications_count === 'number') ? ` (${d.publications_count} publication(s))` : '';
      return `Removed subscription for ${subj}${pubs}${tail}.`;
    }
    case 'custom_published': {
      const ver  = d.version ? ` @ ${d.version}` : '';
      const inst = (typeof d.installers === 'number') ? `, ${d.installers} installer(s)` : '';
      return `Published custom app ${subj}${ver}${inst}.`;
    }
    case 'custom_updated': {
      if (d.field === 'notes')    return `Edited notes on custom app ${subj}.`;
      if (d.field === 'manifest') return `Edited manifest for custom app ${subj}${d.version ? ' @ ' + d.version : ''}.`;
      return `Updated custom app ${subj}.`;
    }
    case 'custom_removed': {
      const tail = d.kept_repo_content
        ? ' -- Gitea manifest + installer left in place'
        : ' -- Gitea manifest + installer cleared';
      return `Removed custom app ${subj}${tail}.`;
    }
    case 'config_saved':       return 'Saved configuration changes.';
    case 'setup_completed':    return 'Completed first-run setup wizard.';
  }

  // Unmapped event: fall back to the old compact key=value dump so the
  // operator at least sees something.
  const keys = ['version','track','custom_id','subscription_id','repo_path','commit_sha','field','kept_repo_content','publications_count','installers'];
  const parts = [];
  for (const k of keys) {
    if (d && d[k] !== undefined && d[k] !== null && d[k] !== '') {
      let v = d[k];
      if (k === 'commit_sha' && typeof v === 'string') v = v.slice(0, 12);
      parts.push(`${k}=${v}`);
    }
  }
  return parts.join(' · ');
}

$('#btn-activity-refresh').onclick = loadActivity;
$('#activity-last').addEventListener('change', loadActivity);

// Filter chips: aria-pressed toggle + re-fetch.
document.querySelectorAll('.activity-filter').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.activity-filter').forEach(b => {
      b.classList.remove('is-active');
      b.setAttribute('aria-pressed', 'false');
    });
    btn.classList.add('is-active');
    btn.setAttribute('aria-pressed', 'true');
    state.activityFilter = btn.dataset.filter || 'all';
    loadActivity();
  });
});

// --- operations ---
// All long-running ops (sync + refresh) flow through the same async kick-off
// and the same status polling. The publisher writes a single shared status
// file, so the inline progress panel can represent both.
function disableOpButtons(on) {
  ['#btn-sync-all','#btn-sync-force','#btn-index-refresh'].forEach(s => {
    const el = $(s); if (el) el.disabled = on;
  });
}
async function runOp(label, body) {
  const out = $('#op-output');
  out.textContent += `[${new Date().toLocaleTimeString()}] starting: ${label}\n`;
  disableOpButtons(true);
  pollRefreshStatus._fails = 0;
  try {
    const r = await api('sync', { method: 'POST', body: JSON.stringify(body || {}) });
    // Bridge is by definition reachable if this call returned; clear any
    // stale unreachable state on the indicator without waiting for the
    // next 30s background probe.
    resetBridgeIndicatorOnSuccess();
    if (r && r.status) {
      updateRefreshUi(r.status);
    } else if (r && r.Status) {
      // synchronous fallback path (?sync=1) — render and we are done
      out.textContent += `[${new Date().toLocaleTimeString()}] ${label} -> ${r.Status} (changed=${r.Counters?.Changed ?? 0} failed=${r.Counters?.Failed ?? 0})\n`;
      toast(`${label}: ${r.Status}`, r.Status === 'succeeded' ? 'ok' : 'bad');
      disableOpButtons(false);
      return;
    }
    if (refreshPollTimer) clearInterval(refreshPollTimer);
    refreshPollTimer = setInterval(pollRefreshStatus, 2000);
  } catch (e) {
    disableOpButtons(false);
    out.textContent += `[${new Date().toLocaleTimeString()}] ${label} kick-off FAILED: ${e.message}\n`;
    toast(`${label} kick-off failed: ${e.message}`, 'bad');
  }
}
// Default "Sync subscriptions" runs the worker pool against the existing
// cached upstream index. Operators who want to refresh the index first
// use the dedicated "Refresh upstream index only" button, or click
// "Sync + refresh index" which does both in one job.
$('#btn-sync-all').onclick     = () => runOp('Sync subscriptions', { SkipIndexRefresh: true });
$('#btn-sync-force').onclick   = () => runOp('Sync + refresh index', { ForceIndexRefresh: true });
// Coarse percent map keyed by walker phase, used to fill the progress bar.
const REFRESH_PHASE_PCT = {
  starting: 5, sparse_checkout: 10, enum_started: 15, enum_done: 25,
  phase2_started: 30, phase2_done: 80, db_writing: 90, complete: 100, failed: 100,
};

function ensureRefreshUi() {
  let host = document.getElementById('op-refresh-progress');
  if (host) return host;
  host = document.createElement('div');
  host.id = 'op-refresh-progress';
  host.className = 'op-progress';
  host.hidden = true;
  host.innerHTML = `
    <div class="op-progress-head">
      <span class="op-progress-title">Upstream index refresh</span>
      <span class="op-progress-elapsed muted" id="op-refresh-elapsed">0s</span>
    </div>
    <div class="op-progress-bar"><div class="op-progress-fill" id="op-refresh-fill"></div></div>
    <div class="op-progress-line"><span class="op-progress-phase" id="op-refresh-phase">phase</span> <span class="op-progress-msg" id="op-refresh-msg"></span></div>
    <div class="op-progress-counts muted" id="op-refresh-counts"></div>`;
  $('#op-output').parentNode.insertBefore(host, $('#op-output'));
  return host;
}

function fmtElapsed(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0s';
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60), s = Math.round(seconds % 60);
  return `${m}m ${s.toString().padStart(2, '0')}s`;
}

function updateRefreshUi(status) {
  const host = ensureRefreshUi();
  host.hidden = false;
  host.classList.toggle('failed', status.phase === 'failed');
  host.classList.toggle('done', status.phase === 'complete');
  const pct = REFRESH_PHASE_PCT[status.phase] ?? 0;
  $('#op-refresh-fill').style.width = `${pct}%`;
  $('#op-refresh-phase').textContent = status.phase || 'unknown';
  $('#op-refresh-msg').textContent = status.message || '';
  const proc = status.processed || 0, total = status.total || 0;
  $('#op-refresh-counts').textContent = total
    ? `${proc.toLocaleString()} / ${total.toLocaleString()} rows`
    : (proc ? `${proc.toLocaleString()} rows` : '');
  if (status.started_at) {
    const startedMs = Date.parse(status.started_at);
    const endedMs = status.ended_at ? Date.parse(status.ended_at) : Date.now();
    $('#op-refresh-elapsed').textContent = fmtElapsed((endedMs - startedMs) / 1000);
  }
  // Cancel bar visibility tracks live phase: visible only while the
  // dispatch gate is closed (any phase outside the terminal set).
  const live = !['idle','complete','failed','unknown'].includes(status.phase);
  const cancelBar = $('#op-cancel-bar');
  if (cancelBar) cancelBar.hidden = !live;
}

$('#btn-op-cancel').onclick = async () => {
  const btn = $('#btn-op-cancel');
  if (!confirm('Force-cancel the running operation? The worker job will be killed and the in-flight gate cleared so new ops can start.')) return;
  btn.disabled = true;
  btn.textContent = 'Cancelling...';
  try {
    const r = await api('operations/cancel', { method: 'POST', body: JSON.stringify({ reason: 'Operator clicked Force cancel' }) });
    toast(`Cancelled. ${r.stopped} job(s) stopped.`, 'ok');
    if (r.status) updateRefreshUi(r.status);
    // Reopen the dispatch gate in the UI as well.
    disableOpButtons(false);
    if (refreshPollTimer) { clearInterval(refreshPollTimer); refreshPollTimer = null; }
    const out = $('#op-output');
    out.textContent += `[${new Date().toLocaleTimeString()}] operator force-cancel: stopped=${r.stopped}, status=${r.status?.phase}\n`;
  } catch (e) {
    toast(`Cancel failed: ${e.message}`, 'bad');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Force cancel running operation';
  }
};

let refreshPollTimer = null;
async function pollRefreshStatus() {
  try {
    const s = await api('index/refresh/status');
    updateRefreshUi(s);
    if (s.phase === 'complete' || s.phase === 'failed' || s.phase === 'idle' || s.phase === 'unknown') {
      clearInterval(refreshPollTimer);
      refreshPollTimer = null;
      disableOpButtons(false);
      const cls = s.phase === 'complete' ? 'ok' : (s.phase === 'failed' ? 'bad' : '');
      const out = $('#op-output');
      out.textContent += `[${new Date().toLocaleTimeString()}] index refresh -> ${s.phase}: ${s.message || ''}\n`;
      toast(`Index refresh ${s.phase}`, cls);
    }
  } catch (e) {
    // Transient errors (bridge restart, brief network blips) shouldn't kill the poll.
    // The next tick will catch up. Surface only if a poll fails three times in a row.
    pollRefreshStatus._fails = (pollRefreshStatus._fails || 0) + 1;
    if (pollRefreshStatus._fails >= 3) {
      clearInterval(refreshPollTimer);
      refreshPollTimer = null;
      disableOpButtons(false);
      toast(`Status poll failed: ${e.message}`, 'bad');
    }
  }
}

$('#btn-index-refresh').onclick = async () => {
  const out = $('#op-output');
  out.textContent += `[${new Date().toLocaleTimeString()}] starting upstream index refresh (async)...\n`;
  disableOpButtons(true);
  pollRefreshStatus._fails = 0;
  try {
    const r = await api('index/refresh', { method: 'POST' });
    resetBridgeIndicatorOnSuccess();
    updateRefreshUi(r.status || r);
    if (refreshPollTimer) clearInterval(refreshPollTimer);
    refreshPollTimer = setInterval(pollRefreshStatus, 2000);
  } catch (e) {
    disableOpButtons(false);
    out.textContent += `[${new Date().toLocaleTimeString()}] index refresh kick-off FAILED: ${e.message}\n`;
    toast(`Refresh kick-off failed: ${e.message}`, 'bad');
  }
};

// --- bridge service control ---
// The publisher exposes /service/{status,stop,restart}. Start is not wired up
// from here on purpose, because if the service is down the container cannot
// reach the publisher to ask it to start itself. The Activity tab surfaces
// reachability as a single small dot in the nav plus a banner that appears
// only after multiple consecutive failed probes (so a normal container
// restart does not nag).

// Bridge health indicator + banner.
//
// One small dot lives next to the Activity tab title in the nav. Color:
//   green  = last probe succeeded (bridge running)
//   yellow = recent failure but under the strike threshold (transient)
//   red    = >= STRIKE_THRESHOLD consecutive failures (banner shown)
//
// Probe runs every PROBE_INTERVAL ms in the background regardless of
// which tab is open. Any successful sync action also resets the counter
// on the spot so a successful op clears stale unreachable state.
const BRIDGE_PROBE_INTERVAL_MS = 30_000;
const BRIDGE_STRIKE_THRESHOLD  = 3;        // 3 consecutive failures -> red+banner
let bridgeStrikes = 0;
let bridgePollTimer = null;

function setBridgeIndicator(state, detail) {
  const dot     = $('#nav-bridge-dot');
  const banner  = $('#bridge-banner');
  const bState  = $('#bridge-banner-state');
  const bDetail = $('#bridge-banner-detail');
  if (dot) {
    dot.classList.remove('is-ok', 'is-warn', 'is-error');
    dot.classList.add(`is-${state}`);
    dot.title = ({
      ok:    'Bridge service: running',
      warn:  'Bridge service: transient probe failure',
      error: 'Bridge service: unreachable',
    })[state] || 'Bridge service status';
  }
  if (banner) {
    if (state === 'error') {
      banner.hidden = false;
      bState.textContent  = 'Bridge unreachable';
      bDetail.textContent = detail || `No response from the publisher after ${BRIDGE_STRIKE_THRESHOLD} consecutive probes (${(BRIDGE_PROBE_INTERVAL_MS*BRIDGE_STRIKE_THRESHOLD/1000)}s).`;
    } else {
      banner.hidden = true;
    }
  }
}

// Reset bridge state immediately. Called after a successful sync action
// (the bridge is by definition reachable if the action came back).
function resetBridgeIndicatorOnSuccess() {
  bridgeStrikes = 0;
  setBridgeIndicator('ok', null);
}

async function probeBridge() {
  try {
    const s = await api('service/status');
    const running = s && (s.state || '').toLowerCase() === 'running';
    if (running) {
      bridgeStrikes = 0;
      setBridgeIndicator('ok', null);
    } else {
      // Reachable but reporting non-running state; treat as a warning,
      // not a hard failure. Probe still counts the strike.
      bridgeStrikes += 1;
      const detail = `Bridge reports state '${s && s.state}'.`;
      setBridgeIndicator(bridgeStrikes >= BRIDGE_STRIKE_THRESHOLD ? 'error' : 'warn', detail);
    }
  } catch (e) {
    bridgeStrikes += 1;
    const detail = `Probe failed: ${e.message}. Container may be restarting; see docker logs repofabric-linux.`;
    setBridgeIndicator(bridgeStrikes >= BRIDGE_STRIKE_THRESHOLD ? 'error' : 'warn', detail);
  }
}

function startBridgeMonitor() {
  if (bridgePollTimer) return;
  // First probe is immediate so the indicator paints quickly on page load.
  probeBridge();
  bridgePollTimer = setInterval(probeBridge, BRIDGE_PROBE_INTERVAL_MS);
}

// Restart button lives in the banner. Confirm + POST + force-probe so the
// indicator catches up without waiting for the next interval.
$('#btn-svc-restart').addEventListener('click', async () => {
  if (!confirm('Restart the bridge?\n\nThe pwsh-bridge process self-exits and supervisord respawns it. Any sync, index refresh, or build in flight is aborted; the orphan-reset on the new pool will return queued rows to pending. The GUI recovers within ~5 seconds.')) return;
  const btn = $('#btn-svc-restart');
  btn.disabled = true; btn.textContent = 'Restarting...';
  try {
    const r = await api('service/restart', { method: 'POST' });
    toast(`Restart accepted (${r.service || 'RfBridge'})`, 'ok');
    // Give supervisord a moment then re-probe.
    setTimeout(probeBridge, 4000);
  } catch (e) {
    toast(`Restart failed: ${e.message}`, 'bad');
  } finally {
    btn.textContent = 'Restart bridge';
    btn.disabled = false;
  }
});

// If the operator reloads the tab while a refresh is in flight, pick up the
// poll loop so the progress bar reappears mid-run.
(async () => {
  try {
    const s = await api('index/refresh/status');
    const live = !['idle','complete','failed','unknown'].includes(s.phase);
    if (live) {
      updateRefreshUi(s);
      disableOpButtons(true);
      refreshPollTimer = setInterval(pollRefreshStatus, 2000);
    }
  } catch { /* bridge not yet ready */ }
})();

// Background bridge monitor: periodic probe + 3-strike banner gate. Runs
// regardless of active tab so the nav dot reflects current state at all
// times. Starts shortly after page load to avoid racing the bootstrap.
setTimeout(startBridgeMonitor, 500);

// --- settings (structured GUI editor) ---
//
// The publisher returns the parsed config as JSON. We render it as a set of
// labelled fields grouped by section, and on Save we POST back the structured
// shape; the publisher serializes to YAML and validates against the schema.
// A timestamped backup is written every time. Raw YAML view stays as a
// read-only pane behind the "Show raw YAML" toggle for troubleshooting.

// Schema-driven form definition. Keep this aligned with
// linux/src/Private/Config/Test-RfConfigSchema.ps1 (the live schema rules).
// The runtime files are service.yaml + solution.yaml under /var/lib/repofabric/config/.
//
// Field types:
//   text        — free-form string
//   email       — string validated as an email
//   number      — integer (min/max optional)
//   bool        — checkbox
//   select      — single-pick dropdown (options:[...])
//   multi-bool  — checkbox group, value is a list of the checked options
//   csv-list    — comma-separated free-form list (still freeform when the
//                 universe of values is open-ended, e.g. BCP-47 locales)
//   lines       — textarea, one item per line
//
// `help` describes the field; rendered as both an inline ⓘ tooltip and the
// browser-native `title` on the input, in view AND edit modes.
// Tier: 'default' renders at the top of Settings, 'advanced' is wrapped in
// a collapsed <details> below the Default cards. Subscription defaults and
// Custom publish defaults are the only sections operators touch routinely;
// everything else is one-time deployment configuration or rarely-tweaked
// tuning. See plan: docs/admin-ux-refresh.md.
const CFG_SECTIONS = [
  { key: 'target', title: 'Target stack (Gitea + nginx installer host)', tier: 'advanced', fields: [
    { k: 'gitea_url',          label: 'Gitea base URL',           type: 'text',   placeholder: 'https://gitea.example.com',
      help: 'Base URL of the Gitea instance hosting the manifest repo. https only, no trailing slash.' },
    { k: 'gitea_repo',         label: 'Gitea repo (<org>/<repo>)', type: 'text',  placeholder: 'repofabric/winget-manifests',
      help: 'Repository identifier in Gitea, in <org>/<repo> form. Manifests are committed under manifests/<letter>/<vendor>/<package>/<version>/ inside this repo.' },
    { k: 'gitea_branch',       label: 'Gitea branch',             type: 'text',   placeholder: 'main',
      help: 'Branch to push manifest changes to. Usually main. The branch must already exist.' },
    { k: 'gitea_user',         label: 'Gitea user',               type: 'text',
      help: 'HTTPS basic-auth username for Gitea AND the git author identity on every publish commit.' },
    { k: 'gitea_author_email', label: 'Gitea author email',       type: 'email',
      help: 'Email recorded as the git author on every commit.' },
    { k: 'installer_base_url', label: 'Installer base URL',       type: 'text',   placeholder: 'https://installers.example.com',
      help: 'Public https origin where installer binaries are served from. Manifests rewrite their InstallerUrl to <installer_base_url>/<package>/<version>/<filename>. No trailing slash. The repofabric-linux container serves the files directly on host port 8091.' },
    { k: 'rewinged_health_url', label: 'rewinged health URL',     type: 'text',
      help: 'https://.../api/information endpoint exposed by rewinged. Used as the source URL discovery target and surfaced on the Activity tab health probe.' },
  ]},
  { key: 'paths', title: 'Paths', tier: 'advanced', fields: [
    { k: 'cache_dir',        label: 'Cache dir',        type: 'text',
      help: 'Local directory where downloaded installer binaries are cached during acquisition.' },
    { k: 'staging_dir',      label: 'Staging dir',      type: 'text',
      help: 'Local directory where transformed manifests are assembled before publish.' },
    { k: 'log_dir',          label: 'Log dir',          type: 'text',
      help: 'Local directory where the structured JSONL run logs are written.' },
    { k: 'state_db',         label: 'State database file', type: 'text',
      help: 'Full path to the SQLite state database. Holds subscriptions, runs, publications, the upstream index.' },
    { k: 'manifest_workdir', label: 'Manifest workdir', type: 'text',
      help: 'Local working clone of the Gitea manifest repo. Auto-managed; do not edit by hand.' },
  ]},
  { key: 'display', title: 'Display', tier: 'default', fields: [
    { k: 'timezone', label: 'Display timezone', type: 'datalist', optionsSource: 'timezones',
      placeholder: 'Type to search, e.g. America/Toronto, Europe/London, Asia/Tokyo, UTC',
      options: [
        { value: 'UTC' }, { value: 'America/Los_Angeles' }, { value: 'America/Denver' },
        { value: 'America/Chicago' }, { value: 'America/New_York' },
      ],
      help: 'Timezone for ALL timestamps across the whole fabric solution: RepoFabric, plus any co-hosted (sidecar) or cross-host ConfigFabric / DSCForge. RepoFabric is the authority (FD-026). Type to search the full IANA timezone list (every zone the browser knows). Default UTC; never locale-guessed. Takes effect on the next container restart / module reload.' },
  ]},
  { key: 'subscription_defaults', title: 'Subscription defaults', tier: 'default', fields: [
    { k: 'arch',   label: 'Default architectures', type: 'multi-bool',
      options: [
        { value: 'x64',   label: 'x64',   help: '64-bit Intel/AMD. The dominant Windows architecture.' },
        { value: 'x86',   label: 'x86',   help: '32-bit Intel. Useful as fallback when only legacy installers are published.' },
        { value: 'arm64', label: 'arm64', help: '64-bit ARM (Surface Pro X, Snapdragon laptops).' },
      ],
      help: 'Architectures published by default for new subscriptions that do not override. At least one must be ticked.' },
    { k: 'locale',    label: 'Default locales',       type: 'csv-list', placeholder: 'en-US, en-CA',
      help: 'BCP-47 locale tags published by default for new subscriptions. Free-form because the universe of locales is open.' },
    { k: 'retention', label: 'Default retention (versions kept)', type: 'number', min: 1,
      help: 'How many recent versions to keep, in addition to all pinned versions. Minimum 1.' },
  ]},
  { key: 'custom_publish', title: 'Custom publish defaults', tier: 'default', fields: [
    { k: 'package_identifier_prefix', label: 'PackageIdentifier prefix', type: 'text', placeholder: 'e.g. RingoSystems',
      help: 'Leading token (the part before the dot) the Publish Custom wizard prepends to the binary\'s MSI "Subject" or EXE FileDescription when auto-building PackageIdentifier. Spaces and non [A-Za-z0-9._-] characters are stripped at use-time. Leave blank to fall back to the installer\'s Publisher / Manufacturer field.' },
  ]},
  { key: 'installers', title: 'Bandwidth / peer distribution', tier: 'default', fields: [
    { k: 'peerdist_enabled', label: 'Enable PeerDist peer caching', type: 'bool',
      help: 'When on, the installer endpoint answers BranchCache/BITS clients (Accept-Encoding: peerdist) with an MS-PCCRC content-information body so endpoints on the same subnet share installer blocks peer-to-peer instead of each re-downloading from the server. Leave off during the initial baseline window. This flag also drives whether generated client-config scripts and the Intune deployment include the BranchCache/BITS/Delivery-Optimization client settings. Takes effect on the next container restart / module reload.' },
  ]},
  { key: 'operational', title: 'Operational thresholds', tier: 'advanced', fields: [
    { k: 'free_space_warning_pct',         label: 'Free-space warning %',           type: 'number', min: 1, max: 99,
      help: 'Surface a WARN row in the health table when any tracked volume is below this percent free. 1..99.' },
    { k: 'index_refresh_threshold_hours',  label: 'Index refresh threshold (h)',    type: 'number', min: 1,
      help: 'How fresh the upstream index must be before a default sync skips the refresh. Bigger values speed up routine syncs at the cost of upstream-change latency.' },
  ]},
  { key: 'notifications', title: 'Notifications', tier: 'advanced', fields: [
    { k: 'enabled',                    label: 'Notifications enabled',         type: 'bool',
      help: 'Master switch. When off, runs and cleanups produce no email regardless of category.' },
    { k: 'notes_survive_retention',    label: 'Notes survive retention',       type: 'bool',
      help: 'When on, publication notes are archived to publication_notes_archive on retention eviction instead of being deleted with the row.' },
    { k: 'heartbeat_enabled',          label: 'Heartbeat enabled',             type: 'bool',
      help: 'Send a periodic all-quiet heartbeat so a silent failure of the publisher is detectable as missing heartbeat.' },
    { k: 'heartbeat_suppression_days', label: 'Heartbeat suppression (days)',  type: 'number', min: 1,
      help: 'Days between heartbeats. Smaller = more email; bigger = slower silent-failure detection.' },
  ]},
  { key: 'smtp', title: 'SMTP relay', tier: 'advanced', fields: [
    { k: 'host',                label: 'Host',     type: 'text',
      help: 'Hostname or IP of the SMTP relay. Required when notifications are enabled.' },
    { k: 'port',                label: 'Port',     type: 'number', min: 1, max: 65535,
      help: 'TCP port. 25 (none/starttls), 587 (starttls), 465 (tls). Match the security setting.' },
    { k: 'security',            label: 'Security', type: 'select',
      options: [
        { value: 'none',     label: 'none',     help: 'Plaintext SMTP. Only for trusted local relays.' },
        { value: 'starttls', label: 'starttls', help: 'Plaintext then upgrade to TLS via STARTTLS. Standard for port 587.' },
        { value: 'tls',      label: 'tls',      help: 'Implicit TLS from the first byte. Standard for port 465.' },
      ],
      help: 'TLS posture on the connection to the relay.' },
    { k: 'auth',                label: 'Auth',     type: 'select',
      options: [
        { value: 'none',  label: 'none',  help: 'No authentication. Only for trusted local relays.' },
        { value: 'basic', label: 'basic', help: 'AUTH PLAIN / LOGIN. Username from this form; password from REPOFABRIC_SMTP_PASSWORD in .env / secrets.' },
      ],
      help: 'How the publisher authenticates to the SMTP relay.' },
    { k: 'username',            label: 'Username (when auth = basic)', type: 'text',
      help: 'SMTP username. Used only when auth = basic.' },
    { k: 'from',                label: 'From',     type: 'email',
      help: 'Envelope-from + RFC 5322 From: header on outgoing notification emails.' },
    { k: 'to',                  label: 'To (one per line)', type: 'lines',
      help: 'Recipient list. At least one address required. Use a distribution list if you have more than three on-call humans.' },
    { k: 'timeout_seconds',     label: 'Timeout (s)', type: 'number', min: 1,
      help: 'Seconds to wait for the relay to accept the message before declaring delivery failed.' },
  ]},
];

let cfgEditing = false;

async function loadCfg() {
  try {
    state.cfg = await api('config');
    renderCfgForm(state.cfg, /*editable*/ false);
    $('#cfg-yaml').textContent = JSON.stringify(state.cfg, null, 2);
    cfgExitEditMode();
  } catch (e) {
    // Bridge unreachable / publisher down: render a clear in-page banner
    // instead of just a toast. The empty form was confusing; the operator
    // had no signal whether the page was loading, broken, or empty.
    const root = $('#cfg-form');
    if (root) {
      root.innerHTML = `
        <div class="cfg-unavailable">
          <strong>Configuration is unavailable right now.</strong>
          <p>The publisher is not answering, so this page cannot read or write settings.</p>
          <p class="muted">Last error: <code>${escHtml(e.message)}</code></p>
          <p class="muted">Open the Activity tab and check the bridge service banner. The page recovers automatically when the bridge is reachable again.</p>
          <p><button class="ghost" id="btn-cfg-retry">Retry</button></p>
        </div>`;
      const retry = document.getElementById('btn-cfg-retry');
      if (retry) retry.addEventListener('click', loadCfg);
    }
    toast(`Load config: ${e.message}`, 'bad');
  }
}

function renderCfgForm(cfg, editable) {
  const root = $('#cfg-form');
  root.innerHTML = '';
  const safeCfg = cfg || {};

  // Default tier: routine knobs the operator actually touches.
  for (const sec of CFG_SECTIONS) {
    if (sec.tier !== 'default') continue;
    root.appendChild(renderCfgSection(sec, safeCfg, editable));
  }

  // Intune policy export card. Not a config section; a CTA card that
  // opens the existing full-page wizard. Lives in Default so the link
  // is one click from the landing view.
  root.appendChild(renderIntuneCard());

  // Per-repo client-config script download card. Populated async.
  root.appendChild(renderClientConfigCard());

  // Advanced tier: one-time deployment config + rarely-tweaked tuning,
  // wrapped in a collapsed <details> so it does not dominate the page.
  const adv = document.createElement('details');
  adv.className = 'cfg-section cfg-advanced';
  adv.innerHTML = `
    <summary>
      <span class="cfg-advanced-title">Advanced configuration</span>
      <span class="cfg-advanced-sub">Target stack, paths, notifications, SMTP relay. Touched at deployment time; rarely after.</span>
    </summary>`;
  const advBody = document.createElement('div');
  advBody.className = 'cfg-advanced-body';
  for (const sec of CFG_SECTIONS) {
    if (sec.tier !== 'advanced') continue;
    advBody.appendChild(renderCfgSection(sec, safeCfg, editable));
  }
  // System card lives at the bottom of Advanced: operator-actionable
  // buttons that do not fit the form-based fields above. Currently
  // hosts the Re-enter setup wizard button.
  advBody.appendChild(renderSystemCard());
  adv.appendChild(advBody);
  root.appendChild(adv);
}

// System card. CTA-only; no fields. Houses operator actions that
// are not configuration values: re-enter setup, future health re-run
// triggers, future repair-cache buttons, etc.
function renderSystemCard() {
  const block = document.createElement('section');
  block.className = 'cfg-section cfg-system-card';
  block.innerHTML = `
    <h3>System <small class="muted">operator actions</small></h3>
    <p class="cfg-system-row" id="row-connect-entra" hidden>
      <a class="btn" id="btn-connect-entra" href="./connect-entra.html">Connect Microsoft Entra sign-in</a>
      <small class="cfg-system-hint" id="hint-connect-entra">This deployment uses a local admin account. Connect Microsoft Entra to switch sign-in to your organization's accounts. The local admin stays as a break-glass fallback.</small>
    </p>
    <p class="cfg-system-row">
      <button type="button" class="ghost" id="btn-reenter-setup">Re-enter setup wizard</button>
      <small class="cfg-system-hint">Re-opens the first-run wizard from step 1 (Targets). Useful when a target endpoint moved or you misconfigured something at first boot. The current admin session keeps working; the wizard runs in parallel until you save.</small>
    </p>`;
  // Wire the click handler after the element is in the DOM tree.
  setTimeout(() => {
    const btn = document.getElementById('btn-reenter-setup');
    if (btn && !btn.dataset.wired) {
      btn.dataset.wired = '1';
      btn.addEventListener('click', reEnterSetupWizard);
    }
    // Connect-Entra is a sandbox-only action (a production deploy already runs
    // on Entra). Reveal it for a sandbox deployment, and re-label once Entra is
    // already connected so the button reads as "reconfigure".
    fetch('api/features', { credentials: 'same-origin' })
      .then(r => r.ok ? r.json() : null)
      .then(f => {
        if (!f || !f.sandbox) return;
        const row = document.getElementById('row-connect-entra');
        if (row) row.hidden = false;
        if (f.entra_configured) {
          const b = document.getElementById('btn-connect-entra');
          const h = document.getElementById('hint-connect-entra');
          if (b) b.textContent = 'Reconfigure Microsoft Entra sign-in';
          if (h) h.textContent = 'Microsoft Entra is connected. Re-run the wizard to rotate the client secret or update the app registration. The local admin remains as a break-glass fallback.';
        }
      })
      .catch(() => { /* features probe failed -> leave the action hidden */ });
  }, 0);
  return block;
}

async function reEnterSetupWizard() {
  if (!confirm('Re-enter the setup wizard?\n\nA new one-time setup token is generated and printed to the container console. The current admin session keeps working; the wizard runs in parallel until you save -- at which point the current YAML files are overwritten with whatever the wizard collects.')) return;
  const btn = document.getElementById('btn-reenter-setup');
  if (btn) { btn.disabled = true; btn.textContent = 'Generating token...'; }
  try {
    const r = await api('setup/re-enter', { method: 'POST' });
    const token = r && r.token ? r.token : null;
    if (!token) throw new Error('No token returned by the server.');
    // Show the token in a copy-able modal so the operator does not
    // have to docker-exec into the container to fish it out.
    const w = window.open('about:blank', '_blank', 'noopener');
    if (w) {
      w.document.write(`
        <html><head><title>REPOFABRIC setup token</title></head><body style="font-family:system-ui;background:#0f1115;color:#d6dae3;padding:32px;">
          <h2 style="color:#4fa3ff;">Setup wizard re-entered</h2>
          <p>Paste this token into the wizard's first step:</p>
          <p><code style="background:#000;padding:10px 14px;font-size:16px;border-radius:6px;display:inline-block;">${token}</code></p>
          <p><a href="/setup/" style="color:#4fa3ff;">Open the setup wizard</a></p>
          <p style="color:#7d8492;">The token is also printed to the container console (<code>docker logs repofabric-linux</code>).</p>
        </body></html>`);
      w.document.close();
    } else {
      // Popup blocked: fall back to an in-page toast.
      toast(`Setup re-entered. Token: ${token} (copy from docker logs repofabric-linux)`, 'ok');
    }
  } catch (e) {
    toast(`Re-enter failed: ${e.message}`, 'bad');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Re-enter setup wizard'; }
  }
}

// One <section> per CFG_SECTIONS entry. Pulled out so both Default and
// Advanced renderers reuse the exact same shape.
function renderCfgSection(sec, safeCfg, editable) {
  const secObj = safeCfg[sec.key] || {};
  const block = document.createElement('section');
  block.className = 'cfg-section';
  block.dataset.section = sec.key;
  block.innerHTML = `<h3>${escHtml(sec.title)} <small class="muted">${sec.key}</small></h3>`;
  const grid = document.createElement('div');
  grid.className = 'cfg-fields';
  for (const f of sec.fields) {
    grid.appendChild(renderCfgField(sec.key, f, secObj[f.k], editable));
  }
  block.appendChild(grid);
  return block;
}

// Intune policy export card. Single discoverable home for the Intune
// wizard (previously also surfaced as a button in the Subscriptions
// toolbar; that copy was removed when this card landed).
function renderIntuneCard() {
  const block = document.createElement('section');
  block.className = 'cfg-section cfg-intune-card';
  block.innerHTML = `
    <h3>Intune policy export <small class="muted">deploy</small></h3>
    <p class="cfg-intune-body">
      Build a Settings Catalog policy that locks managed Windows clients to
      this WinGet REST source. Opens a wizard, lets you tune the per-policy
      switches, and downloads a JSON file an Intune admin imports.
    </p>
    <p class="cfg-intune-cta">
      <a class="btn" href="./intune-deploy.html">Open Intune export wizard</a>
    </p>`;
  return block;
}

// Per-repo client configuration scripts. One standalone PowerShell 5/7
// script per winget repo that registers the source, applies silent
// defaults, and (when peerdist is enabled) configures BranchCache/BITS/DO
// peer caching. Populated asynchronously from /api/client-config.
function renderClientConfigCard() {
  const block = document.createElement('section');
  block.className = 'cfg-section cfg-clientcfg-card';
  block.innerHTML = `
    <h3>Client configuration scripts <small class="muted">deploy</small></h3>
    <p class="cfg-intune-body">
      Two standalone PowerShell 5/7 scripts per winget repo, run elevated on a
      Windows client. <strong>Client config</strong> registers the source as
      Trusted (winget source add), applies the always-silent winget defaults,
      and — when peer distribution is enabled — configures BranchCache, BITS
      Peercaching, and Delivery Optimization. <strong>Policy</strong> writes the
      DesktopAppInstaller policy stack (the Intune Settings Catalog equivalent:
      lockdown toggles + policy-pinned source) to the local Group Policy
      registry. <strong>Peer-cache test</strong> is a read-only diagnostic that
      shows where installer bytes actually came from (LAN peers vs origin
      server), with an optional live download test to confirm savings. They are
      separate by design; run any of them.
    </p>
    <div class="cfg-clientcfg-list"><span class="muted">Loading repos…</span></div>`;
  const listEl = block.querySelector('.cfg-clientcfg-list');
  api('client-config').then(data => {
    const targets = (data && data.targets) || [];
    const pd = data && data.peerdistEnabled
      ? '<p class="cfg-clientcfg-pd ok">Peer caching is ON — generated scripts include the BranchCache/BITS/DO block.</p>'
      : '<p class="cfg-clientcfg-pd muted">Peer caching is OFF — scripts register the source and silent defaults only. Enable it above to include peer caching.</p>';
    if (targets.length === 0) {
      listEl.innerHTML = pd + '<p class="muted">No winget repos configured yet.</p>';
      return;
    }
    const rows = targets.map(t => {
      if (!t.ready) {
        return `<li class="cfg-clientcfg-row"><span class="cfg-clientcfg-name">${escHtml(t.displayName)}</span>
          <span class="muted">unavailable — ${escHtml(t.note || 'no hostname')}</span></li>`;
      }
      const href = `api/client-config/${encodeURIComponent(t.repoId)}/script`;
      const polHref = `api/intune-policy-script/${encodeURIComponent(t.repoId)}/script`;
      const diagHref = `api/peer-cache-script/${encodeURIComponent(t.repoId)}/script`;
      const modeTag = t.mode === 'subdir'
        ? `<small class="cfg-clientcfg-mode muted" title="${escAttr(t.note || '')}">subdirectory — proxy must route this path</small>`
        : (t.mode === 'fqdn' ? '<small class="cfg-clientcfg-mode muted">dedicated host</small>' : '');
      return `<li class="cfg-clientcfg-row">
        <span class="cfg-clientcfg-name">${escHtml(t.displayName)}</span>
        <code class="cfg-clientcfg-src">${escHtml(t.sourceName)} → ${escHtml(t.sourceUrl)}</code>${modeTag}
        <a class="btn" href="${href}" download title="Source registration (winget source add), silent defaults, and peer caching">Client config .ps1</a>
        <a class="btn ghost" href="${polHref}" download title="DesktopAppInstaller policy stack written to the local GP registry (Intune policy equivalent)">Policy .ps1</a>
        <a class="btn ghost" href="${diagHref}" download title="Read-only diagnostic: shows whether installer bytes came from LAN peers or the origin server, with an optional live test">Peer-cache test .ps1</a>
      </li>`;
    }).join('');
    listEl.innerHTML = pd + `<ul class="cfg-clientcfg-ul">${rows}</ul>`;
  }).catch(e => {
    listEl.innerHTML = `<p class="muted">Could not load repos: ${escHtml(e.message)}</p>`;
  });
  return block;
}

function renderCfgField(sectionKey, field, value, editable) {
  const wrap = document.createElement('div');
  wrap.className = 'cfg-field';
  wrap.dataset.section = sectionKey;
  wrap.dataset.key = field.k;
  wrap.dataset.type = field.type;
  const id = `cfg-${sectionKey}-${field.k}`;
  const titleAttr = field.help ? `title="${escAttr(field.help)}"` : '';
  let inputHtml;
  switch (field.type) {
    case 'bool':
      inputHtml = `<input type="checkbox" id="${id}" ${titleAttr} ${value ? 'checked' : ''} ${editable ? '' : 'disabled'}>`;
      break;
    case 'select': {
      const opts = (field.options || []).map(o => {
        const v = typeof o === 'string' ? o : o.value;
        const lbl = typeof o === 'string' ? o : (o.label || o.value);
        const oHelp = typeof o === 'string' ? '' : (o.help || '');
        const t = oHelp ? ` title="${escAttr(oHelp)}"` : '';
        return `<option value="${escAttr(v)}"${t} ${v === value ? 'selected' : ''}>${escHtml(lbl)}</option>`;
      }).join('');
      inputHtml = `<select id="${id}" ${titleAttr} ${editable ? '' : 'disabled'}>${opts}</select>`;
      break;
    }
    case 'datalist': {
      // Free-text input backed by a <datalist> so the operator gets native
      // type-to-search over a large option set (e.g. all IANA timezones).
      let list = [];
      if (field.optionsSource === 'timezones') {
        try {
          if (typeof Intl !== 'undefined' && typeof Intl.supportedValuesOf === 'function') {
            list = Intl.supportedValuesOf('timeZone');
          }
        } catch { list = []; }
      }
      if (!Array.isArray(list) || !list.length) {
        // Older browser without Intl.supportedValuesOf: fall back to the
        // curated short list declared on the field.
        list = (field.options || []).map(o => (typeof o === 'string' ? o : o.value));
      }
      if (!list.includes('UTC')) list = ['UTC', ...list];
      const listId = `${id}-list`;
      const dlOpts = list.map(v => `<option value="${escAttr(v)}"></option>`).join('');
      inputHtml = `<input type="text" id="${id}" list="${listId}" ${titleAttr} value="${escAttr(value ?? '')}" placeholder="${escAttr(field.placeholder || '')}" autocomplete="off" ${editable ? '' : 'readonly'}><datalist id="${listId}">${dlOpts}</datalist>`;
      break;
    }
    case 'multi-bool': {
      // Render a horizontal row of checkboxes; each option has its own
      // tooltip explaining what the value means.
      const set = new Set(Array.isArray(value) ? value : []);
      const cells = (field.options || []).map(o => {
        const checked = set.has(o.value);
        const oHelp = o.help || '';
        const t = oHelp ? ` title="${escAttr(oHelp)}"` : '';
        return `<label class="multi-bool-opt"${t}><input type="checkbox" data-multi-value="${escAttr(o.value)}" ${checked ? 'checked' : ''} ${editable ? '' : 'disabled'}> ${escHtml(o.label)}</label>`;
      }).join('');
      inputHtml = `<div class="multi-bool" id="${id}" ${titleAttr}>${cells}</div>`;
      break;
    }
    case 'csv-list': {
      const text = Array.isArray(value) ? value.join(', ') : (value || '');
      inputHtml = `<input type="text" id="${id}" ${titleAttr} value="${escAttr(text)}" placeholder="${escAttr(field.placeholder || '')}" ${editable ? '' : 'readonly'}>`;
      break;
    }
    case 'lines': {
      const text = Array.isArray(value) ? value.join('\n') : (value || '');
      inputHtml = `<textarea id="${id}" rows="3" ${titleAttr} ${editable ? '' : 'readonly'}>${escHtml(text)}</textarea>`;
      break;
    }
    case 'number':
      inputHtml = `<input type="number" id="${id}" ${titleAttr} value="${escAttr(value ?? '')}" ${field.min !== undefined ? `min="${field.min}"` : ''} ${field.max !== undefined ? `max="${field.max}"` : ''} ${editable ? '' : 'readonly'}>`;
      break;
    case 'email':
      inputHtml = `<input type="email" id="${id}" ${titleAttr} value="${escAttr(value ?? '')}" ${editable ? '' : 'readonly'}>`;
      break;
    default:
      inputHtml = `<input type="text" id="${id}" ${titleAttr} value="${escAttr(value ?? '')}" placeholder="${escAttr(field.placeholder || '')}" ${editable ? '' : 'readonly'}>`;
  }

  // Header row: label + ⓘ tooltip badge (visible in BOTH view and edit modes
  // so the operator can self-onboard without flipping into edit).
  const helpIcon = field.help
    ? `<span class="cfg-help" tabindex="0" title="${escAttr(field.help)}" aria-label="${escAttr(field.help)}">&#9432;</span>`
    : '';
  wrap.innerHTML = `<label class="cfg-label-row" for="${id}"><span class="cfg-label">${escHtml(field.label)}</span>${helpIcon}</label>${inputHtml}${field.help ? `<small class="cfg-help-text">${escHtml(field.help)}</small>` : ''}`;

  return wrap;
}

function gatherCfgFromForm() {
  // Start from the live config so unknown / not-yet-modelled keys are
  // preserved instead of silently stripped on save.
  const out = JSON.parse(JSON.stringify(state.cfg || {}));
  for (const sec of CFG_SECTIONS) {
    if (!out[sec.key] || typeof out[sec.key] !== 'object') out[sec.key] = {};
    for (const f of sec.fields) {
      const id = `cfg-${sec.key}-${f.k}`;
      const el = document.getElementById(id);
      if (!el) continue;
      switch (f.type) {
        case 'bool':
          out[sec.key][f.k] = el.checked;
          break;
        case 'select':
          out[sec.key][f.k] = el.value;
          break;
        case 'datalist':
          // Free-text + datalist. Trim; empty falls back to the backend default
          // (UTC for the timezone field) rather than persisting a blank.
          out[sec.key][f.k] = el.value.trim();
          break;
        case 'multi-bool': {
          const picked = Array.from(el.querySelectorAll('input[type="checkbox"]'))
            .filter(c => c.checked)
            .map(c => c.dataset.multiValue);
          out[sec.key][f.k] = picked;
          break;
        }
        case 'csv-list':
          out[sec.key][f.k] = el.value.split(',').map(s => s.trim()).filter(Boolean);
          break;
        case 'lines':
          out[sec.key][f.k] = el.value.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
          break;
        case 'number': {
          const v = el.value.trim();
          if (v === '') { delete out[sec.key][f.k]; }
          else { out[sec.key][f.k] = Number(v); }
          break;
        }
        default: {
          const v = el.value;
          // Preserve empties as empty string; the schema validator decides if a
          // missing field is fatal (vs blank-but-permitted).
          out[sec.key][f.k] = v;
        }
      }
    }
  }
  return out;
}

function escHtml(s)  { return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function escAttr(s)  { return escHtml(s); }

function cfgEnterEditMode() {
  cfgEditing = true;
  renderCfgForm(state.cfg, true);
  $('#btn-cfg-edit').hidden   = true;
  $('#btn-cfg-save').hidden   = false;
  $('#btn-cfg-cancel').hidden = false;
  $('#cfg-warning').hidden    = false;
  $('#cfg-edit-hint').textContent = 'editing structured form';
}
function cfgExitEditMode() {
  cfgEditing = false;
  renderCfgForm(state.cfg, false);
  $('#btn-cfg-edit').hidden   = false;
  $('#btn-cfg-save').hidden   = true;
  $('#btn-cfg-cancel').hidden = true;
  $('#cfg-warning').hidden    = true;
  $('#cfg-edit-hint').textContent = '';
}
$('#btn-cfg-edit').onclick   = () => cfgEnterEditMode();
$('#btn-cfg-cancel').onclick = () => { cfgExitEditMode(); };
$('#btn-cfg-save').onclick = async () => {
  const cfg = gatherCfgFromForm();
  if (!confirm('Save settings? Service.yaml + solution.yaml will each get a timestamped backup before being rewritten. In-flight syncs keep the old config; new bridge requests pick up the changes after the next module reload.')) return;
  try {
    const result = await api('config', { method: 'PUT', body: JSON.stringify({ config: cfg }) });
    const svcBak = result?.service?.backup;
    const solBak = result?.solution?.backup;
    toast(`Saved. Backups: ${svcBak || '(no prior service.yaml)'} + ${solBak || '(no prior solution.yaml)'}`, 'ok');
    await loadCfg();
  } catch (e) {
    toast(`Save failed: ${e.message}`, 'bad');
  }
};
$('#btn-cfg-yaml-toggle').onclick = () => {
  const pre = $('#cfg-yaml');
  const showing = !pre.hidden;
  pre.hidden = showing;
  $('#btn-cfg-yaml-toggle').textContent = showing ? 'Show raw YAML' : 'Hide raw YAML';
};
async function loadHealth() {
  try {
    const body = await api('health');
    state.health = body.checks || [];
    const tbody = $('#health-table tbody'); tbody.innerHTML = '';
    state.health.forEach(c => {
      const m = String(c).match(/^\[(\w+)\]\s+(\S.*?)\s{2,}(.*)$/);
      if (!m) {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td class="status-skip">?</td><td colspan=2 class="muted">${c}</td>`;
        tbody.appendChild(tr); return;
      }
      const [, st, name, detail] = m;
      const cls = ({ OK: 'status-ok', FAIL: 'status-fail', WARN: 'status-warn', SKIP: 'status-skip' })[st] || 'status-skip';
      const tr = document.createElement('tr');
      tr.innerHTML = `<td class="${cls}">${st}</td><td>${name}</td><td class="muted">${detail}</td>`;
      tbody.appendChild(tr);
    });
  } catch (e) { toast(`Load health: ${e.message}`, 'bad'); }
}
$('#btn-cfg-refresh').onclick = () => { loadCfg(); loadHealth(); loadPopularityStatus(); loadBackupStatus(); };

// Backup & DR card (Phase D.6/D.7). Renders the latest snapshot per
// repo plus the latest drill outcome, and wires the manual snapshot
// and verify-backup buttons.
async function loadBackupStatus() {
  const target = document.getElementById('backup-status');
  if (!target) return;
  try {
    const body = await api('backup/status');
    const t = body.totals || {};
    const repos = body.repos || [];
    const repoLines = repos.map(r => {
      const snap = r.last_snapshot_utc ? `last snapshot ${formatLocalTime(r.last_snapshot_utc)}` : 'no snapshots yet';
      const drill = r.last_drill_outcome
        ? `last drill <strong>${escHtml(r.last_drill_outcome)}</strong> ${r.last_drill_utc ? 'at ' + formatLocalTime(r.last_drill_utc) : ''}`
        : 'no drills yet';
      return `<li><code>${escHtml(r.repo_id)}</code> -- ${escHtml(snap)}; ${drill} (${r.snapshot_count || 0} snapshots stored)</li>`;
    }).join('');
    const bytes = Number(t.bytes_total) || 0;
    const human = bytes < 1024 ? `${bytes} B` : (bytes < 1048576 ? `${(bytes/1024).toFixed(1)} KB` : `${(bytes/1048576).toFixed(2)} MB`);
    target.innerHTML = `
      <div>Archive: ${Number(t.commits_total) || 0} commits, ${Number(t.blobs_total) || 0} blobs, ${escHtml(human)} total</div>
      <ul style="margin: 6px 0 0 0; padding-left: 18px;">${repoLines || '<li class="muted">No active repos.</li>'}</ul>`;
  } catch (e) {
    target.innerHTML = `<span class="muted">status load failed: ${e.message}</span>`;
  }
}

document.getElementById('btn-backup-snapshot')?.addEventListener('click', async () => {
  try {
    const res = await api('backup/snapshot', { method: 'POST', body: JSON.stringify({}) });
    toast(`Snapshot taken: ${res.SnapshotsTaken || 0} repo(s)`, 'ok');
    setTimeout(loadBackupStatus, 600);
  } catch (e) {
    toast(`Snapshot failed: ${e.message}`, 'bad');
  }
});

// Retention cleanup: run the prune sweep on demand and report the result.
// removed = versions unpublished this run; skipped = within retention (or held
// by a lock gate); failed = errors (see Activity tab). Refreshes the Catalog so
// the Pubs counts reflect the prune.
document.getElementById('btn-cleanup-run')?.addEventListener('click', async () => {
  const btn = document.getElementById('btn-cleanup-run');
  const status = document.getElementById('cleanup-status');
  btn.disabled = true;
  btn.textContent = 'Running cleanup...';
  if (status) status.textContent = 'Pruning versions beyond each subscription’s retention...';
  try {
    const res = await api('cleanup/run', { method: 'POST', body: JSON.stringify({}) });
    const msg = `Cleanup ${res.status || 'done'}: removed ${res.removed || 0}, within-retention ${res.skipped || 0}, failed ${res.failed || 0}.`;
    if (status) status.textContent = msg + (res.failed ? ' See the Activity tab for the failure detail.' : '');
    toast(msg, res.failed ? 'bad' : 'ok');
    setTimeout(() => { if (typeof loadCombinedView === 'function') loadCombinedView(); }, 800);
  } catch (e) {
    if (status) status.textContent = `Cleanup failed: ${e.message}`;
    toast(`Cleanup failed: ${e.message}`, 'bad');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Run retention cleanup now';
  }
});

document.getElementById('btn-backup-drill')?.addEventListener('click', async () => {
  const btn = document.getElementById('btn-backup-drill');
  btn.disabled = true;
  btn.textContent = 'Running drill...';
  try {
    const body = await api('backup/drill', { method: 'POST', body: JSON.stringify({}) });
    const results = body.results || [];
    const passed = results.filter(r => r.Outcome === 'passed').length;
    const failed = results.filter(r => r.Outcome === 'failed').length;
    const cls = failed > 0 ? 'bad' : 'ok';
    toast(`Drill: ${passed} passed, ${failed} failed`, cls);
    if (failed > 0) {
      const firstFail = results.find(r => r.Outcome === 'failed');
      if (firstFail) console.error('DR drill failure detail:', firstFail);
    }
    await loadBackupStatus();
  } catch (e) {
    toast(`Drill failed: ${e.message}`, 'bad');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Verify backup (DR drill)';
  }
});

// Settings > Search popularity card. Renders the latest popularity_run
// summary plus aggregate fresh / not-in-source / error counts, and
// wires the manual "Refresh now" button.
async function loadPopularityStatus() {
  const target = $('#popularity-status');
  if (!target) return;
  try {
    const body = await api('popularity/status');
    if (body.disabled) {
      target.innerHTML = '<span class="muted">Disabled by configuration (<code>popularity.disabled: true</code>).</span>';
      const btn = $('#btn-popularity-refresh'); if (btn) btn.disabled = true;
      return;
    }
    const c = body.counts || {};
    const r = body.latest_run || null;
    const runLine = r
      ? `Last run: <strong>${r.status}</strong> (${r.tier}) at ${r.ended_utc || r.started_utc || 'pending'} -- fetched=${r.packages_fetched ?? 0}, not-in-source=${r.packages_skipped ?? 0}, failed=${r.packages_failed ?? 0}, total=${r.packages_total ?? 0}`
      : 'No popularity refresh has run yet.';
    const aggLine = `Index: ${c.fresh ?? 0} fresh, ${c.not_in_source ?? 0} not-in-source, ${c.rate_limited ?? 0} rate-limited, ${c.error_rows ?? 0} errored, ${c.total ?? 0} total rows`;
    target.innerHTML = `<div>${runLine}</div><div class="muted">${aggLine}</div>`;
    const btn = $('#btn-popularity-refresh'); if (btn) btn.disabled = false;
  } catch (e) {
    target.innerHTML = `<span class="muted">status load failed: ${e.message}</span>`;
  }
}

$('#btn-popularity-refresh')?.addEventListener('click', async () => {
  try {
    await api('popularity/refresh', { method: 'POST' });
    toast('Popularity refresh queued (tier 1, ~17 minutes)', 'ok');
    setTimeout(loadPopularityStatus, 2000);
  } catch (e) {
    toast(`Refresh failed: ${e.message}`, 'bad');
  }
});

// ============================================================================
// Catalog sidebar + repo-scoped views (Phase C.f UX refactor)
//
// The Subscriptions tab is now a 2-pane layout: a sidebar listing every
// active virtual repo (with package counts and live container badges),
// and a main pane that filters subscriptions / customs / untracked by
// the selected repo. Non-main repos also surface a "Promoted into this
// repo" section sourced from promotion_events. The standalone Virtual
// repos tab is gone; its CRUD (add / edit / archive / reconcile) is
// reachable from the sidebar header and the main pane action row.
// ============================================================================
state.virtualRepos  = [];
state.selectedRepoId = 'main';
state.promotedIn    = [];

// Top-level loader for the catalog. Fetches the repo list first so the
// sidebar can render immediately, then dispatches the package-data load
// for the currently selected repo. Container badges fill in async.
async function loadCatalog() {
  try {
    const resp = await api('virtual-repos');
    state.virtualRepos = (resp.virtualRepos || []);
  } catch (e) {
    toast(`Load virtual repos: ${e.message}`, 'bad');
  }
  // If the selected repo got archived elsewhere (or never existed),
  // fall back to main so the main pane is never blank.
  if (!state.virtualRepos.some(r => r.RepoId === state.selectedRepoId && r.Status !== 'archived')) {
    state.selectedRepoId = 'main';
  }
  renderCatalogSidebar();
  refreshSidebarContainers().catch(() => {});
  await loadCombinedView();
  await loadPromotedInForCurrentRepo();
  loadDriftBanner().catch(() => {});
  // Re-render sidebar so the package counts reflect freshly loaded data.
  renderCatalogSidebar();
  updateRepoHeader();
}

// Drift detection (Phase D.5) banner above the catalog. Lists pending
// drift events across all repos so operators see uninvited Gitea
// commits quickly. Acknowledge button marks an event as resolved
// without modifying Gitea. Best-effort; never blocks the catalog load.
async function loadDriftBanner() {
  const banner = document.getElementById('drift-banner');
  if (!banner) return;
  let body;
  try {
    body = await api('drift');
  } catch {
    banner.hidden = true;
    return;
  }
  const count = Number(body.pending_count) || 0;
  if (count === 0) {
    banner.hidden = true;
    banner.innerHTML = '';
    return;
  }
  const events = (body.events || []).filter(e => e.resolution === 'pending').slice(0, 10);
  const rows = events.map(e => {
    const shortSha = String(e.gitea_commit_sha || '').slice(0, 8);
    const firstLine = String(e.gitea_commit_message || '').split('\n')[0];
    const author = String(e.gitea_commit_author || 'unknown');
    return `<li>
      <code>${escHtml(e.repo_id)}</code>
      <code>${escHtml(shortSha)}</code>
      by ${escHtml(author)}:
      ${escHtml(firstLine || '(no message)')}
      <button type="button" class="ghost drift-ack" data-drift-ack="${escAttr(e.drift_event_id)}">Acknowledge</button>
    </li>`;
  }).join('');
  const tooMany = count > events.length ? ` (showing ${events.length} of ${count})` : '';
  banner.innerHTML = `
    <div class="drift-head">
      <span class="drift-title">Drift detected (${count} pending)${tooMany}</span>
      <span>
        <span class="muted">External commits on Gitea that did not come from RepoFabric's publisher</span>
        <button type="button" id="btn-drift-ack-all" class="ghost u-spacer-left">Acknowledge all ${count}</button>
      </span>
    </div>
    <ul>${rows}</ul>`;
  banner.hidden = false;
}

document.addEventListener('click', async (ev) => {
  if (ev.target && ev.target.id === 'btn-drift-ack-all') {
    const btn = ev.target;
    if (!confirm(`Acknowledge all pending drift events? This clears the banner but keeps the history queryable.`)) return;
    btn.disabled = true;
    try {
      const res = await api('drift/acknowledge-all', { method: 'POST' });
      toast(`Acknowledged ${res.acknowledged || 0} drift events`, 'ok');
      await loadDriftBanner();
    } catch (e) {
      btn.disabled = false;
      toast(`Bulk acknowledge failed: ${e.message}`, 'bad');
    }
  }
});

document.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('[data-drift-ack]');
  if (!btn) return;
  const id = btn.dataset.driftAck;
  if (!id) return;
  btn.disabled = true;
  try {
    await api(`drift/${id}/acknowledge`, { method: 'POST', body: JSON.stringify({ Notes: '' }) });
    toast('Drift event acknowledged', 'ok');
    await loadDriftBanner();
  } catch (e) {
    btn.disabled = false;
    toast(`Acknowledge failed: ${e.message}`, 'bad');
  }
});

// Filters applied to existing state arrays so renderSubs / renderCustom /
// renderUntracked don't need to know about the repo selection. They keep
// iterating state.subs / state.customPkgs etc.; we just narrow those at
// load time by re-reading the API responses through these helpers.
function subsForCurrentRepo(allSubs) {
  return (allSubs || []).filter(s => (s.RepoId || 'main') === state.selectedRepoId);
}
function customsForCurrentRepo(allCustoms) {
  return (allCustoms || []).filter(c => (c.repo_id || c.RepoId || 'main') === state.selectedRepoId);
}
function untrackedForCurrentRepo(allUntracked) {
  // Untracked rows come from repo_catalog which has repo_id; default to
  // 'main' for legacy rows that pre-date the column.
  return (allUntracked || []).filter(u => (u.repo_id || u.RepoId || 'main') === state.selectedRepoId);
}

async function loadPromotedInForCurrentRepo() {
  const section = $('#catalog-promoted-in');
  const tbody = $('#promoted-in-table tbody');
  if (!section || !tbody) return;
  // 'main' is always a source, never a promotion target in practice.
  // Hide the section entirely there to keep the main pane uncluttered.
  if (state.selectedRepoId === 'main') {
    section.hidden = true;
    state.promotedIn = [];
    return;
  }
  try {
    const resp = await api('promotions');
    const all = (resp.promotions || []);
    state.promotedIn = all.filter(p => p.target_repo_id === state.selectedRepoId);
    renderPromotedIn();
    section.hidden = false;
  } catch (e) {
    section.hidden = true;
    console.warn(`Load promotions for ${state.selectedRepoId}:`, e.message);
  }
}

function renderPromotedIn() {
  const tbody = $('#promoted-in-table tbody');
  if (!tbody) return;
  tbody.innerHTML = '';
  if (!state.promotedIn.length) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">Nothing promoted into this repo yet. Select a subscription in <code>main</code> and use "Promote selected" to copy a published package here.</td></tr>';
    return;
  }
  for (const p of state.promotedIn) {
    const tr = document.createElement('tr');
    let cls = 'badge';
    if (p.status === 'succeeded')        cls += ' on';
    else if (p.status === 'failed')      cls += ' off';
    else if (p.status === 'in_progress') cls += ' archive';
    const commit = p.target_gitea_commit_sha ? String(p.target_gitea_commit_sha).substring(0, 8) : '';
    const notesText = p.failure_message || p.notes || '';
    tr.innerHTML = `
      <td>${p.promotion_id}</td>
      <td>${escapeHtml((p.initiated_at || '').replace('T', ' ').replace('Z', ''))}</td>
      <td>${escapeHtml(p.initiated_by || '')}</td>
      <td><code>${escapeHtml(p.source_repo_id || '')}</code></td>
      <td><code>${escapeHtml(p.package_id || '')}</code></td>
      <td><code>${escapeHtml(p.package_version || '')}</code></td>
      <td><span class="${cls}" title="${escapeHtml(notesText)}">${escapeHtml(p.status || '')}</span></td>
      <td><code>${escapeHtml(commit)}</code></td>
      <td title="${escapeHtml(notesText)}">${escapeHtml(notesText.length > 60 ? notesText.substring(0, 60) + '...' : notesText)}</td>
    `;
    tbody.appendChild(tr);
  }
}

function renderCatalogSidebar() {
  const list = $('#catalog-side-list');
  if (!list) return;
  list.innerHTML = '';
  if (!state.virtualRepos.length) {
    list.innerHTML = '<li class="catalog-side-item is-archived"><span class="name">(no repos)</span></li>';
    return;
  }
  // Count packages per repo from the current state (best-effort; counts
  // refresh when the package data reloads). Includes managed + custom.
  const countByRepo = {};
  (state.subs || []).forEach(s => {
    const rid = s.RepoId || 'main';
    countByRepo[rid] = (countByRepo[rid] || 0) + 1;
  });
  (state.customPkgs || []).forEach(c => {
    const rid = c.repo_id || c.RepoId || 'main';
    countByRepo[rid] = (countByRepo[rid] || 0) + 1;
  });
  // Untracked apps (including content promoted into a non-main repo) come from
  // repo_catalog, which is repo_id-scoped, so count them per repo to match the
  // apps actually listed for that repo. This replaces the old promoted-in count
  // hack, which only applied to the active repo and double-counted once the
  // promoted package appeared in repo_catalog (RepoFabric).
  (state.untrackedPkgs || []).forEach(u => {
    const rid = u.repo_id || u.RepoId || 'main';
    countByRepo[rid] = (countByRepo[rid] || 0) + 1;
  });
  for (const r of state.virtualRepos) {
    const li = document.createElement('li');
    li.className = 'catalog-side-item';
    li.dataset.repoId = r.RepoId;
    if (r.Status === 'archived') li.classList.add('is-archived');
    if (r.RepoId === state.selectedRepoId) li.classList.add('is-active');
    const count = countByRepo[r.RepoId] || 0;
    li.innerHTML = `
      <span class="name">${escapeHtml(r.RepoId)}</span>
      <span class="count" title="Packages in this repo">${count}</span>
    `;
    li.onclick = () => {
      if (state.selectedRepoId === r.RepoId) return;
      state.selectedRepoId = r.RepoId;
      // Clear any subscription detail drawer state from the prior repo,
      // otherwise the drawer keeps showing the stale row's manifest +
      // source card under the new repo's header (operator confusion).
      state.selectedSubId = null;
      const drawer  = $('#sub-detail');
      const summary = $('#sub-detail-summary');
      const body    = $('#sub-detail-body');
      if (drawer)  drawer.open = false;
      if (summary) summary.textContent = 'Detail';
      if (body)    body.innerHTML = '';
      // Disable the row-scoped action buttons; they re-enable when the
      // operator clicks a row in the new repo.
      updateSubButtons();
      renderCatalogSidebar();
      updateRepoHeader();
      // Re-render existing arrays scoped to the new repo; no refetch
      // needed because state.subs / state.customPkgs are already loaded.
      renderSubs();
      renderCustomPackages();
      renderUntracked();
      loadPromotedInForCurrentRepo();
    };
    list.appendChild(li);
  }
}

function updateRepoHeader() {
  const repo = state.virtualRepos.find(r => r.RepoId === state.selectedRepoId);
  if (!repo) return;
  $('#catalog-repo-title').textContent = repo.RepoId;
  const bits = [];
  if (repo.DisplayName && repo.DisplayName !== repo.RepoId) bits.push(repo.DisplayName);
  if (repo.Hostname) bits.push(repo.Hostname);
  if (repo.GiteaRepoPath) bits.push(repo.GiteaRepoPath);
  $('#catalog-repo-subtitle').textContent = bits.join(' · ');
  // 'main' is non-archivable, but it IS editable: it must be able to receive a
  // Hostname, and the Edit handler + PUT /virtual-repos/:id already support it
  // (the slug/rename is fixed because the PUT drops RepoId). Enable Edit for any
  // active repo; only Archive stays restricted for 'main' (and archived repos).
  const editable   = repo.Status !== 'archived';
  const archivable = repo.RepoId !== 'main' && repo.Status !== 'archived';
  $('#btn-vrepo-edit').disabled    = !editable;
  $('#btn-vrepo-archive').disabled = !archivable;
}

async function refreshSidebarContainers() {
  await Promise.all(state.virtualRepos.map(async (r) => {
    try {
      const c = await api(`virtual-repos/${r.RepoId}/container`);
      paintSidebarContainer(r.RepoId, c);
    } catch {
      paintSidebarContainer(r.RepoId, { accessible: false, state: 'unknown', message: 'lookup failed' });
    }
  }));
}

function paintSidebarContainer(repoId, c) {
  // Show a tiny color dot next to the count: green=running, yellow=absent,
  // red=exited/dead/unknown, no dot=unknown. Tooltip carries the detail.
  const li = document.querySelector(`#catalog-side-list li[data-repo-id="${repoId}"]`);
  if (!li) return;
  const name = li.querySelector('.name');
  if (!name) return;
  // Strip any prior dot before appending the new one.
  const old = li.querySelector('.catalog-side-dot');
  if (old) old.remove();
  let color = 'var(--fg-dim)';
  if (!c.accessible) color = 'var(--bad)';
  else if (c.state === 'running') color = 'var(--ok)';
  else if (c.state === 'absent')  color = 'var(--warn)';
  else if (c.state === 'exited' || c.state === 'dead' || c.state === 'restarting') color = 'var(--bad)';
  const dot = document.createElement('span');
  dot.className = 'catalog-side-dot';
  dot.style.cssText = `display:inline-block;width:6px;height:6px;border-radius:50%;background:${color};margin-right:6px;`;
  const tooltip = (c.message || `${c.state || ''} since ${c.startedAt || '?'}`);
  li.title = tooltip;
  name.prepend(dot);
}

function openVrepoModal(existing) {
  const title = existing ? `Edit virtual repo: ${existing.RepoId}` : 'New virtual repo';
  $('#vrepo-modal-title').textContent = title;
  $('#vrepo-slug').value = existing?.RepoId || '';
  $('#vrepo-slug').disabled = !!existing;
  $('#vrepo-display-name').value = existing?.DisplayName || '';
  $('#vrepo-description').value = existing?.Description || '';
  $('#vrepo-base-domain').value = existing?.BaseDomain || '';
  $('#vrepo-hostname').value = existing?.Hostname || '';
  $('#vrepo-binary-mode').value = existing?.DefaultBinaryMode || 'local';
  $('#vrepo-modal').showModal();
}

// Sandbox multi-repo nudge: when the Docker socket is absent the add/reconcile
// buttons stay visible but open this friendly popup (rather than the
// non-functional multi-repo flow) to point the operator at the full deployment.
function showMultiRepoUpgrade() {
  const dlg = document.getElementById('multirepo-upgrade-modal');
  if (dlg && typeof dlg.showModal === 'function') dlg.showModal();
}
const _multiRepoUpgradeClose = document.getElementById('multirepo-upgrade-close');
if (_multiRepoUpgradeClose) _multiRepoUpgradeClose.onclick = () => document.getElementById('multirepo-upgrade-modal').close();

// Header "Sandbox vs Recommended" compare button + modal (the button is revealed
// for sandbox deployments by the boot features probe below).
const _cmpBtn = document.getElementById('btn-compare-deployments');
const _cmpClose = document.getElementById('compare-close');
if (_cmpBtn) _cmpBtn.onclick = () => { const d = document.getElementById('compare-modal'); if (d && d.showModal) d.showModal(); };
if (_cmpClose) _cmpClose.onclick = () => { const d = document.getElementById('compare-modal'); if (d) d.close(); };
// "Upgrade to Recommended →" CTA: close the compare popup and jump to the Settings
// tab's upgrade panel where the readiness check + conversion live.
const _cmpUpgrade = document.getElementById('compare-upgrade');
if (_cmpUpgrade) _cmpUpgrade.onclick = () => {
  const d = document.getElementById('compare-modal'); if (d) d.close();
  activateTab('settings');
  const u = document.getElementById('upgrade-card'); if (u && u.scrollIntoView) u.scrollIntoView({ behavior: 'smooth' });
};

$('#btn-vrepo-add').onclick = () => {
  if (state.multiRepoLocked) return showMultiRepoUpgrade();
  openVrepoModal(null);
};
$('#btn-vrepo-edit').onclick = () => {
  // 'main' is editable too (it must be able to receive a Hostname); only
  // archive/rename stay restricted for it.
  const existing = state.virtualRepos.find(r => r.RepoId === state.selectedRepoId);
  if (existing) openVrepoModal(existing);
};
$('#vrepo-cancel').onclick = () => $('#vrepo-modal').close();
$('#vrepo-form').onsubmit = async (e) => {
  e.preventDefault();
  const slug = $('#vrepo-slug').value.trim();
  if (!slug) { toast('Repo ID required', 'bad'); return; }
  // Hostname is optional: blank = served at the /<repoId>/api/ subdirectory on
  // the shared public host; set it only for a dedicated FQDN.
  const body = {
    RepoId: slug,
    DisplayName:        $('#vrepo-display-name').value.trim() || undefined,
    Description:        $('#vrepo-description').value.trim() || undefined,
    BaseDomain:         $('#vrepo-base-domain').value.trim() || undefined,
    Hostname:           $('#vrepo-hostname').value.trim() || undefined,
    DefaultBinaryMode:  $('#vrepo-binary-mode').value,
  };
  const existing = state.virtualRepos.find(r => r.RepoId === slug);
  try {
    if (existing) {
      delete body.RepoId;
      await api(`virtual-repos/${slug}`, { method: 'PUT', body: JSON.stringify(body) });
      toast(`Updated ${slug}`, 'ok');
    } else {
      await api('virtual-repos', { method: 'POST', body: JSON.stringify(body) });
      toast(`Created ${slug}`, 'ok');
      state.selectedRepoId = slug;
    }
    $('#vrepo-modal').close();
    await loadCatalog();
  } catch (err) {
    toast(`Save failed: ${err.message}`, 'bad');
  }
};
$('#btn-vrepo-archive').onclick = async () => {
  const slug = state.selectedRepoId;
  if (!slug || slug === 'main') return;
  if (!confirm(`Archive virtual repo "${slug}"? This stops its Rewinged container and hides it from default views, but all data is preserved. Use --Purge via CLI for permanent deletion.`)) return;
  try {
    await api(`virtual-repos/${slug}`, { method: 'DELETE' });
    toast(`Archived ${slug}`, 'ok');
    state.selectedRepoId = 'main';
    await loadCatalog();
  } catch (e) {
    toast(`Archive failed: ${e.message}`, 'bad');
  }
};

// Reconcile is global, not per-repo. Lives in the sidebar footer.
$('#btn-vrepo-reconcile').onclick = async () => {
  if (state.multiRepoLocked) return showMultiRepoUpgrade();
  const btn = $('#btn-vrepo-reconcile');
  btn.disabled = true;
  const prevLabel = btn.textContent;
  btn.textContent = 'Reconciling...';
  try {
    const r = await api('virtual-repos/reconcile', { method: 'POST' });
    if (!r.DockerAccessible) {
      toast(`Docker not reachable: ${r.Message}`, 'bad');
    } else {
      toast(`Reconcile: spawned ${r.Spawned}, removed ${r.Removed}, ok ${r.AlreadyOk}, failed ${r.Failed}`,
            r.Failed ? 'bad' : 'ok');
      if (r.Failed && Array.isArray(r.Details)) {
        for (const d of r.Details) {
          if (!d.Ok) console.warn(`reconcile ${d.RepoId} (${d.Action}):`, d.Message);
        }
      }
    }
    await loadCatalog();
  } catch (e) {
    toast(`Reconcile failed: ${e.message}`, 'bad');
  } finally {
    btn.disabled = false;
    btn.textContent = prevLabel;
  }
};

// ============================================================================
// Promotion (Phase C.f) -- triggered from the Subscriptions toolbar's
// "Promote selected" button. Source repo + package id come from the
// selected subscription row. Operator picks the target repo and version.
// History surfaces in the Activity tab via 'package_promoted' admin_events.
// ============================================================================

async function openPromoModalForSubscription(sub, preselectTargetRepoId) {
  if (!sub) return;
  // Refresh the virtual_repos list so newly-created repos show up.
  try {
    const repos = await api('virtual-repos');
    state.virtualRepos = (repos.virtualRepos || []);
  } catch { /* non-fatal; selector will just be sparse */ }

  const srcRepoId = sub.RepoId || 'main';
  $('#promo-source').value = srcRepoId;
  $('#promo-source-label').textContent = srcRepoId;
  $('#promo-package-id').value = sub.PackageId;
  $('#promo-notes').value = '';

  // Target dropdown: every active virtual repo except the source.
  const tgtSel = $('#promo-target');
  tgtSel.innerHTML = '';
  const candidates = (state.virtualRepos || []).filter(r =>
    r.RepoId !== srcRepoId && r.Status !== 'archived'
  );
  if (!candidates.length) {
    tgtSel.innerHTML = '<option value="">(no other virtual repos available; create one in Virtual repos tab)</option>';
  } else {
    for (const r of candidates) {
      const o = document.createElement('option');
      o.value = r.RepoId;
      o.textContent = `${r.RepoId} (${r.DisplayName || ''})`;
      tgtSel.appendChild(o);
    }
    // Preselect a requested target (e.g. the Inventory repo the operator is
    // viewing when promoting from there) so the common case is one click.
    if (preselectTargetRepoId && candidates.some(r => r.RepoId === preselectTargetRepoId)) {
      tgtSel.value = preselectTargetRepoId;
    }
  }

  // Versions checkbox group: enumerate every successful publication of
  // this subscription in the SOURCE repo. Operator picks one or many.
  // Default-check the most-recently-published version so the common
  // case (promote latest) is a single click.
  buildPromoVersionList(sub);

  $('#promo-modal').showModal();
}

function buildPromoVersionList(sub) {
  const container = $('#promo-versions-list');
  const hint = $('#promo-versions-hint');
  if (!container) return;
  container.innerHTML = '';
  const pubs = (state.pubs || []).filter(p => p.subscription_id === sub.SubscriptionId);
  if (!pubs.length) {
    container.innerHTML = '<span class="promo-versions-empty">no published versions for this subscription; sync it first</span>';
    if (hint) hint.textContent = '';
    return;
  }
  // Sort by publication_id descending so the most recent comes first
  // and gets pre-checked. publication_id is monotonic so this is a
  // proxy for chronological ordering, immune to clock skew.
  const sorted = [...pubs].sort((a, b) => (Number(b.publication_id) || 0) - (Number(a.publication_id) || 0));
  const latestPid = Number(sorted[0].publication_id) || 0;
  for (const p of sorted) {
    const label = document.createElement('label');
    label.className = 'promo-version';
    const isLatest = Number(p.publication_id) === latestPid;
    if (isLatest) label.classList.add('is-checked');
    label.innerHTML = `
      <input type="checkbox" name="PromoVersion" value="${escapeHtml(String(p.version))}" ${isLatest ? 'checked' : ''}>
      <span>${escapeHtml(String(p.version))}</span>
    `;
    label.querySelector('input').addEventListener('change', (e) => {
      label.classList.toggle('is-checked', e.target.checked);
    });
    container.appendChild(label);
  }
  if (hint) {
    hint.textContent = pubs.length === 1
      ? '(1 published version available)'
      : `(${pubs.length} published; latest pre-selected)`;
  }
}

$('#btn-sub-promote').onclick = () => {
  const sub = state.subs.find(s => s.SubscriptionId === state.selectedSubId);
  if (sub) openPromoModalForSubscription(sub);
};
$('#promo-cancel').onclick = () => $('#promo-modal').close();
$('#promo-form').onsubmit = async (e) => {
  e.preventDefault();
  const sourceRepoId = $('#promo-source').value;
  const targetRepoId = $('#promo-target').value;
  const packageId    = $('#promo-package-id').value.trim();
  const notes        = $('#promo-notes').value.trim() || undefined;

  if (!targetRepoId) {
    toast('Target repo required', 'bad'); return;
  }
  if (sourceRepoId === targetRepoId) {
    toast('Source and target must differ', 'bad'); return;
  }
  const versions = Array.from(document.querySelectorAll('#promo-versions-list input[type=checkbox]:checked'))
                        .map(c => c.value);
  if (!versions.length) {
    toast('Pick at least one version to promote', 'bad'); return;
  }

  const btn = $('#promo-save');
  btn.disabled = true;
  const prevLabel = btn.textContent;
  btn.textContent = versions.length === 1 ? 'Promoting...' : `Promoting ${versions.length}...`;

  let ok = 0;
  const failures = [];
  // Promotions run sequentially so a downstream Gitea rate limit or a
  // first-version Gitea-repo-creation step finishes before the next push
  // begins. Parallel would shave seconds but multiply failure modes;
  // promotions are not in any UI hot path.
  for (const v of versions) {
    try {
      await api('promotions', {
        method: 'POST',
        body: JSON.stringify({
          SourceRepoId:   sourceRepoId,
          TargetRepoId:   targetRepoId,
          PackageId:      packageId,
          PackageVersion: v,
          Notes:          notes,
        }),
      });
      ok++;
    } catch (err) {
      failures.push({ version: v, message: err.message });
      console.warn(`promote ${packageId} ${v} -> ${targetRepoId} failed:`, err.message);
    }
  }

  if (!failures.length) {
    toast(`Promoted ${ok}/${versions.length} version${versions.length === 1 ? '' : 's'} of ${packageId} to ${targetRepoId}`, 'ok');
    $('#promo-modal').close();
  } else {
    const firstFailure = failures[0];
    toast(`Promoted ${ok}/${versions.length}; first failure: ${firstFailure.version} -- ${firstFailure.message}`, 'bad');
  }

  btn.disabled = false;
  btn.textContent = prevLabel;
};

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// --- bandwidth dashboard (0.8.0) ---
//
// Reads /admin/api/bandwidth/* which is served direct from metrics.db
// (no pwsh bridge). Four panels: headline tiles, daily time-series bar
// chart, per-subnet effectiveness table, top-installer table. The
// window selector at the top of the tab toggles between 7/30/90 days
// and is shared across all four panels.

let bwWindowDays = 30;

function formatBytes(n) {
  if (!n || n < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = Number(n);
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)} ${units[i]}`;
}

function formatPercent(ratio) {
  if (!isFinite(ratio)) return '--';
  return `${(ratio * 100).toFixed(ratio >= 0.999 ? 0 : 1)}%`;
}

async function loadBandwidth() {
  try {
    const [summary, series, subnets, installers] = await Promise.all([
      api(`bandwidth/summary?days=${bwWindowDays}`),
      api(`bandwidth/timeseries?days=${bwWindowDays}`),
      api(`bandwidth/subnets?days=${bwWindowDays}`),
      api(`bandwidth/installers?days=${bwWindowDays}&limit=20`),
    ]);
    renderBandwidthHeadline(summary, subnets, installers);
    renderBandwidthChart(series);
    renderBandwidthSubnets(subnets);
    renderBandwidthInstallers(installers);
  } catch (e) {
    toast(`Bandwidth dashboard failed: ${e.message}`, 'err');
  }
}

function renderBandwidthHeadline(summary, subnets, installers) {
  $('#bw-tile-saved').textContent = formatBytes(summary.bytesSaved);
  $('#bw-tile-savings-ratio').textContent = `${formatPercent(summary.savingsRatio)} saved`;
  $('#bw-tile-requests').textContent = (summary.requests || 0).toLocaleString();
  $('#bw-tile-peerdist-ratio').textContent = `${formatPercent(summary.peerdistRatio)} peer-accelerated`;

  const topSubnet = subnets[0];
  if (topSubnet) {
    $('#bw-tile-top-subnet').textContent = topSubnet.client_subnet;
    $('#bw-tile-top-subnet-saved').textContent = `${formatBytes(topSubnet.bytes_saved)} saved`;
  } else {
    $('#bw-tile-top-subnet').textContent = '--';
    $('#bw-tile-top-subnet-saved').textContent = 'no peer savings yet';
  }

  const topInstaller = installers[0];
  if (topInstaller) {
    const shortPath = topInstaller.installer_path.split('/').filter(Boolean).pop() || topInstaller.installer_path;
    $('#bw-tile-top-installer').textContent = shortPath;
    $('#bw-tile-top-installer-saved').textContent = `${formatBytes(topInstaller.bytes_saved)} saved`;
  } else {
    $('#bw-tile-top-installer').textContent = '--';
    $('#bw-tile-top-installer-saved').textContent = 'no peer savings yet';
  }
}

// Bandwidth savings bar chart, one bar per day. Calm and dark-theme native:
// server egress is a recessive slate (it is normal, expected traffic, never
// an alarm), and the bytes LAN peers served, the hero metric, sit on top in
// the brand green with a soft gradient. Nice-rounded byte ticks keep the axis
// readable, a 1px seam between the two segments is a colour-independent cue
// for red-green colourblind viewers, a flat cap keeps quiet days from looking
// broken, and an aria summary reports the window totals to screen readers.
// Scales from a single MSI up to multi-GB days. Keeps the existing data
// contract { day, naive_bytes, actual_bytes, bytes_saved } and formatBytes().
function renderBandwidthChart(series) {
  const container = $('#bw-chart');
  if (!series || series.length === 0) {
    container.innerHTML = '<div class="bw-chart-empty">No installs in this window.</div>';
    return;
  }

  const w = 800, h = 220, padL = 64, padR = 16, padT = 14, padB = 30;
  const innerW = w - padL - padR;
  const innerH = h - padT - padB;

  // Round the axis top up to a clean 1/2/5/8 x 1024^n so tick labels read as
  // round byte values instead of an arbitrary max/2 fraction.
  function niceCeil(v) {
    if (v <= 0) return 1;
    const exp = Math.floor(Math.log(v) / Math.log(1024));
    const base = Math.pow(1024, exp);
    const frac = v / base;
    const step = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 8;
    return step * base;
  }
  const rawMax = Math.max(...series.map(d => d.naive_bytes || 0));
  const maxNaive = niceCeil(rawMax) || 1;

  const n = series.length;
  const slot = innerW / Math.max(1, n);
  const gap = Math.min(8, Math.max(1, slot * 0.28));
  const barW = Math.max(2, slot - gap);
  const radius = Math.min(3, barW / 2);
  const yAt = v => padT + innerH - (innerH * v / maxNaive);

  // Soft vertical gradient on the savings (green) segment only; egress stays
  // flat so it recedes. Literal hex stops, not var(), to avoid the one SVG
  // engine quirk with custom properties inside stop-color.
  const defs = '<defs><linearGradient id="bwGradSaved" x1="0" y1="0" x2="0" y2="1">'
    + '<stop offset="0" stop-color="#5fd49a"/><stop offset="1" stop-color="#3fbf81"/>'
    + '</linearGradient></defs>';

  // Gridlines + axis labels at 0/.25/.5/.75/1 of the nice max.
  const yLines = [0, 0.25, 0.5, 0.75, 1].map(f => {
    const v = maxNaive * f;
    const y = yAt(v);
    const cls = f === 0 ? 'bw-chart-baseline' : 'bw-chart-grid';
    return `<line x1="${padL}" y1="${y}" x2="${w - padR}" y2="${y}" class="${cls}"/>`
      + `<text x="${padL - 8}" y="${y + 3.5}" class="bw-chart-axis" text-anchor="end">${formatBytes(v)}</text>`;
  }).join('');

  // Path that rounds only the two top corners of a bar segment.
  function topRoundedRect(x, y, bw, bh, r) {
    if (bh <= 0) return '';
    const rr = Math.min(r, bh, bw / 2);
    return `M${x},${y + bh} L${x},${y + rr} Q${x},${y} ${x + rr},${y}`
      + ` L${x + bw - rr},${y} Q${x + bw},${y} ${x + bw},${y + rr}`
      + ` L${x + bw},${y + bh} Z`;
  }

  let totActual = 0, totSaved = 0;
  const bars = series.map((d, i) => {
    const x = padL + i * slot + (slot - barW) / 2;
    const actual = Math.max(0, d.actual_bytes || 0);
    const saved = Math.max(0, d.bytes_saved || 0);
    const naive = (d.naive_bytes != null) ? d.naive_bytes : (actual + saved);
    const total = Math.max(naive, actual + saved);
    totActual += actual; totSaved += saved;

    const actualH = innerH * Math.min(actual, maxNaive) / maxNaive;
    const savedH = innerH * Math.min(saved, Math.max(0, maxNaive - actual)) / maxNaive;
    const yEgressTop = yAt(actual);
    const ySavedTop = yEgressTop - savedH;

    // Egress is flat-topped when savings sit on it, rounded when it is the cap.
    const egress = actualH > 0
      ? (savedH > 0
          ? `<rect x="${x.toFixed(1)}" y="${yEgressTop.toFixed(1)}" width="${barW.toFixed(1)}" height="${actualH.toFixed(1)}" class="bw-chart-egress"/>`
          : `<path d="${topRoundedRect(x, yEgressTop, barW, actualH, radius)}" class="bw-chart-egress"/>`)
      : '';
    const savedSeg = savedH > 0
      ? `<path d="${topRoundedRect(x, ySavedTop, barW, savedH, radius)}" class="bw-chart-saved"/>`
      : '';
    // 1px seam in the panel colour: a colour-independent cue that the bar has
    // both a sent and a saved part, for red-green colourblind viewers.
    const seam = (savedH > 0 && actualH > 0)
      ? `<line x1="${x.toFixed(1)}" y1="${yEgressTop.toFixed(1)}" x2="${(x + barW).toFixed(1)}" y2="${yEgressTop.toFixed(1)}" class="bw-chart-seam"/>`
      : '';
    // Days with no bytes still get a flat cap so the row never looks broken.
    const cap = (actualH + savedH) < 1
      ? `<line x1="${x.toFixed(1)}" y1="${(padT + innerH).toFixed(1)}" x2="${(x + barW).toFixed(1)}" y2="${(padT + innerH).toFixed(1)}" class="bw-chart-cap"/>`
      : '';

    const pct = total > 0 ? Math.round(100 * saved / total) : 0;
    const tip = `${d.day}\nSaved by peers: ${formatBytes(saved)} (${pct}%)\nSent by server: ${formatBytes(actual)}\nTotal demand: ${formatBytes(total)}`;

    return `<g class="bw-chart-bar"><title>${escapeHtml(tip)}</title>`
      + `<rect x="${x.toFixed(1)}" y="${padT}" width="${barW.toFixed(1)}" height="${innerH}" class="bw-chart-hit"/>`
      + egress + savedSeg + seam + cap + `</g>`;
  }).join('');

  // First / mid / last day labels so a 30-bar window has a middle anchor.
  const idxs = n <= 2 ? [0, n - 1] : [0, Math.floor((n - 1) / 2), n - 1];
  const xLabels = [...new Set(idxs)].map(i => {
    const anchor = i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle';
    const ax = i === 0 ? padL : i === n - 1 ? (w - padR) : (padL + i * slot + slot / 2);
    return `<text x="${ax.toFixed(1)}" y="${h - 8}" class="bw-chart-xaxis" text-anchor="${anchor}">${escapeHtml(series[i].day)}</text>`;
  }).join('');

  const totPct = (totActual + totSaved) > 0 ? Math.round(100 * totSaved / (totActual + totSaved)) : 0;
  const aria = `Bytes per day, ${series[0].day} to ${series[n - 1].day}. `
    + `LAN peers served ${formatBytes(totSaved)} (${totPct}% of demand); this server sent ${formatBytes(totActual)}.`;

  container.innerHTML = `<svg viewBox="0 0 ${w} ${h}" class="bw-chart-svg" role="img" aria-label="${escapeHtml(aria)}">`
    + `<desc>${escapeHtml(aria)}</desc>${defs}${yLines}${bars}${xLabels}</svg>`;
}

function renderBandwidthSubnets(rows) {
  const tbody = $('#bw-subnets-table tbody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="muted">No peerdist-negotiated requests in this window.</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(r => `
    <tr>
      <td>${escapeHtml(r.client_subnet)}</td>
      <td>${r.requests.toLocaleString()}</td>
      <td>${formatBytes(r.naive_bytes)}</td>
      <td>${formatBytes(r.actual_bytes)}</td>
      <td>${formatBytes(r.bytes_saved)}</td>
      <td>${formatPercent(r.savings_ratio)}</td>
    </tr>`).join('');
}

function renderBandwidthInstallers(rows) {
  const tbody = $('#bw-installers-table tbody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">No installer requests in this window.</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(r => `
    <tr>
      <td>${escapeHtml(r.installer_path)}</td>
      <td>${r.requests.toLocaleString()}</td>
      <td>${formatBytes(r.avg_installer_size)}</td>
      <td>${formatBytes(r.bytes_saved)}</td>
    </tr>`).join('');
}

// Hook the window selector and refresh button. Wired here rather than
// inside loadBandwidth() so the listeners are attached only once.
$$('button[data-bw-window]').forEach(btn => {
  btn.addEventListener('click', () => {
    bwWindowDays = parseInt(btn.dataset.bwWindow, 10) || 30;
    $$('button[data-bw-window]').forEach(b => b.classList.toggle('active', b === btn));
    loadBandwidth();
  });
});
$('#btn-bw-refresh')?.addEventListener('click', loadBandwidth);

// --- ConfigFabric absorption tab (flag-gated, injected at runtime) ---------
// When the server reports configfabric.enabled, inject a ConfigFabric tab that
// hosts the absorbed CF admin SPA (served same-origin at /admin/cf/) in an
// iframe: same container, same origin, same RepoFabric session, so one login
// covers it. When the flag is off, nothing is injected and the SPA is
// byte-identical to a standalone RepoFabric deploy.
let cfFrameLoaded = false;
function loadCfFrame() {
  if (cfFrameLoaded) return;
  const f = $('#cf-frame');
  if (f) { f.src = 'cf/'; cfFrameLoaded = true; }
}
async function initConfigFabricTab() {
  let enabled = false;
  try {
    const r = await fetch('api/features', { credentials: 'same-origin' });
    if (r.ok) enabled = (await r.json()).configfabric === true;
  } catch { /* features probe failed -> treat as disabled */ }
  if (!enabled) return;
  if (!VALID_TABS.includes('configfabric')) VALID_TABS.push('configfabric');
  const nav = $('nav#tabs');
  if (nav && !nav.querySelector('button[data-tab="configfabric"]')) {
    const btn = document.createElement('button');
    btn.dataset.tab = 'configfabric';
    btn.textContent = 'ConfigFabric';
    btn.title = 'DSC v3 configuration fabric (ConfigFabric), absorbed sidecar';
    btn.addEventListener('click', () => activateTab('configfabric'));
    nav.appendChild(btn);
  }
  const main = $('#main');
  if (main && !$('#tab-configfabric')) {
    const sec = document.createElement('section');
    sec.id = 'tab-configfabric';
    sec.className = 'tab';
    const f = document.createElement('iframe');
    f.id = 'cf-frame';
    f.className = 'cf-frame';
    f.title = 'ConfigFabric admin';
    f.style.cssText = 'width:100%;min-height:calc(100vh - 130px);border:0;display:block;';
    sec.appendChild(f);
    main.appendChild(sec);
  }
  // The page may have been opened directly on #configfabric; bootTabFromHash
  // ran before this async probe resolved, so activate it now that it exists.
  if ((location.hash || '').replace(/^#/, '') === 'configfabric') activateTab('configfabric');
}

// ===================== Reconcile retention (preview -> apply) =====================
// Per-repo on-demand retention enforcement. The button previews (dry run) what a
// purge would remove for the SELECTED repo -- versions past retention plus
// orphaned publication rows (the ones that inflate the Pubs count above the real
// version count) -- then applies it only on confirm. Mirrors the nightly cron.
const dlgReconcile = $('#dlg-reconcile');

$('#btn-vrepo-reconcile-retention').onclick = () => openReconcile(state.selectedRepoId || 'main');

async function openReconcile(repoId) {
  $('#reconcile-title').textContent = `Reconcile retention — ${repoId}`;
  $('#reconcile-subtitle').textContent = 'Preview of what a retention purge would do. Nothing is deleted until you click Apply.';
  $('#reconcile-body').innerHTML = '<div class="muted">Computing preview…</div>';
  const applyBtn = $('#reconcile-apply');
  applyBtn.disabled = true;
  applyBtn.dataset.repoId = repoId;
  dlgReconcile.showModal();
  try {
    const p = await api('cleanup/preview', { method: 'POST', body: JSON.stringify({ RepoId: repoId }) });
    renderReconcilePreview(p, repoId);
  } catch (e) {
    $('#reconcile-body').innerHTML = `<div class="bad-text">Preview failed: ${escapeHtml(e.message)}</div>`;
  }
}

function renderReconcilePreview(p, repoId) {
  const evict = p.Evict || [];
  const orphans = p.Orphans || [];
  const s = p.Summary || {};
  const applyBtn = $('#reconcile-apply');
  if ((s.EvictVersions || 0) === 0 && (s.OrphanRows || 0) === 0) {
    $('#reconcile-body').innerHTML = `<div class="ok-text">Nothing to do — <code>${escapeHtml(repoId)}</code> is already within retention with no orphaned publication rows.</div>`;
    applyBtn.disabled = true;
    return;
  }
  let html = `<div class="reconcile-summary">Would remove <b>${s.EvictVersions || 0}</b> version(s) past retention and reconcile <b>${s.OrphanRows || 0}</b> orphaned publication row(s) across <b>${s.PackagesAffected || 0}</b> package(s).</div>`;
  if (evict.length) {
    html += `<h4>Versions past retention (will be unpublished)</h4><table class="reconcile-tbl"><thead><tr><th>Package</th><th>Keep</th><th>Remove</th></tr></thead><tbody>`;
    for (const e of evict) {
      html += `<tr><td><code>${escapeHtml(e.PackageId)}</code><br><small class="muted">keep ${e.KeepN}</small></td>`
        + `<td>${(e.Keep || []).map(v => `<span class="ver ver-keep">${escapeHtml(v)}</span>`).join(' ') || '<span class="muted">—</span>'}</td>`
        + `<td>${(e.Remove || []).map(v => `<span class="ver ver-drop">${escapeHtml(v)}</span>`).join(' ')}</td></tr>`;
    }
    html += `</tbody></table>`;
  }
  if (orphans.length) {
    html += `<h4>Orphaned publication rows <small class="muted">(manifest already gone from disk — this is the Pubs-count fix)</small></h4><table class="reconcile-tbl"><thead><tr><th>Package</th><th>Version</th><th>Outcome</th></tr></thead><tbody>`;
    for (const o of orphans) {
      html += `<tr><td><code>${escapeHtml(o.PackageId)}</code></td><td><span class="ver ver-orphan">${escapeHtml(o.Version)}</span></td><td class="muted">${escapeHtml(o.Outcome || '')}</td></tr>`;
    }
    html += `</tbody></table>`;
  }
  html += `<p class="muted reconcile-note">A version locked by a live ConfigFabric config may still be held back at apply time (fail-closed lock gate).</p>`;
  $('#reconcile-body').innerHTML = html;
  applyBtn.disabled = false;
}

$('#reconcile-cancel').onclick = () => dlgReconcile.close();
$('#reconcile-apply').onclick = async () => {
  const applyBtn = $('#reconcile-apply');
  const repoId = applyBtn.dataset.repoId;
  applyBtn.disabled = true;
  applyBtn.textContent = 'Applying…';
  try {
    const r = await api('cleanup/run', { method: 'POST', body: JSON.stringify({ RepoId: repoId }) });
    toast(`Reconcile ${r.status || 'done'}: removed ${r.removed || 0}, reconciled ${r.reconciled || 0}, within-retention ${r.skipped || 0}, failed ${r.failed || 0}.`, r.failed ? 'bad' : 'ok');
    dlgReconcile.close();
    if ($('#tab-subscriptions').classList.contains('active')) loadCatalog();
    if ($('#tab-inventory').classList.contains('active')) renderInventory();
  } catch (e) {
    toast(`Reconcile failed: ${e.message}`, 'bad');
  } finally {
    applyBtn.textContent = 'Apply purge';
  }
};

// ===================== Inventory tab =====================
// Full per-version view of ONE repo -- every version actually present (and every
// publication row, so orphans surface) -- compared against the PRIMARY repo so an
// operator can see at a glance whether this repo is ahead of / behind primary.
state.inventory = null;
state.invRepoId = null;
state.invPrimaryId = null;

async function loadInventory() {
  const statusEl = $('#inv-status');
  try {
    const pr = await api('settings/primary-repo'); // { primaryRepoId, repos:[{RepoId,DisplayName}] }
    const repos = pr.repos || [];
    if (!state.invRepoId || !repos.some(r => r.RepoId === state.invRepoId)) {
      state.invRepoId = (state.selectedRepoId && repos.some(r => r.RepoId === state.selectedRepoId)) ? state.selectedRepoId : pr.primaryRepoId;
    }
    if (!state.invPrimaryId || !repos.some(r => r.RepoId === state.invPrimaryId)) {
      state.invPrimaryId = pr.primaryRepoId;
    }
    fillRepoSelect($('#inv-repo-select'), repos, state.invRepoId);
    fillRepoSelect($('#inv-primary-select'), repos, state.invPrimaryId);
  } catch (e) {
    statusEl.textContent = `repo list failed: ${e.message}`;
    return;
  }
  await renderInventory();
}

function fillRepoSelect(sel, repos, selected) {
  sel.innerHTML = repos.map(r =>
    `<option value="${escapeHtml(r.RepoId)}"${r.RepoId === selected ? ' selected' : ''}>${escapeHtml(r.RepoId)}${r.DisplayName && r.DisplayName !== r.RepoId ? ` (${escapeHtml(r.DisplayName)})` : ''}</option>`
  ).join('');
}

async function renderInventory() {
  const repoId = $('#inv-repo-select').value;
  const primaryId = $('#inv-primary-select').value;
  if (!repoId) return;
  state.invRepoId = repoId; state.invPrimaryId = primaryId;
  const statusEl = $('#inv-status');
  const tbody = $('#inv-table tbody');
  statusEl.textContent = 'Loading…';
  tbody.innerHTML = `<tr><td colspan="7" class="muted">Scanning ${escapeHtml(repoId)}…</td></tr>`;
  let inv;
  try {
    inv = await api(`repo/inventory?repoId=${encodeURIComponent(repoId)}&primaryRepoId=${encodeURIComponent(primaryId)}`);
  } catch (e) {
    statusEl.textContent = '';
    tbody.innerHTML = `<tr><td colspan="7" class="bad-text">Inventory failed: ${escapeHtml(e.message)}</td></tr>`;
    return;
  }
  state.inventory = inv;
  statusEl.textContent = '';
  renderInventorySummary(inv);
  renderInventoryRows(inv);
}

function renderInventorySummary(inv) {
  const s = inv.Summary || {};
  const mb = ((s.TotalSizeBytes || 0) / 1048576).toFixed(1);
  const cmp = inv.IsPrimary
    ? `<span class="inv-pill inv-primary">this IS the primary repo</span>`
    : `<span class="inv-pill inv-ahead">${s.Ahead || 0} ahead</span> <span class="inv-pill inv-behind">${s.Behind || 0} behind</span> <span class="inv-pill inv-diverged">${s.Diverged || 0} diverged</span> <span class="inv-pill inv-insync">${s.InSync || 0} in sync</span>${s.MissingHere ? ` <span class="inv-pill inv-missinghere">${s.MissingHere} missing here</span>` : ''}${s.OnlyHere ? ` <span class="inv-pill inv-onlyhere">${s.OnlyHere} only here</span>` : ''}`;
  $('#inv-summary').innerHTML =
    `<div><b>${escapeHtml(inv.RepoId)}</b> — ${s.Packages || 0} package(s), ${s.OnDiskVersions || 0} version(s) on disk, ${mb} MB`
    + (s.OrphanRows ? ` · <span class="inv-pill inv-orphan">${s.OrphanRows} orphan publication row(s)</span>` : '')
    + `</div>`
    + `<div class="inv-compare">vs primary <code>${escapeHtml(inv.PrimaryRepoId)}</code>: ${cmp}</div>`;
}

function invStatusPill(st) {
  const cls = { ahead: 'inv-ahead', behind: 'inv-behind', diverged: 'inv-diverged', 'in-sync': 'inv-insync', 'only-here': 'inv-onlyhere', 'missing-here': 'inv-missinghere', primary: 'inv-primary' }[st] || '';
  const label = { 'in-sync': 'in sync', 'only-here': 'only here', 'missing-here': 'missing here' }[st] || st;
  return `<span class="inv-pill ${cls}">${escapeHtml(label)}</span>`;
}

function renderInventoryRows(inv) {
  const onlyIssues = $('#inv-only-issues').checked;
  const tbody = $('#inv-table tbody');
  let pkgs = inv.Packages || [];
  if (onlyIssues) {
    pkgs = pkgs.filter(p => p.OrphanCount > 0 || p.DropCount > 0 || (p.CompareStatus !== 'in-sync' && p.CompareStatus !== 'primary'));
  }
  if (!pkgs.length) {
    tbody.innerHTML = `<tr><td colspan="7" class="muted">${onlyIssues ? 'No drift or orphans — everything is within retention and in sync with primary.' : 'No packages in this repo.'}</td></tr>`;
    return;
  }
  tbody.innerHTML = pkgs.map(p => {
    const vers = (p.Versions || []).map(v => {
      let cls = 'ver';
      if (v.Orphan) cls += ' ver-orphan';
      else if (!v.OnDisk) cls += ' ver-nodisk';
      else if (!v.RetentionKeep) cls += ' ver-drop';
      else cls += ' ver-keep';
      if (v.Pinned) cls += ' ver-pinned';
      const flags = [];
      if (v.Pinned) flags.push('pinned');
      if (v.Orphan) flags.push('orphan: publication row but not on disk');
      else if (v.OnDisk && !v.RetentionKeep) flags.push('past retention — would drop');
      if (!v.OnDisk && v.HasPublication) flags.push('publication only');
      if (!inv.IsPrimary && !v.InPrimary) flags.push('not in primary');
      return `<span class="${cls}" title="${escapeHtml(flags.join(', '))}">${escapeHtml(v.Version)}<button type="button" class="ver-del" data-inv-action="del-ver" data-pkg="${escapeHtml(p.PackageId)}" data-ver="${escapeHtml(v.Version)}" title="Delete ${escapeHtml(v.Version)} from this repo">✕</button></span>`;
    }).join(' ');
    const totMB = ((p.Versions || []).filter(v => v.OnDisk).reduce((a, v) => a + (v.SizeBytes || 0), 0) / 1048576).toFixed(1);
    const ret = `<span class="muted">keep ${p.KeepN}</span>`
      + (p.DropCount ? ` · <span class="ver-drop-text">${p.DropCount} drop</span>` : '')
      + (p.OrphanCount ? ` · <span class="inv-pill inv-orphan">${p.OrphanCount} orphan</span>` : '');
    return `<tr>
      <td><code>${escapeHtml(p.PackageId)}</code>${p.PackageName ? `<br><small class="muted">${escapeHtml(p.PackageName)}</small>` : ''}</td>
      <td>${escapeHtml(p.Source)}</td>
      <td class="inv-vers">${vers || '<span class="muted">—</span>'}</td>
      <td>${invStatusPill(p.CompareStatus)}</td>
      <td>${ret}</td>
      <td>${totMB}</td>
      <td class="inv-actions">
        <button type="button" class="danger inv-btn" data-inv-action="del-pkg" data-pkg="${escapeHtml(p.PackageId)}" title="Delete ${escapeHtml(p.PackageId)} (all versions) from this repo">Delete</button>${p.Source === 'untracked' ? ` <button type="button" class="ghost inv-btn" data-inv-action="subscribe" data-pkg="${escapeHtml(p.PackageId)}" title="Adopt this orphaned package as a managed subscription">Subscribe</button>` : ''}
      </td>
    </tr>`;
  }).join('');
}

$('#inv-repo-select').onchange = renderInventory;
$('#inv-primary-select').onchange = renderInventory;
$('#inv-only-issues').onchange = () => { if (state.inventory) renderInventoryRows(state.inventory); };
$('#inv-refresh').onclick = renderInventory;
// When "Subscribe" is clicked on an untracked Inventory row, the package may
// already be a published subscription in ANOTHER repo. In that case promoting
// it into the viewed repo (copying the already-built manifest + installer) is
// faster than re-acquiring it and avoids the "subscription already exists"
// error from adding it to the wrong repo. Returns the source subscription to
// promote from, or null when no other repo has it published (so the caller
// falls back to a fresh subscription in the viewed repo).
async function findPromotableSource(packageId, targetRepoId) {
  if (!state.subs || !state.subs.length) {
    try { const b = await api('subscriptions'); state.subs = (b.subscriptions || []).filter(Boolean); }
    catch { return null; }
  }
  const candidates = (state.subs || []).filter(s =>
    s && s.PackageId === packageId && s.RepoId && s.RepoId !== targetRepoId);
  if (!candidates.length) return null;
  if (!state.pubs || !state.pubs.length) {
    try { const b = await api('publications'); state.pubs = (b.publications || []).filter(Boolean); }
    catch { /* treat as no publications: handled below */ }
  }
  // Promotion copies a built artifact, so only a source with at least one
  // published version is usable; an unsynced subscription has nothing to copy.
  return candidates.find(s =>
    (state.pubs || []).some(p => p.subscription_id === s.SubscriptionId)) || null;
}

// Delegated delete / subscribe for the Inventory table. Universal delete (whole
// package or one version) works across managed / custom / untracked via
// DELETE /api/repo/:repoId/package/:packageId; "Subscribe" re-adopts an orphaned
// package as a managed subscription (pre-fills the Add subscription search).
$('#inv-table').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-inv-action]');
  if (!btn) return;
  const action = btn.dataset.invAction;
  const pkg = btn.dataset.pkg;
  const repoId = state.invRepoId;
  if (!pkg || !repoId) return;
  if (action === 'subscribe') {
    // If this package is already published in another repo, promote it here
    // (publish to both) instead of erroring on a duplicate add or re-acquiring
    // from scratch. Otherwise open the Add-subscription dialog defaulted to the
    // repo currently being viewed (not the stale Catalog selection).
    btn.disabled = true;
    try {
      const src = await findPromotableSource(pkg, repoId);
      if (src) {
        await openPromoModalForSubscription(src, repoId);
      } else {
        await openSubDialog(null, repoId);
        const input = document.getElementById('pkg-search-input');
        if (input) { input.value = pkg; input.dispatchEvent(new Event('input', { bubbles: true })); }
      }
    } catch (err) {
      toast(`Subscribe: ${err.message}`, 'bad');
    } finally {
      btn.disabled = false;
    }
    return;
  }
  if (action === 'del-pkg' || action === 'del-ver') {
    const ver = btn.dataset.ver;
    const what = action === 'del-ver' ? `${pkg} ${ver}` : `${pkg} (all versions)`;
    if (!confirm(`Delete ${what} from ${repoId}?\n\nThis removes the manifest${action === 'del-ver' ? '' : 's'} and installer file(s) from this repo.`)) return;
    btn.disabled = true;
    try {
      const qs = action === 'del-ver' ? `?version=${encodeURIComponent(ver)}` : '';
      await api(`repo/${encodeURIComponent(repoId)}/package/${encodeURIComponent(pkg)}${qs}`, { method: 'DELETE' });
      toast(`Deleted ${what} from ${repoId}`, 'ok');
      await renderInventory();
    } catch (err) {
      toast(`Delete failed: ${err.message}`, 'bad');
      btn.disabled = false;
    }
  }
});
$('#inv-set-primary').onclick = async () => {
  const primaryId = $('#inv-primary-select').value;
  try {
    await api('settings/primary-repo', { method: 'PUT', body: JSON.stringify({ RepoId: primaryId }) });
    toast(`Primary repo set to ${primaryId}`, 'ok');
  } catch (e) { toast(`Set primary failed: ${e.message}`, 'bad'); }
};

// --- boot ---
loadMe();
initConfigFabricTab();

// Multi-repo controls need the Docker socket (each virtual repo spawns its own
// Rewinged container). When the socket is absent (the throwaway sandbox) we keep
// "+ add repo" and "Reconcile containers" VISIBLE -- so the UI matches the full
// deployment -- but route them to a friendly popup pointing at the full, free,
// more-secure production deployment, rather than creating repos that cannot
// serve here. Default LOCKED until features confirm the socket, so a fast click
// before the probe resolves never opens the (non-functional) add flow.
state.multiRepoLocked = true;
(async () => {
  try {
    const r = await fetch('api/features', { credentials: 'same-origin' });
    if (!r.ok) return;
    const f = await r.json();
    state.multiRepoLocked = !(f && f.docker_socket === true);
    state.isSandbox = !!(f && f.sandbox);
    state.httpPort  = (f && f.http_port) || 8080;
    // Reveal the header "Sandbox vs Recommended" compare button and the Settings
    // "Upgrade to Recommended" panel in the sandbox (both hidden once graduated).
    if (state.isSandbox) {
      const b = document.getElementById('btn-compare-deployments'); if (b) b.hidden = false;
      const u = document.getElementById('upgrade-card'); if (u) u.hidden = false;
    }
  } catch { /* features probe failed -> leave locked (safe default) */ }
})();
// Restore the last-visited tab from the URL hash so refresh / bookmark
// links open the page where the operator left it. Unknown / missing
// hash falls back to Subscriptions.
(function bootTabFromHash() {
  const want = (location.hash || '').replace(/^#/, '');
  activateTab(VALID_TABS.includes(want) ? want : 'subscriptions');
})();

// --- Sandbox -> Recommended upgrade panel (Settings tab; sandbox profile only) ---
// A re-runnable readiness check tests each gap (green/red/confirm); "Complete
// conversion" stays disabled until every check passes. Multi-visit friendly.
function upgPillClass(st) { return st === 'pass' ? 'inv-insync' : (st === 'confirm' ? 'inv-orphan' : 'inv-behind'); }
function upgPillLabel(st) { return st === 'pass' ? 'ready' : (st === 'confirm' ? 'confirm' : 'not ready'); }
function renderUpgradeChecks(data) {
  const wrap = document.getElementById('upgrade-checks');
  if (!wrap) return;
  const checks = (data && data.checks) || [];
  wrap.innerHTML = checks.map(c => {
    const fix = (c.status !== 'pass' && c.remediation)
      ? `<div class="upgrade-fix">${escapeHtml(c.remediation)}${c.link ? ` <a class="btn" href="${escapeHtml(c.link)}">Open</a>` : ''}</div>` : '';
    const confirmBox = c.confirmable
      ? `<label class="upgrade-confirm"><input type="checkbox" data-upgrade-confirm="${escapeHtml(c.key)}"${c.status === 'pass' ? ' checked' : ''}> I confirm this is in place</label>` : '';
    return `<div class="upgrade-check">
      <span class="inv-pill ${upgPillClass(c.status)}">${upgPillLabel(c.status)}</span>
      <div class="upgrade-check-body">
        <div class="upgrade-check-label">${escapeHtml(c.label)}</div>
        <div class="muted">${escapeHtml(c.detail || '')}</div>
        ${fix}${confirmBox}
      </div>
    </div>`;
  }).join('');
  const done = document.getElementById('btn-upgrade-complete');
  if (done) done.disabled = !(data && data.ready);
  const status = document.getElementById('upgrade-status');
  if (status) status.textContent = checks.length ? (data.ready ? 'All checks pass — ready to convert.' : `${checks.filter(c => c.status === 'pass').length}/${checks.length} ready.`) : '';
}
async function runUpgradeCheck() {
  const status = document.getElementById('upgrade-status');
  if (status) status.textContent = 'Checking…';
  try { renderUpgradeChecks(await api('upgrade/readiness')); }
  catch (e) { if (status) status.textContent = ''; toast(`Readiness check failed: ${e.message}`, 'bad'); }
}
{
  const btnCheck = document.getElementById('btn-upgrade-check');
  if (btnCheck) btnCheck.onclick = runUpgradeCheck;
  const btnDone = document.getElementById('btn-upgrade-complete');
  if (btnDone) btnDone.onclick = async () => {
    if (!confirm('Complete the conversion to the Recommended deployment?\n\nSign-in becomes Entra-only (the local admin becomes a dormant break-glass) and the sandbox warnings are removed. Run the readiness check again first if unsure.')) return;
    btnDone.disabled = true;
    try {
      const res = await api('upgrade/complete', { method: 'POST' });
      toast('Converting to Recommended… reloading once node-admin restarts.', 'ok');
      setTimeout(() => { location.href = (res && res.redirect_to) || '/admin/'; }, 3000);
    } catch (e) { toast(`Conversion blocked: ${e.message}`, 'bad'); btnDone.disabled = false; }
  };
  const checksWrap = document.getElementById('upgrade-checks');
  if (checksWrap) checksWrap.addEventListener('change', async (e) => {
    const cb = e.target.closest('[data-upgrade-confirm]');
    if (!cb) return;
    try {
      await api('upgrade/confirm', { method: 'POST', body: JSON.stringify({ key: cb.dataset.upgradeConfirm, confirmed: cb.checked }) });
      await runUpgradeCheck();
    } catch (err) { toast(`Confirm failed: ${err.message}`, 'bad'); cb.checked = !cb.checked; }
  });
}
