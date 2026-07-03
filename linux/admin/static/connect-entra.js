// Connect Microsoft Entra wizard (sandbox post-setup). Talks to
// /admin/api/entra/*. No secret touches the server until /connect: the operator
// runs the generated script in their own Azure Cloud Shell and pastes the three
// printed values here. CSP-safe: external script, no inline handlers, same-origin
// fetches only.

const $ = (id) => document.getElementById(id);
const scripts = { bash: '', powershell: '', shell: 'powershell' };

function escHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function unlock(id) { const el = $(id); if (el) el.classList.remove('is-locked'); }
function markDone(numId) { const el = $(numId); if (el) { el.classList.add('done'); el.textContent = '✓'; } }

// --- Step 1: generate the script -----------------------------------------
async function generate() {
  const btn = $('genBtn');
  const prev = btn.textContent;
  btn.disabled = true; btn.textContent = 'Generating...'; $('genMsg').textContent = '';
  try {
    const r = await fetch('api/entra/az-script', { credentials: 'same-origin' });
    const data = await r.json();
    if (!r.ok || !data.ok) throw new Error(data.error || 'Failed to generate the script.');
    scripts.bash = data.bash || '';
    scripts.powershell = data.powershell || '';
    $('redirectUri').textContent = data.redirect_uri || '';
    $('scriptBox').hidden = false;
    renderScript();
    btn.textContent = 'Regenerate script';
    markDone('num1');
    unlock('step2'); unlock('step3'); unlock('step4');
  } catch (err) {
    btn.textContent = prev;
    $('genMsg').textContent = err.message;
  } finally {
    btn.disabled = false;
  }
}

function renderScript() {
  $('scriptText').textContent = scripts[scripts.shell] || '';
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('is-active', t.dataset.shell === scripts.shell));
}

function switchTab(btn) {
  scripts.shell = btn.dataset.shell === 'powershell' ? 'powershell' : 'bash';
  renderScript();
}

async function copyScript() {
  const btn = $('copyBtn');
  const text = scripts[scripts.shell] || '';
  try {
    await navigator.clipboard.writeText(text);
    const prev = btn.textContent; btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = prev; }, 1500);
  } catch {
    // Clipboard API unavailable (non-secure context): select the text so the
    // operator can Ctrl+C manually.
    const pre = $('scriptText');
    const range = document.createRange(); range.selectNodeContents(pre);
    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
  }
}

// --- Step 3: paste output -> fields --------------------------------------
function fillFromOutput() {
  const raw = $('output').value || '';
  const grab = (key) => { const m = new RegExp(key + '\\s*=\\s*(.+)').exec(raw); return m ? m[1].trim() : ''; };
  const set = (id, val) => { if (!val) return false; $(id).value = val; return true; };
  const got = [
    set('tenant_id', grab('TENANT_ID')),
    set('client_id', grab('CLIENT_ID')),
    set('client_secret', grab('CLIENT_SECRET')),
  ].filter(Boolean).length;
  $('fillMsg').textContent =
    got === 3 ? 'Filled tenant ID, client ID, and client secret below.' :
    got > 0   ? `Filled ${got} of 3. Check the output has TENANT_ID=, CLIENT_ID=, and CLIENT_SECRET= lines.` :
                'No values found. Paste the lines the script printed (TENANT_ID=, CLIENT_ID=, CLIENT_SECRET=).';
}

function creds() {
  return {
    tenant_id: $('tenant_id').value.trim(),
    client_id: $('client_id').value.trim(),
    client_secret: $('client_secret').value.trim(),
  };
}

async function probe() {
  const { tenant_id, client_id, client_secret } = creds();
  const out = $('probe');
  out.className = 'probe show pending';
  out.innerHTML = '<strong>Testing...</strong>';
  if (!tenant_id || !client_id || !client_secret) {
    out.className = 'probe show fail';
    out.innerHTML = '<strong>Fill in all three values first.</strong>';
    return;
  }
  try {
    const r = await fetch('api/entra/probe', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tenant_id, client_id, client_secret }),
    });
    const data = await r.json();
    if (data.ok) {
      out.className = 'probe show ok';
      out.innerHTML = `<strong>Credentials accepted.</strong>
        <ul>
          <li>Tenant: <code>${escHtml(tenant_id)}</code></li>
          <li>Client: <code>${escHtml(client_id)}</code></li>
          ${data.expires_in ? `<li>Access token issued (expires in ${data.expires_in}s)</li>` : ''}
          <li class="muted">Note: this confirms the secret is valid. Admin consent for user/group
            lookups is checked at first sign-in; if it was not granted you will see a 403 there.</li>
        </ul>`;
    } else {
      const detail = data.error ? (typeof data.error === 'string' ? data.error : (data.error.error_description || JSON.stringify(data.error))) : `HTTP ${data.status}`;
      out.className = 'probe show fail';
      out.innerHTML = `<strong>Entra rejected the credentials.</strong>
        <ul><li><code>${escHtml(detail)}</code></li></ul>
        <p class="muted">Re-check you copied the whole CLIENT_SECRET (it can contain symbols) and the right tenant.</p>`;
    }
  } catch (err) {
    out.className = 'probe show fail';
    out.innerHTML = `<strong>Could not reach Entra.</strong> <code>${escHtml(err.message)}</code>`;
  }
}

