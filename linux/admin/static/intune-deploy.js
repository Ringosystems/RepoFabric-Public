// Intune Settings Catalog export wizard. RingoSystems Heavy Industries UNRAID-local fork.
// Renders the 15 DesktopAppInstaller CSP policies grouped by section, with
// explicit per-policy consequence text for Enabled vs Disabled. Live JSON
// preview rebuilds via POST /api/intune/policy. Download writes a browser
// Blob so the operator hands the file to an Intune admin who imports it
// under their own credentials.

const API = '/admin/api';

function $(s, r = document)  { return r.querySelector(s); }
function $$(s, r = document) { return Array.from(r.querySelectorAll(s)); }

// ===== Policy catalog ==================================================
// Each row drives one card in the wizard. The recommended state matches
// the locked-decision table in the plan: lock the surface down, allow
// only this server's REST source, force-refresh hourly. Operator can
// flip any of them before exporting.
const POLICIES = [
  // -- Client surface ----------------------------------------------------
  {
    name: 'EnableAppInstaller',
    section: 'client',
    recommended: 'enabled',
    textEnabled:  'winget is available on the device. CLI, GUI, configure, source list, install and upgrade all work.',
    textDisabled: 'winget on the device is completely disabled. Every winget command exits with "disabled by group policy". Users cannot install, upgrade, or list anything. Use this only as a kill-switch.',
  },
  {
    name: 'EnableWindowsPackageManagerCommandLineInterfaces',
    section: 'client',
    recommended: 'enabled',
    textEnabled:  'The winget CLI is available to users, scripts, and Intune Win32 app deployments. Required for almost every winget workflow.',
    textDisabled: 'The winget command exits with "disabled by group policy". Endpoint can no longer self-install or upgrade via CLI. Recommended only for kiosk or tightly locked-down endpoints.',
  },
  {
    name: 'EnableWindowsPackageManagerConfiguration',
    section: 'client',
    recommended: 'enabled',
    textEnabled:  'winget configure (Desired State Configuration) is available. Useful for repeatable workstation onboarding from a YAML file.',
    textDisabled: 'winget configure exits with "disabled by group policy". DSC-style provisioning via winget is blocked.',
  },
  {
    name: 'EnableSettings',
    section: 'client',
    recommended: 'disabled',
    textEnabled:  'Users may edit settings.json in their profile to change winget behaviour locally (download method, UI preferences, experimental features per-user). Local edits can weaken your lockdown.',
    textDisabled: 'winget settings still opens but every edit to settings.json is ignored. Local overrides cannot weaken the lockdown.',
  },

  // -- Hardening overrides ----------------------------------------------
  {
    name: 'EnableExperimentalFeatures',
    section: 'hardening',
    recommended: 'disabled',
    textEnabled:  'Users can flip experimental flags in settings.json (resume, download, dependencies preview, and other in-progress work). Endpoint behaviour becomes unpredictable.',
    textDisabled: 'Experimental flags are forced off. Only shipped, stable winget behaviour runs on managed endpoints.',
  },
  {
    name: 'EnableLocalManifestFiles',
    section: 'hardening',
    recommended: 'disabled',
    textEnabled:  'winget install --manifest <path-to-yaml> is allowed. A user can sideload any installer just by writing a local manifest pointing at any URL.',
    textDisabled: 'The --manifest flag is rejected. Installs must come from a configured source. Closes the side-door for unsigned and unvetted packages.',
  },
  {
    name: 'EnableHashOverride',
    section: 'hardening',
    recommended: 'disabled',
    textEnabled:  'winget install --ignore-hashes is allowed. The downloaded installer runs even if its SHA-256 does not match the manifest.',
    textDisabled: 'Hash mismatch always blocks the install. A swapped or corrupted installer cannot be executed.',
  },
  {
    name: 'EnableLocalArchiveMalwareScanOverride',
    section: 'hardening',
    recommended: 'disabled',
    textEnabled:  'winget install --ignore-local-archive-malware-scan is allowed. Built-in scans for zip and portable installer types can be bypassed.',
    textDisabled: 'The override flag is rejected. Built-in malware scan always runs on archive installers.',
  },
  {
    name: 'EnableMSAppInstallerProtocol',
    section: 'hardening',
    recommended: 'disabled',
    textEnabled:  'ms-appinstaller:// links handle from a browser. A web page can launch the App Installer UI directly. This is the vector used by recent drive-by install campaigns.',
    textDisabled: 'Clicking an ms-appinstaller:// link does nothing. Installs must be initiated from the CLI, GUI, or winget configure against a configured source.',
  },

  // -- Public sources ---------------------------------------------------
  {
    name: 'EnableDefaultSource',
    section: 'public',
    recommended: 'disabled',
    textEnabled:  'The public WinGet community source (named "winget") is available. Users can winget install any public package, regardless of whether it is in your inventory.',
    textDisabled: 'The public source is gone from winget source list. Only the sources you allow (i.e. yours) can resolve packages. Closes drift to unmanaged inventory.',
  },
  {
    name: 'EnableMicrosoftStoreSource',
    section: 'public',
    recommended: 'disabled',
    textEnabled:  'The msstore source is available. winget install of Store apps works.',
    textDisabled: 'msstore source is gone. Store apps must be deployed through Intune mobileApps, or not at all.',
  },
  {
    name: 'EnableBypassCertificatePinningForMicrosoftStore',
    section: 'public',
    recommended: 'not_configured',
    textEnabled:  'winget skips certificate pinning when reaching the Microsoft Store source. Only ever needed when a TLS-inspecting proxy is in the path. Has no effect on your private REST source.',
    textDisabled: 'Pinning is enforced for Store traffic (the secure default). Irrelevant when EnableMicrosoftStoreSource is Disabled.',
  },

  // -- Private REST source ----------------------------------------------
  {
    name: 'EnableAdditionalSources',
    section: 'private',
    recommended: 'enabled',
    textEnabled:  'Forces this REST source onto every endpoint via the XML payload built from the fields above. Users cannot remove it, even with winget source remove. This is the policy that wires up your private source.',
    textDisabled: 'No additional sources are pushed. Endpoint sees only sources users add manually, which means your private source will not be present unless every user adds it by hand.',
  },
  {
    name: 'EnableAllowedSources',
    section: 'private',
    recommended: 'enabled',
    textEnabled:  'The listed sources are the ONLY ones the client may use. winget source add is blocked for anything outside the allow list. Restricts inventory to exactly what you ship.',
    textDisabled: 'Users can add any source they like with winget source add. Inventory drift becomes possible. Combine with EnableDefaultSource Disabled if you still want the public source closed.',
  },
];

