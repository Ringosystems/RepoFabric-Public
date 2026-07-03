// Setup wizard front-end. Seven-step flow (Welcome / Targets / Defaults /
// Schedule / Identity / Optional / Review) with rich probe feedback for
// Gitea, rewinged, and Entra. Steps are freely navigable: Next never blocks
// and the step tabs jump anywhere once the token is verified. Every required
// answer is validated together at Save, which points the operator at the
// first gap.

const state = { step: 0, values: {} };

function $(sel, root = document) { return root.querySelector(sel); }
function $$(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

function showStep(n) {
  $$('.panel').forEach(p => { p.hidden = (Number(p.dataset.panel) !== n); });
  $$('#steps li').forEach(li => li.classList.toggle('active', Number(li.dataset.step) === n));
  state.step = n;
  document.body.dataset.step = String(n);
  window.scrollTo({ top: 0, behavior: 'instant' });
  if (n === 6) renderReview();
}

// Free navigation via the step tabs. The token gate still applies: the
// wizard body cannot be reached until the setup token is verified.
function gotoStep(n) {
  if (Number.isNaN(n) || n === state.step) return;
  if (!state.values.token) return showStep(0);
  collectInputs($(`[data-panel="${state.step}"]`));
  showStep(n);
}

function collectInputs(panel) {
  $$('input, select', panel).forEach(el => {
    const name = el.name;
    if (!name) return;
    state.values[name] = (el.type === 'checkbox') ? el.checked : el.value;
  });
}

// Field validation. VALIDATORS / VALIDATOR_HINT define the shape checks and
// setFieldState paints a field ok / error inline. validateAll() runs at Save
// (not on Next), so the operator can browse every step freely and is only
// stopped at the finish line.
const VALIDATORS = {
  'url':         v => /^https?:\/\/[^/\s]+(\/.*)?$/.test(v) && !v.endsWith('/'),
  'owner-repo':  v => /^[^/\s]+\/[^/\s]+$/.test(v),
  'guid':        v => /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(v),
  'csv-arch':    v => v.split(',').map(s => s.trim()).filter(Boolean).every(a => ['x64','x86','arm64','arm'].includes(a)),
  'csv-locale':  v => v.split(',').map(s => s.trim()).filter(Boolean).every(l => /^[a-z]{2}(-[A-Z]{2})?$/.test(l)),
  'cron':        v => v.trim().split(/\s+/).length === 5,
};
const VALIDATOR_HINT = {
  'url':        'Expected an http(s):// URL with no trailing slash.',
  'owner-repo': 'Expected <owner>/<repo> form.',
  'guid':       'Expected an 8-4-4-4-12 hex GUID.',
  'csv-arch':   'Comma-separated. Valid values: x64, x86, arm64, arm.',
  'csv-locale': 'Comma-separated BCP-47 tags (e.g. en-US, fr-FR).',
  'cron':       'Standard 5-field cron (minute hour dom month dow).',
};

function setFieldState(el, ok, errMsg) {
  const label = el.closest('label');
  if (!label) return;
  label.classList.toggle('is-invalid', !ok);
  let hint = label.querySelector('.validation-msg');
  if (!ok) {
    if (!hint) {
      hint = document.createElement('small');
      hint.className = 'validation-msg';
      label.appendChild(hint);
    }
    hint.textContent = errMsg;
  } else if (hint) {
    hint.remove();
  }
}

const STEP_NAMES = { 1: 'Targets', 2: 'Defaults', 3: 'Schedule', 4: 'Identity', 5: 'Optional' };

// Whole-wizard validation, run at Save. Marks every empty required or
// mis-shaped field across all input steps and reports which steps still need
// attention plus the first offending element, so free navigation stays
// unblocked until the finish line.
function validateAll() {
  const badSteps = [];
  let count = 0;
  let firstEl = null;
  $$('.panel').forEach(panel => {
    const step = Number(panel.dataset.panel);
    if (step === 0 || step === 6) return; // token + review carry no inputs
    let panelBad = false;
    $$('input, select', panel).forEach(el => {
      const required = el.hasAttribute('data-required');
      const validator = el.getAttribute('data-validate');
      const raw = (el.value || '').trim();
      let msg = null;
      if (required && !raw) msg = 'Required.';
      else if (validator && raw && VALIDATORS[validator] && !VALIDATORS[validator](raw)) msg = VALIDATOR_HINT[validator] || 'Invalid format.';
      setFieldState(el, !msg, msg);
      if (msg) { count++; panelBad = true; if (!firstEl) firstEl = el; }
    });
    if (panelBad) badSteps.push(step);
  });
  return { ok: count === 0, count, badSteps, firstEl };
}

async function verifyToken() {
  const tokenEl = $('#setupToken');
  const token = tokenEl.value.trim();
  if (!token) {
    setFieldState(tokenEl, false, 'Required.');
    return showError('#tokenError', 'Token is required.');
  }
  try {
    const r = await fetch('/setup/api/verify-token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token })
    });
    const body = await r.json();
    if (!r.ok || !body.ok) {
      setFieldState(tokenEl, false, 'Token rejected.');
      return showError('#tokenError', body.error || 'Token rejected.');
    }
    state.values.token = token;
    hideError('#tokenError');
    showStep(1);
  } catch (err) {
    showError('#tokenError', err.message);
  }
}