function parseList(id) {
  return ($(id).value || '').split(',').map(s => s.trim()).filter(Boolean);
}

function refreshOpenAccessWarn() {
  const users = parseList('allowed_users');
  const groups = parseList('allowed_groups');
  $('openAccessWarn').hidden = !(users.length === 0 && groups.length === 0);
}

// --- Step 4: connect ------------------------------------------------------
async function connect() {
  const { tenant_id, client_id, client_secret } = creds();
  const msg = $('connectMsg');
  if (!tenant_id || !client_id || !client_secret) {
    msg.textContent = 'Fill in tenant ID, client ID, and client secret first (Step 3).';
    return;
  }
  const users = parseList('allowed_users');
  const groups = parseList('allowed_groups').map(id => ({ id, display_name: id }));
  if (users.length === 0 && groups.length === 0) {
    if (!confirm('No allowed users or groups set.\n\nAnyone in your tenant will be able to sign in as admin. Continue anyway?')) return;
  }
  const btn = $('connectBtn');
  btn.disabled = true; btn.textContent = 'Connecting...'; msg.textContent = '';
  try {
    const r = await fetch('api/entra/connect', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tenant_id, client_id, client_secret, allowed_users: users, allowed_groups: groups }),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok || !data.ok) {
      // The server fails closed: a 422 means Entra rejected the credentials, a
      // 409 means solution.yaml is unreadable, a 502 means Entra was unreachable.
      // Nothing was changed in any of those cases.
      const detail = data.detail ? ` (${data.detail})` : '';
      throw new Error((data.error || `Connect failed (HTTP ${r.status}).`) + detail);
    }
    showDone();
  } catch (err) {
    btn.disabled = false; btn.textContent = 'Connect Microsoft Entra & restart';
    msg.textContent = err.message;
  }
}

function showDone() {
  $('wrap').innerHTML = `
    <div class="done-card">
      <h1>Microsoft Entra connected</h1>
      <p>Credentials were validated and saved. The admin service is restarting; sign-in is now Microsoft Entra.</p>
      <p class="muted">Your local admin account stays available as a break-glass fallback at <code class="inline">/admin/auth/local-login</code>.</p>
      <p id="redir" class="muted">Waiting for the service to come back (<span id="cd">0</span>s)...</p>
      <p><a class="btn" href="/admin/auth/login">Go to sign-in now</a></p>
    </div>`;
  // Don't navigate on a blind timer: node-admin is mid-restart and the proxy
  // returns 502 during the down window. Poll the unauthenticated health endpoint
  // and only navigate once it answers, with a hard cap so we never hang forever.
  let waited = 0;
  const go = () => { window.location.href = '/admin/auth/login'; };
  const poll = setInterval(async () => {
    waited += 2;
    const cd = $('cd'); if (cd) cd.textContent = String(waited);
    try {
      const r = await fetch('/admin/healthz', { cache: 'no-store' });
      if (r.ok) { clearInterval(poll); go(); return; }
    } catch { /* still restarting; keep polling */ }
    if (waited >= 40) { clearInterval(poll); go(); }
  }, 2000);
}

// --- wiring ---------------------------------------------------------------
document.addEventListener('click', (ev) => {
  const btn = ev.target.closest('button, a.btn');
  if (!btn) return;
  if (btn.id === 'genBtn') return generate();
  if (btn.id === 'copyBtn') return copyScript();
  if (btn.id === 'fillBtn') return fillFromOutput();
  if (btn.id === 'probeBtn') return probe();
  if (btn.id === 'connectBtn') return connect();
  if (btn.classList.contains('tab')) return switchTab(btn);
});

document.addEventListener('input', (ev) => {
  if (ev.target.id === 'allowed_users' || ev.target.id === 'allowed_groups') refreshOpenAccessWarn();
});

// Initial status: surface the "already connected" note and bail out cleanly if
// the page is somehow opened on a non-sandbox deployment.
fetch('api/entra/status', { credentials: 'same-origin' })
  .then(r => r.ok ? r.json() : { sandbox: false })
  .then(s => {
    if (!s) return;
    if (!s.sandbox) {
      document.getElementById('wrap').innerHTML =
        '<div class="done-card"><h1>Not available</h1><p>This deployment already runs on Microsoft Entra. The Connect Entra wizard is only for sandbox (local-admin) deployments.</p><p><a class="btn" href="/admin/">Back to admin</a></p></div>';
      return;
    }
    if (s.entra_configured) $('already').hidden = false;
  })
  .catch(() => { /* leave the page in its default first-connect state */ });