// ===== State =============================================================
const state = {
  // policy short name -> 'enabled' | 'disabled' | 'not_configured'.
  // SourceAutoUpdateInterval is a numeric policy; we mark it 'enabled' so
  // the backend emits the integer setting using source_auto_update_minutes.
  // Operator zeroes the input to skip it (handled in rebuild()).
  settings: {
    ...Object.fromEntries(POLICIES.map(p => [p.name, p.recommended])),
    SourceAutoUpdateInterval: 'enabled',
  },
  lastJson: '',
  lastOma: [],
};

// ===== Render ============================================================

function policyCard(p) {
  const tpl = $('#policyTemplate');
  const card = tpl.content.firstElementChild.cloneNode(true);
  card.dataset.policy = p.name;
  card.querySelector('[data-policy-name]').textContent = p.name;
  const recTag = card.querySelector('[data-policy-rec]');
  if (p.recommended === 'enabled')        { recTag.textContent = 'Recommended: Enabled';        recTag.classList.add('rec-en'); }
  else if (p.recommended === 'disabled')  { recTag.textContent = 'Recommended: Disabled';       recTag.classList.add('rec-di'); }
  else                                    { recTag.textContent = 'Recommended: Not configured'; recTag.classList.add('rec-nc'); }

  card.querySelector('[data-text-enabled]').textContent  = p.textEnabled;
  card.querySelector('[data-text-disabled]').textContent = p.textDisabled;

  const radios = card.querySelectorAll('input[type=radio]');
  radios.forEach(r => {
    r.name = `pol_${p.name}`;
    if (r.value === state.settings[p.name]) r.checked = true;
    r.addEventListener('change', () => {
      state.settings[p.name] = r.value;
      reflectActiveConsequence(card, r.value);
      scheduleRebuild();
    });
  });
  reflectActiveConsequence(card, state.settings[p.name]);
  return card;
}