// Rich probe feedback. The /setup/api/probe/* endpoints already return
// structured detail (full_name for Gitea, source_identifier for
// rewinged, expires_in for Entra). Render those instead of a bare
// "OK" so the operator knows WHAT was reached and HOW it answered.
async function probe(kind) {
  collectInputs($(`[data-panel="${state.step}"]`));
  const out = $(`[data-probe-result="${kind}"]`);
  out.className = 'probe-result probe-result-pending';
  out.innerHTML = '<strong>Probing...</strong>';
  let body;
  if (kind === 'gitea') {
    body = { base_url: state.values.gitea_base_url, repo: state.values.gitea_repo, pat: state.values.gitea_pat };
  } else if (kind === 'rewinged') {
    body = { url: state.values.rewinged_url };
  } else if (kind === 'entra') {
    body = { tenant_id: state.values.entra_tenant_id, client_id: state.values.entra_client_id, client_secret: state.values.entra_client_secret };
  }
  try {
    const r = await fetch(`/setup/api/probe/${kind}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await r.json();
    if (data.ok) {
      out.className = 'probe-result probe-result-ok';
      out.innerHTML = renderProbeOk(kind, body, data);
    } else {
      out.className = 'probe-result probe-result-fail';
      out.innerHTML = renderProbeFail(kind, body, data);
    }
  } catch (err) {
    out.className = 'probe-result probe-result-fail';
    out.innerHTML = `<strong>Probe error.</strong> <code>${escHtml(err.message)}</code>`;
  }
}

function renderProbeOk(kind, body, data) {
  if (kind === 'gitea') {
    return `
      <strong>Connected to Gitea.</strong>
      <ul>
        <li>Reached <code>${escHtml(body.base_url)}</code></li>
        <li>Repo: <code>${escHtml(data.full_name || body.repo)}</code></li>
        <li>HTTP ${data.status}</li>
      </ul>`;
  }
  if (kind === 'rewinged') {
    return `
      <strong>Connected to rewinged.</strong>
      <ul>
        <li>Reached <code>${escHtml(body.url)}/information</code></li>
        ${data.source_identifier ? `<li>SourceIdentifier: <code>${escHtml(data.source_identifier)}</code></li>` : ''}
        <li>HTTP ${data.status}</li>
      </ul>`;
  }
  if (kind === 'entra') {
    return `
      <strong>Entra credentials accepted.</strong>
      <ul>
        <li>Tenant: <code>${escHtml(body.tenant_id)}</code></li>
        <li>Client: <code>${escHtml(body.client_id)}</code></li>
        ${data.expires_in ? `<li>Access token issued (expires in ${data.expires_in}s)</li>` : ''}
      </ul>`;
  }
  return '<strong>OK.</strong>';
}

function renderProbeFail(kind, body, data) {
  let head;
  if (kind === 'gitea')    head = `Could not reach Gitea at <code>${escHtml(body.base_url)}</code>.`;
  else if (kind === 'rewinged') head = `Could not reach rewinged at <code>${escHtml(body.url)}</code>.`;
  else if (kind === 'entra')    head = `Entra rejected the credentials.`;
  else head = 'Probe failed.';
  const details = [];
  if (data.status) details.push(`HTTP ${data.status}`);
  if (data.error)  details.push(typeof data.error === 'string' ? data.error : JSON.stringify(data.error));
  if (data.detail) details.push(typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail));
  return `
    <strong>${head}</strong>
    ${details.length ? `<ul>${details.map(d => `<li><code>${escHtml(d)}</code></li>`).join('')}</ul>` : ''}`;
}

function escHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// Copy the text content of a derived read-out (e.g. the WinGet source URL)
// to the clipboard. Falls back silently where the clipboard API is blocked.
function copyReadout(btn) {
  const el = document.getElementById(btn.dataset.copy);
  if (!el) return;
  const done = () => { const prev = btn.textContent; btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = prev; }, 1200); };
  if (navigator.clipboard) navigator.clipboard.writeText(el.textContent).then(done, done);
  else done();
}

function buildPayload() {
  const v = state.values;
  return {
    defaults: {
      preferred_architectures: (v.architectures || 'x64,x86,arm64').split(',').map(s => s.trim()).filter(Boolean),
      locales:                 (v.locales || 'en-US').split(',').map(s => s.trim()).filter(Boolean),
      retention_count:         Number(v.retention_count || 3),
      scope:                   v.scope || 'machine'
    },
    sync: {
      worker_pool_size:              Number(v.worker_pool_size || 4),
      schedule_cron:                 v.schedule_cron || '0 */6 * * *',
      index_refresh_threshold_hours: Number(v.index_refresh_threshold_hours || 6)
    },
    auth: {
      tenant_id:     v.entra_tenant_id || '',
      client_id:     v.entra_client_id || '',
      client_secret: v.entra_client_secret || '',
      allowed_users:  (v.allowed_users  || '').split(',').map(s => s.trim()).filter(Boolean),
      allowed_groups: (v.allowed_groups || '').split(',').map(s => s.trim()).filter(Boolean).map(id => ({ id, display_name: id }))
    },
    targets: {
      gitea_base_url:     v.gitea_base_url,
      gitea_repo:         v.gitea_repo,
      gitea_pat:          v.gitea_pat || '',
      rewinged_url:       v.rewinged_url,
      installer_base_url: v.installer_base_url
    },
    notifications: {
      smtp: { host: v.smtp_host || '', port: Number(v.smtp_port || 25), from: v.smtp_from || '', to: (v.smtp_to || '').split(',').map(s => s.trim()).filter(Boolean) }
    }
  };
}

function renderReview() {
  // Redact secrets from the on-screen review so a screenshot of the
  // wizard's last step does not leak them. They're still saved as
  // entered; only the rendered payload masks them.
  const payload = buildPayload();
  const safe = JSON.parse(JSON.stringify(payload));
  if (safe.targets?.gitea_pat) safe.targets.gitea_pat = '********';
  if (safe.auth?.client_secret) safe.auth.client_secret = '********';
  $('#reviewPayload').textContent = JSON.stringify(safe, null, 2);
}

async function save() {
  $('#saveError').hidden = true;
  // Free navigation means the operator can reach Save with gaps. Enforce every
  // required answer here, mark the offenders, and name the steps that need work.
  const check = validateAll();
  if (!check.ok) {
    const d = check.firstEl && check.firstEl.closest('details'); if (d) d.open = true;
    const names = check.badSteps.map(s => STEP_NAMES[s] || ('Step ' + s)).join(', ');
    return showError('#saveError', `${check.count} required ${check.count === 1 ? 'answer is' : 'answers are'} still missing or invalid on: ${names}. Use the step tabs above to jump to each, then Save again.`);
  }
  const payload = buildPayload();
  try {
    const r = await fetch('/setup/api/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const body = await r.json();
    if (!r.ok || !body.ok) return showError('#saveError', body.error || 'Save failed');
    renderDonePage();
  } catch (err) {
    showError('#saveError', err.message);
  }
}

// After-save page. Replaces the wizard with a card that explains what
// just happened and what to do next, instead of leaving the operator
// staring at a "Setup complete" two-liner with no orientation.
function renderDonePage() {
  document.body.innerHTML = `
    <div class="done">
      <h1>Setup complete</h1>
      <p>Configuration was written to <code>/var/lib/repofabric/config/</code> (<code>service.yaml</code> + <code>solution.yaml</code>). The setup token was invalidated; the container will refuse this wizard from now on unless an admin re-enables it.</p>

      <h2>Next steps</h2>
      <ol class="done-next">
        <li>Sign into the admin: <a href="/admin/">open the admin UI</a>. You will be redirected to Entra; sign in with any UPN you listed under <em>Allowed users</em>.</li>
        <li>Add your first managed subscription: Subscriptions tab &rarr; <strong>+ Add subscription</strong>. Type-ahead searches the local upstream index.</li>
        <li>Publish a custom in-house app (optional): Subscriptions tab &rarr; <strong>+ Publish custom app</strong>. Drop an MSI / EXE; the wizard auto-fills from the binary's metadata.</li>
        <li>Run the first sync: Activity tab &rarr; <strong>Sync all subscriptions</strong>. The first run can take a few minutes while the upstream index is built.</li>
        <li>Generate an Intune policy (optional): Settings tab &rarr; <strong>Open Intune export wizard</strong>. Hands an Intune admin a Settings Catalog JSON to lock managed endpoints to this REST source.</li>
      </ol>

      <p class="muted">If anything looks wrong in the saved config, hit <strong>Settings &rarr; Advanced &rarr; Re-enter setup wizard</strong> from the admin to walk the steps again without editing YAML by hand.</p>
    </div>`;
}

// --- Entra app-registration bootstrap (step 4) ----------------------------
// Ask the server for a pre-filled `az` script (redirect URI derived server-side
// so it is always exact), show it with a copy button, and optionally autofill
// the three credential fields from the script's printed output. No secret ever
// touches the server here: the script runs in the operator's own Azure Cloud
// Shell, and the printed values are pasted client-side into the fields.
const entra = { bash: '', powershell: '', shell: 'bash' };

async function entraGenerate() {
  const btn = $('#entraGenBtn');
  const prev = btn.textContent;
  btn.disabled = true; btn.textContent = 'Generating...';
  try {
    const r = await fetch('/setup/api/entra/az-script');
    const data = await r.json();
    if (!r.ok || !data.ok) throw new Error(data.error || 'Failed to generate commands.');
    entra.bash = data.bash || '';
    entra.powershell = data.powershell || '';
    $('#entraRedirect').textContent = data.redirect_uri || '';
    $('#entraScriptBox').hidden = false;
    entraRenderScript();
    btn.textContent = 'Regenerate commands';
  } catch (err) {
    btn.textContent = prev;
    $('#entraFillMsg').textContent = err.message;
  } finally {
    btn.disabled = false;
  }
}

function entraRenderScript() {
  $('#entraScript').textContent = entra[entra.shell] || '';
  $$('.entra-tab').forEach(t => t.classList.toggle('is-active', t.dataset.shell === entra.shell));
}

function entraSwitchTab(btn) {
  entra.shell = btn.dataset.shell === 'powershell' ? 'powershell' : 'bash';
  entraRenderScript();
}

async function entraCopy() {
  const btn = $('#entraCopyBtn');
  try {
    await navigator.clipboard.writeText(entra[entra.shell] || '');
    const prev = btn.textContent; btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = prev; }, 1500);
  } catch {
    // Clipboard API unavailable (e.g. non-secure context): select the text so
    // the operator can Ctrl+C manually.
    const pre = $('#entraScript');
    const range = document.createRange(); range.selectNodeContents(pre);
    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
  }
}

function entraFillFromOutput() {
  const raw = $('#entraOutput').value || '';
  const grab = key => { const m = new RegExp(key + '\\s*=\\s*(.+)').exec(raw); return m ? m[1].trim() : ''; };
  const set = (name, val) => {
    if (!val) return false;
    const el = document.querySelector(`[name="${name}"]`);
    if (!el) return false;
    el.value = val;
    const label = el.closest('label'); // clear any stale validation error
    if (label && label.classList.contains('is-invalid')) { label.classList.remove('is-invalid'); const h = label.querySelector('.validation-msg'); if (h) h.remove(); }
    return true;
  };
  const got = [
    set('entra_tenant_id', grab('TENANT_ID')),
    set('entra_client_id', grab('CLIENT_ID')),
    set('entra_client_secret', grab('CLIENT_SECRET')),
  ].filter(Boolean).length;
  $('#entraFillMsg').textContent =
    got === 3 ? 'Filled tenant id, client id, and client secret below.' :
    got > 0   ? `Filled ${got} of 3. Make sure the output has TENANT_ID=, CLIENT_ID=, and CLIENT_SECRET= lines.` :
                'No values found. Paste the lines the script printed (TENANT_ID=, CLIENT_ID=, CLIENT_SECRET=).';
}

function showError(sel, msg) { const el = $(sel); el.textContent = msg; el.hidden = false; }
function hideError(sel)      { const el = $(sel); el.hidden = true; }

document.addEventListener('click', ev => {
  // Step tabs jump to any step (the token gate is enforced inside gotoStep).
  const stepLi = ev.target.closest('#steps li');
  if (stepLi) return gotoStep(Number(stepLi.dataset.step));

  const btn = ev.target.closest('button');
  if (!btn) return;
  if (btn.id === 'saveButton') return save();
  if (btn.id === 'entraGenBtn') return entraGenerate();
  if (btn.id === 'entraCopyBtn') return entraCopy();
  if (btn.id === 'entraFillBtn') return entraFillFromOutput();
  if (btn.classList.contains('entra-tab')) return entraSwitchTab(btn);
  if (btn.dataset.copy) return copyReadout(btn);
  if (btn.dataset.probe) return probe(btn.dataset.probe);
  if (btn.hasAttribute('data-next')) {
    if (state.step === 0) return verifyToken();
    // Free navigation: never block moving forward. Answers are validated
    // together at Save.
    collectInputs($(`[data-panel="${state.step}"]`));
    showStep(state.step + 1);
    return;
  }
  if (btn.hasAttribute('data-prev')) {
    collectInputs($(`[data-panel="${state.step}"]`));
    showStep(state.step - 1);
    return;
  }
});

// Live-validation: clear an inline error message the moment the
// operator edits the field, so they get feedback without needing to
// re-click Next.
document.addEventListener('input', ev => {
  const el = ev.target.closest('input, select');
  if (!el || (!el.hasAttribute('data-required') && !el.hasAttribute('data-validate'))) return;
  const label = el.closest('label');
  if (label && label.classList.contains('is-invalid')) {
    const hint = label.querySelector('.validation-msg');
    if (hint) hint.remove();
    label.classList.remove('is-invalid');
  }
});

// Initial state probe so we can short-circuit re-entry to the wizard.
fetch('/setup/api/state').then(r => r.json()).then(s => {
  if (!s.in_setup_mode) {
    document.body.innerHTML = '<div class="done"><h1>Setup already complete</h1><p>The wizard does not run after first save. From the admin you can re-enter via <strong>Settings &rarr; Advanced &rarr; Re-enter setup wizard</strong>.</p><p><a href="/admin/">Open the admin UI</a></p></div>';
  }
});

// Step tabs are keyboard-operable; they navigate on click via the delegated
// handler above.
$$('#steps li').forEach(li => { li.setAttribute('role', 'button'); li.tabIndex = 0; });
document.addEventListener('keydown', ev => {
  if (ev.key !== 'Enter' && ev.key !== ' ') return;
  const li = ev.target.closest('#steps li');
  if (!li) return;
  ev.preventDefault();
  gotoStep(Number(li.dataset.step));
});

// --- Targets step: derive the fleet-facing fields from the one DNS name ----
// The operator types their RepoFabric address once; the WinGet source URL, the
// `winget source add` command, and the installer base URL fill in from it. The
// installer field stops auto-filling the moment it is edited by hand.
(function wireTargets() {
  const dns = $('#targetDns');
  if (!dns) return;
  const installer = document.querySelector('[name="installer_base_url"]');
  const roSource = $('#roSource');
  const roCmd = $('#roCmd');
  const autoTag = $('#installerAutoTag');
  let installerEdited = false;

  const parentZone = host => {
    const parts = host.split('.').filter(Boolean);
    return parts.length >= 3 ? parts.slice(1).join('.') : parts.join('.');
  };
  function recompute() {
    const host = dns.value.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
    if (!host) {
      roSource.textContent = 'https://…/api';
      roCmd.textContent = 'winget source add <name> https://…/api';
      return;
    }
    roSource.textContent = `https://${host}/api`;
    const org = parentZone(host).split('.')[0] || 'winget';
    roCmd.textContent = `winget source add ${org} https://${host}/api`;
    if (!installerEdited && installer) {
      installer.value = `https://installers.${parentZone(host)}`;
      if (autoTag) autoTag.hidden = false;
      const label = installer.closest('label');
      if (label && label.classList.contains('is-invalid')) {
        label.classList.remove('is-invalid');
        const h = label.querySelector('.validation-msg'); if (h) h.remove();
      }
    }
  }
  dns.addEventListener('input', recompute);
  if (installer) installer.addEventListener('input', () => { installerEdited = true; if (autoTag) autoTag.hidden = true; });
  recompute();
})();