function reflectActiveConsequence(card, value) {
  $$('.iw-conseq', card).forEach(el => {
    el.classList.toggle('is-active', el.dataset.conseq === value);
  });
  const pill = card.querySelector('[data-policy-pill]');
  pill.classList.remove('ok', 'warn', 'error');
  if (value === 'not_configured') {
    pill.classList.add('warn');
  } else {
    pill.classList.add('ok');
  }
}

function renderAll() {
  const buckets = { client: [], hardening: [], public: [], private: [] };
  POLICIES.forEach(p => buckets[p.section].push(policyCard(p)));
  Object.entries(buckets).forEach(([section, cards]) => {
    const host = $(`#policies-${section}`);
    cards.forEach(c => host.appendChild(c));
  });
}

// ===== Validation =========================================================

function setIndicator(id, level) {
  const ind = $(`[data-ind-for="${id}"]`);
  if (!ind) return;
  ind.classList.remove('ok', 'warn', 'error');
  ind.textContent = '';
  if (level === 'ok')    { ind.classList.add('ok');    ind.textContent = 'OK'; }
  if (level === 'warn')  { ind.classList.add('warn');  ind.textContent = '!';  }
  if (level === 'error') { ind.classList.add('error'); ind.textContent = 'X';  }
}

function validateMeta() {
  const name = $('#policy_name').value.trim();
  const url  = $('#source_url').value.trim();
  let ok = true;
  if (!name)                                   { setIndicator('policy_name', 'error'); ok = false; }
  else if (name.length < 3)                    { setIndicator('policy_name', 'warn');  }
  else                                         { setIndicator('policy_name', 'ok'); }

  // very permissive URL check; the pwsh side will be the real gate.
  if (!url)                                    { setIndicator('source_url', 'error'); ok = false; }
  else if (!/^https?:\/\/.+/i.test(url))       { setIndicator('source_url', 'error'); ok = false; }
  else                                         { setIndicator('source_url', 'ok'); }

  const pill = $('#pill-meta');
  pill.classList.remove('ok', 'warn', 'error');
  pill.classList.add(ok ? 'ok' : 'error');
  return ok;
}

// ===== Live preview =======================================================

let rebuildTimer = null;
function scheduleRebuild() {
  if (rebuildTimer) clearTimeout(rebuildTimer);
  rebuildTimer = setTimeout(rebuild, 200);
}

async function rebuild() {
  const metaOk = validateMeta();
  $('#downloadBtn').disabled = !metaOk;
  $('#exportHint').textContent = metaOk ? 'Ready. JSON is built server-side; preview below.' : 'Fill the red fields, then download.';

  if (!metaOk) {
    $('#pill-export').classList.remove('ok');
    $('#pill-export').classList.add('warn');
    return;
  }

  // 0 in the interval input means "do not push SourceAutoUpdateInterval at all".
  const intervalMinutes = Number($('#source_auto_update_minutes').value);
  const effectiveSettings = { ...state.settings };
  if (!intervalMinutes || intervalMinutes <= 0) {
    effectiveSettings.SourceAutoUpdateInterval = 'not_configured';
  } else {
    effectiveSettings.SourceAutoUpdateInterval = 'enabled';
  }

  const body = {
    policy_name:               $('#policy_name').value.trim(),
    description:               $('#description').value.trim() || undefined,
    source_url:                $('#source_url').value.trim(),
    source_name:               $('#source_name').value.trim() || 'repofabric',
    source_identifier:         $('#source_identifier').value.trim() || 'RfPrivate',
    source_auto_update_minutes:intervalMinutes || 60,
    settings:                  effectiveSettings,
  };

  try {
    const r = await fetch(`${API}/intune/policy`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });
    if (!r.ok) throw new Error(await r.text());
    const out = await r.json();
    state.lastJson = out.Json || '';
    state.lastOma  = out.OmaUri || [];
    $('#jsonPreview').textContent = state.lastJson || '(empty)';
    renderOmaPanel(state.lastOma);
    $('#pill-export').classList.remove('warn', 'error');
    $('#pill-export').classList.add('ok');
  } catch (e) {
    $('#jsonPreview').textContent = `ERROR: ${e.message}`;
    $('#pill-export').classList.remove('ok', 'warn');
    $('#pill-export').classList.add('error');
  }
}

function renderOmaPanel(rows) {
  const tbody = $('#omaBody');
  tbody.innerHTML = '';
  rows.forEach(row => {
    const tr = document.createElement('tr');
    const cols = [row.Policy, row.Path, row.DataType, String(row.Value).slice(0, 800)];
    cols.forEach(v => {
      const td = document.createElement('td');
      td.textContent = v;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
}

// ===== Download / copy ====================================================

function safeFilename(s) {
  return (s || 'policy')
    .replace(/[^A-Za-z0-9_.-]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 80) || 'policy';
}

function download() {
  if (!state.lastJson) return;
  const name = safeFilename($('#policy_name').value.trim()) + '.json';
  const blob = new Blob([state.lastJson], { type: 'application/json' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url; a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function copyJson() {
  if (!state.lastJson) return;
  try {
    await navigator.clipboard.writeText(state.lastJson);
    $('#exportHint').textContent = 'JSON copied to clipboard.';
  } catch (e) {
    $('#exportHint').textContent = `Clipboard copy failed: ${e.message}`;
  }
}

function toggleOma() {
  const panel = $('#omaPanel');
  const wasHidden = panel.hasAttribute('hidden');
  if (wasHidden) panel.removeAttribute('hidden'); else panel.setAttribute('hidden', '');
  $('#toggleOmaBtn').textContent = wasHidden ? 'Hide OMA-URI table' : 'Show OMA-URI table';
}

// ===== Bootstrap ==========================================================

async function defaultSourceUrlFromConfig() {
  // Pull solution.container.public_url to default the REST URL for the
  // 'main' repo. Falls back to current page origin if the field is empty.
  // Used as the base URL when a non-main repo has no Hostname set, by
  // swapping hostname segments.
  try {
    const r = await fetch(`${API}/config/solution`);
    if (r.ok) {
      const cfg = await r.json();
      const pub = cfg?.container?.public_url;
      if (pub) {
        const trimmed = pub.replace(/\/+$/, '');
        return trimmed + '/api/';
      }
    }
  } catch { /* fall through */ }
  return location.origin + '/api/';
}

// ===== Virtual repo support (Phase F prep) =================================
// The Intune wizard now scopes its export to a single virtual repo. The
// REST source URL, source name, identifier, and policy name auto-fill
// from the selected repo's stored fields, so the operator's effort is
// limited to picking the repo and clicking download.
let _repos = [];
let _mainPublicUrl = null;

async function loadVirtualRepos() {
  try {
    const r = await fetch(`${API}/virtual-repos`);
    if (!r.ok) return [];
    const body = await r.json();
    return (body.virtualRepos || []).filter(v => v.Status !== 'archived');
  } catch { return []; }
}

function urlForRepo(repo) {
  // 'main' uses solution.yaml's container.public_url (the legacy single-
  // repo deployment URL). Other repos use their stored Hostname; if that
  // is unset, we synthesise a placeholder so the operator can see and
  // edit the value rather than getting a blank field.
  if (!repo) return _mainPublicUrl || `${location.origin}/api/`;
  if (repo.RepoId === 'main') return _mainPublicUrl || `${location.origin}/api/`;
  if (repo.Hostname) return `https://${repo.Hostname}/api/`;
  if (repo.BaseDomain) return `https://winget-${repo.RepoId}.${repo.BaseDomain}/api/`;
  return `https://winget-${repo.RepoId}.<base-domain>/api/  (set Hostname on the repo first)`;
}

function applyRepoDefaults(repo) {
  if (!repo) return;
  const today = new Date().toISOString().slice(0, 10);
  const niceName = repo.DisplayName || repo.RepoId;

  // Policy name pulls in the repo so an admin importing several policies
  // can tell them apart in the Intune console without opening each one.
  $('#policy_name').value = `RingoSystems - WinGet Lockdown - ${niceName} ${today}`;

  // Description mentions the repo and its hostname so the audit trail
  // in Intune's policy detail makes the deployment intent obvious.
  $('#description').value =
    `RepoFabric (RingoSystems Heavy Industries) lockdown for the '${repo.RepoId}' virtual repo. ` +
    `Locks the DesktopAppInstaller surface and pins clients to ${repo.Hostname || '(unset hostname)'}.`;

  $('#source_url').value        = urlForRepo(repo);
  $('#source_name').value       = (repo.RepoId === 'main') ? 'repofabric' : `repofabric-${repo.RepoId}`;
  $('#source_identifier').value = (repo.RepoId === 'main') ? 'RfPrivate'  : `RfPrivate${repo.RepoId.charAt(0).toUpperCase()}${repo.RepoId.slice(1).replace(/-/g, '')}`;
}

function populateRepoDropdown(repos) {
  const sel = $('#repo_id');
  sel.innerHTML = '';
  if (!repos.length) {
    sel.innerHTML = '<option value="">(no virtual repos available)</option>';
    sel.disabled = true;
    return;
  }
  sel.disabled = false;
  for (const r of repos) {
    const opt = document.createElement('option');
    opt.value = r.RepoId;
    const status = (r.Status && r.Status !== 'active') ? ` [${r.Status}]` : '';
    opt.textContent = `${r.RepoId} (${r.DisplayName || r.RepoId})${status}`;
    sel.appendChild(opt);
  }
}

async function bootstrap() {
  renderAll();

  // Pull repos and the legacy main public URL in parallel.
  const [repos, mainUrl] = await Promise.all([
    loadVirtualRepos(),
    defaultSourceUrlFromConfig(),
  ]);
  _repos = repos;
  _mainPublicUrl = mainUrl;

  populateRepoDropdown(repos);

  // Auto-pick 'main' if present, otherwise the first available repo.
  const initial = repos.find(r => r.RepoId === 'main') || repos[0];
  if (initial) {
    $('#repo_id').value = initial.RepoId;
    applyRepoDefaults(initial);
  } else {
    // Fallback: legacy behaviour when no repos exist yet.
    const today = new Date().toISOString().slice(0, 10);
    $('#policy_name').value = `RingoSystems - WinGet Lockdown ${today}`;
    $('#source_url').value  = mainUrl;
  }

  // Repo change re-applies defaults to ALL repo-derived fields, even
  // ones the operator may have edited. Operators who want to keep
  // edits in place should leave the dropdown alone after picking.
  $('#repo_id').addEventListener('change', () => {
    const r = _repos.find(x => x.RepoId === $('#repo_id').value);
    if (r) applyRepoDefaults(r);
    scheduleRebuild();
  });

  // Wire up live preview triggers.
  ['policy_name', 'description', 'source_url', 'source_name', 'source_identifier', 'source_auto_update_minutes']
    .forEach(id => $(`#${id}`).addEventListener('input', scheduleRebuild));

  // Buttons.
  $('#downloadBtn').addEventListener('click', download);
  $('#copyBtn').addEventListener('click', copyJson);
  $('#toggleOmaBtn').addEventListener('click', toggleOma);

  // Kick off the first preview build.
  scheduleRebuild();
}

bootstrap();
