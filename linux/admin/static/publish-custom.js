// Publish-custom wizard, single-page version. RingoSystems Heavy Industries UNRAID-local fork.
// Flow:
//   1. Operator drops or picks an installer file (top of page).
//   2. We upload, server returns {upload_id, path, sha256, size_bytes}.
//   3. We hit /api/custom/inspect with the staged path and apply
//      heuristics (InstallerType, Architecture, default switches, MSI
//      ProductCode, Appx identity, top-level Publisher/PackageName/etc)
//      to whichever installer card is associated with the upload, plus
//      the top-level Identity + Default Locale fields when those are empty.
//   4. Live validation runs on every input: per-field indicator (ok/warn/error)
//      bubbles up to a per-section pill which bubbles up to the overall pill.
//      Publish button enables only when no required fields are in error.

const API = '/admin/api';
const SCHEMA_VERSION = '1.6.0';

function $(s, r = document)  { return r.querySelector(s); }
function $$(s, r = document) { return Array.from(r.querySelectorAll(s)); }

const uploadedFiles = []; // { upload_id, path, sha256, size_bytes, original_name }

// Edit mode is entered via ?edit=<customId>. When non-null, the wizard
// hides the upload section, prefills every field from the existing
// manifest, locks PackageIdentifier + PackageVersion (changing either
// would orphan the existing repo path on Gitea + nginx), and PUTs to
// /api/custom/<id> on Save instead of POSTing to /api/custom/publish.
const editMode = { active: false, customId: null };

// ===== installer + locale card factories ================================

function addInstaller() {
  const tpl = $('#installerTemplate');
  const card = tpl.content.firstElementChild.cloneNode(true);
  $('#installers').append(card);
  card.querySelector('.installer-remove').addEventListener('click', () => {
    card.remove();
    recomputeAll();
  });
  // Field-change drives re-validation.
  card.addEventListener('input',  () => recomputeAll());
  card.addEventListener('change', () => recomputeAll());
  recomputeAll();
  return card;
}

function addLocale() {
  const tpl = $('#localeTemplate');
  const card = tpl.content.firstElementChild.cloneNode(true);
  $('#locales').append(card);
  card.querySelector('.locale-remove').addEventListener('click', () => {
    card.remove();
    recomputeAll();
  });
  card.addEventListener('input',  () => recomputeAll());
  card.addEventListener('change', () => recomputeAll());
  recomputeAll();
}

// ===== upload =============================================================

async function handleFile(file) {
  if (!file) return;
  const dropEl = $('#drop');
  const dropText = $('#drop-text');
  const summary = $('#drop-summary');
  const counter = $('#counter-upload');

  dropEl.classList.add('has-file');
  dropText.textContent = `Uploading ${file.name} (${(file.size/1048576).toFixed(1)} MiB)...`;
  setPill('#pill-upload', 'warn');
  counter.textContent = 'uploading...';

  const fd = new FormData();
  fd.append('installer', file);
  try {
    const r = await fetch(`${API}/custom/upload`, { method: 'POST', body: fd });
    if (!r.ok) throw new Error(await r.text());
    const body = await r.json();
    body.original_name = file.name;
    uploadedFiles.push(body);

    // Bind the upload to an installer card. Reuse the first card if it's
    // unbound (no upload yet); otherwise create a fresh card so a second
    // drop is interpreted as adding another architecture/scope entry.
    let card = $$('#installers .pc-installer-card').find(c => !c.dataset.uploadId);
    if (!card) card = addInstaller();
    card.dataset.uploadId = body.upload_id;
    card.dataset.sha256 = body.sha256;
    card.dataset.uploadPath = body.path;
    card.dataset.uploadSize = body.size_bytes;
    card.dataset.originalName = file.name;

    dropText.textContent = `Uploaded ${file.name}`;
    summary.hidden = false;
    summary.innerHTML = `<code>sha256:${body.sha256.slice(0,12)}...</code> <code>${(body.size_bytes/1048576).toFixed(1)} MiB</code> <span class="muted">inspecting...</span>`;

    // Inspect for heuristics.
    try {
      const meta = await (await fetch(`${API}/custom/inspect`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ LocalPath: body.path, OriginalName: file.name })
      })).json();
      if (meta && !meta.error) {
        renderPrefixHint(meta.PackageIdentifierPrefix);
        applyInstallerDefaults(card, meta);
        const tags = [meta.InstallerType, meta.Architecture].filter(Boolean).join(' / ');
        summary.innerHTML = `<code>sha256:${body.sha256.slice(0,12)}...</code> <code>${(body.size_bytes/1048576).toFixed(1)} MiB</code> <code>${tags || 'inspected'}</code>`;
        setPill('#pill-upload', 'ok');
        counter.textContent = tags || 'uploaded';
        // Synchronous upstream-hash collision check ran on the bridge
        // during inspect. Render the banner now (red + override) when
        // matches were found; otherwise no banner. The weekly cron job
        // Update-RfCustomPackageCollisions re-runs this for every
        // already-published custom package and the results surface in
        // the combined Subscriptions tab Custom apps row.
        renderCollisionBanner(card, meta.KnownUpstreamMatches || []);
      } else {
        summary.innerHTML += ' <span class="muted">(inspect failed; fill manually)</span>';
        setPill('#pill-upload', 'warn');
        counter.textContent = 'inspect failed';
      }
    } catch (err) {
      console.warn('inspect failed', err);
      summary.innerHTML += ` <span class="muted">(inspect: ${err.message})</span>`;
      setPill('#pill-upload', 'warn');
      counter.textContent = 'inspect failed';
    }
    recomputeAll();
  } catch (err) {
    dropText.textContent = `Upload failed: ${err.message}`;
    setPill('#pill-upload', 'error');
    counter.textContent = 'failed';
    dropEl.classList.remove('has-file');
  }
}

function applyInstallerDefaults(card, meta) {
  const setEmpty = (selector, value) => {
    if (value === null || value === undefined || value === '') return;
    const el = card.querySelector(selector);
    if (!el || el.value) return;
    el.value = (typeof value === 'object' ? JSON.stringify(value) : String(value));
  };
  setEmpty('select[name="InstallerType"]', meta.InstallerType);
  setEmpty('select[name="Architecture"]',  meta.Architecture);
  setEmpty('select[name="Scope"]',         meta.Scope);

  const sw = meta.DefaultSwitches || {};
  setEmpty('input[name="sw_Silent"]',             sw.Silent);
  setEmpty('input[name="sw_SilentWithProgress"]', sw.SilentWithProgress);
  setEmpty('input[name="sw_Log"]',                sw.Log);
  setEmpty('input[name="sw_InstallLocation"]',    sw.InstallLocation);

  if (Array.isArray(meta.DefaultInstallModes) && meta.DefaultInstallModes.length) {
    setEmpty('input[name="InstallModes"]', meta.DefaultInstallModes.join(','));
  }
  if (Array.isArray(meta.DefaultExpectedReturnCodes) && meta.DefaultExpectedReturnCodes.length) {
    setEmpty('textarea[name="ExpectedReturnCodes"]', meta.DefaultExpectedReturnCodes);
  }

  const msi = meta.MsiMetadata;
  if (msi) {
    setEmpty('input[name="ProductCode"]', msi.ProductCode);
    setEmpty('input[name="UpgradeCode"]', msi.UpgradeCode);
    fillTopIfEmpty('#PackageVersion',     msi.ProductVersion);
    fillTopIfEmpty('#DefaultLocale',      msi.PackageLocale);
    fillTopIfEmpty('#loc_Publisher',      msi.Manufacturer);
    fillTopIfEmpty('#loc_PackageName',    msi.ProductName);
    // Comments field on the MSI Summary Information stream is the closest
    // analog to a one-line description (see screenshot from operator: the
    // "Comments" detail tab field). Falls through silently when absent.
    fillTopIfEmpty('#loc_ShortDescription', msi.Comments);
    // PackageIdentifier is <configured-prefix>.<Subject-without-spaces>.
    // Falls back to Manufacturer/ProductName when either piece is missing.
    buildPackageIdentifier(meta.PackageIdentifierPrefix, msi.Subject, msi.Manufacturer, msi.ProductName);
    const ae = card.querySelector('textarea[name="AppsAndFeaturesEntries"]');
    if (ae && !ae.value) {
      ae.value = JSON.stringify([{
        ProductCode:   msi.ProductCode,
        UpgradeCode:   msi.UpgradeCode,
        DisplayVersion:msi.ProductVersion,
        DisplayName:   msi.ProductName,
        Publisher:     msi.Manufacturer,
        InstallerType: meta.InstallerType
      }]);
    }
  }
  const appx = meta.AppxIdentity;
  if (appx) {
    setEmpty('input[name="PackageFamilyName"]', appx.PackageFamilyName);
    fillTopIfEmpty('#PackageVersion', appx.ProductVersion);
    fillTopIfEmpty('#loc_Publisher',  appx.Publisher);
    fillTopIfEmpty('#loc_PackageName',appx.ProductName);
    buildPackageIdentifier(meta.PackageIdentifierPrefix, appx.ProductName, appx.Publisher, appx.ProductName);
  }
  const exe = meta.ExeVersionInfo;
  if (exe) {
    // PE VS_VERSIONINFO -> wizard. FileDescription is the closest analog
    // to MSI Summary "Subject" (one-line app description) so it drives
    // both PackageName fallback and PackageIdentifier remainder.
    fillTopIfEmpty('#PackageVersion',       exe.ProductVersion || exe.FileVersion);
    fillTopIfEmpty('#loc_Publisher',        exe.CompanyName);
    fillTopIfEmpty('#loc_PackageName',      exe.ProductName || exe.FileDescription);
    fillTopIfEmpty('#loc_ShortDescription', exe.Comments || exe.FileDescription);
    fillTopIfEmpty('#loc_Copyright',        exe.LegalCopyright);
    buildPackageIdentifier(meta.PackageIdentifierPrefix, exe.FileDescription, exe.CompanyName, exe.ProductName);
  }
}

// Render the upstream-hash collision banner on an installer card.
// matches is an array of {PackageId, Version, ManifestPath}. When the
// array is non-empty, the card cannot be published unless the operator
// checks the override box. Empty array clears any prior banner.
function renderCollisionBanner(card, matches) {
  // PowerShell ConvertTo-Json unwraps a single-element array into the
  // bare element. When the upstream-hash check returns exactly one
  // match (very common for popular vendor MSIs that ARE in upstream),
  // KnownUpstreamMatches lands here as an object, not an array. Wrap
  // it so the .slice / .length calls below stay correct. The
  // server-side fix in Find-RfUpstreamHashMatches uses the comma
  // operator to prevent unwrapping; this defensive normalization is
  // for older bridge builds and for clean code hygiene.
  if (matches && typeof matches === 'object' && !Array.isArray(matches)) {
    matches = [matches];
  }
  if (!Array.isArray(matches)) matches = [];
  card.querySelectorAll('.collision-banner').forEach(el => el.remove());
  card.dataset.collisionMatches = '';
  card.dataset.collisionOverride = '0';
  if (matches.length === 0) { recomputeAll(); return; }
  card.dataset.collisionMatches = JSON.stringify(matches);
  const top  = matches.slice(0, 3).map(m => `<code>${m.PackageId}@${m.Version}</code>`).join(', ');
  const more = matches.length > 3 ? ` (and ${matches.length - 3} more)` : '';
  const banner = document.createElement('div');
  banner.className = 'collision-banner';
  banner.innerHTML = `
    <strong>This binary is already in the public WinGet repo.</strong>
    Matched: ${top}${more}.
    <br>A managed subscription is almost always the right move here.
    <label class="collision-override">
      <input type="checkbox" data-collision-override>
      I understand. Publish this binary as a custom package anyway.
    </label>`;
  card.prepend(banner);
  banner.querySelector('input[data-collision-override]').addEventListener('change', ev => {
    card.dataset.collisionOverride = ev.target.checked ? '1' : '0';
    recomputeAll();
  });
  recomputeAll();
}

// Update the small "Prefix: <X>" breadcrumb under the PackageIdentifier
// field so the operator knows what the wizard will prepend before they
// even drop a file. Called on page load AND after every inspect
// response (the latter is authoritative because inspect reads
// service.yaml fresh on each request).
function renderPrefixHint(prefix) {
  const el = document.getElementById('pc-prefix-hint');
  if (!el) return;
  const v = (prefix || '').trim();
  el.textContent = v || '(unset, falls back to Publisher)';
}

function fillTopIfEmpty(sel, value) {
  if (!value) return;
  const el = $(sel);
  if (el && !el.value) el.value = String(value);
}
// Build PackageIdentifier as "<prefix>.<remainder>". Prefix comes from
// service.yaml custom_publish.package_identifier_prefix (operator-set,
// e.g. "RingoSystems"); remainder is the MSI Summary Subject with spaces
// stripped (and any other regex-unsafe characters dropped). When the
// prefix is unset OR the Subject is missing, we fall back to the
// publisher/product-name pair so a binary without summary metadata
// still gets a usable identifier.
function buildPackageIdentifier(prefix, subject, fallbackPublisher, fallbackName) {
  const el = $('#PackageIdentifier');
  if (!el || el.value) return;
  const sanitize = (s) => String(s || '').replace(/\s+/g, '').replace(/[^A-Za-z0-9._-]/g, '');
  const left  = sanitize(prefix) || sanitize(fallbackPublisher);
  const right = sanitize(subject) || sanitize(fallbackName);
  if (left && right) el.value = `${left}.${right}`;
}

// ===== validation engine ==================================================

// Per-element rule check. Returns 'ok' | 'warn' | 'error'. 'warn' fires
// when the field is optional but recommended (URL fields look unset).
function checkField(el) {
  const v = (el.value || '').trim();
  const isRequired = el.hasAttribute('data-required');
  const pattern = el.getAttribute('data-pattern');
  const min     = parseInt(el.getAttribute('data-min') || '0', 10);
  const warnOn  = el.getAttribute('data-warn-on');
  if (!v) return isRequired ? 'error' : 'ok';
  if (pattern && !new RegExp(pattern).test(v)) return 'error';
  if (min > 0 && v.length < min) return 'error';
  if (el.type === 'url') {
    try { new URL(v); } catch { return 'error'; }
  }
  // data-warn-on lets a field be permissible-but-flagged on a sentinel
  // value. Used by the License field where "Undefined" is allowed but
  // should surface a yellow indicator rather than the green check.
  if (warnOn && v === warnOn) return 'warn';
  return 'ok';
}

function setIndicator(el, state) {
  // Find the sibling indicator span.
  const lbl = el.closest('label');
  if (!lbl) return;
  const ind = lbl.querySelector('.ind');
  if (!ind) return;
  ind.classList.remove('ok','warn','error');
  if (state === 'ok')    { ind.classList.add('ok');    ind.textContent = '✓'; }
  else if (state === 'warn')  { ind.classList.add('warn');  ind.textContent = '!'; }
  else if (state === 'error') { ind.classList.add('error'); ind.textContent = '✗'; }
  else                        { ind.textContent = ''; }
}

function setPill(sel, state) {
  const el = $(sel);
  if (!el) return;
  el.classList.remove('ok','warn','error');
  if (state) el.classList.add(state);
}

function recomputeAll() {
  // Identity section.
  const idEls = ['#PackageIdentifier', '#PackageVersion', '#DefaultLocale'].map(s => $(s));
  let idWorst = 'ok';
  let idMissing = 0;
  idEls.forEach(el => {
    const s = checkField(el);
    setIndicator(el, s);
    if (s === 'error') { idWorst = 'error'; idMissing++; }
    else if (s === 'warn' && idWorst !== 'error') idWorst = 'warn';
  });
  setPill('#pill-identity', idWorst);
  $('#counter-identity').textContent = idMissing ? `${idMissing} required missing` : 'ok';

  // Default locale section. License is intentionally NOT in locReq: an
  // operator can ship with License="Undefined" (warn) when the binary
  // has no declared license. checkField surfaces that as warn so the
  // section pill goes yellow but publish stays enabled.
  const locReq = ['#loc_Publisher', '#loc_PackageName', '#loc_ShortDescription'].map(s => $(s));
  const locWarnable = [$('#loc_License')];
  const locOpt = $$('#loc_PublisherUrl,#loc_PublisherSupportUrl,#loc_PrivacyUrl,#loc_PackageUrl,#loc_LicenseUrl,#loc_CopyrightUrl,#loc_ReleaseNotesUrl,#loc_Description,#loc_Tags');
  let locWorst = 'ok';
  let locMissing = 0;
  locReq.forEach(el => {
    const s = checkField(el);
    setIndicator(el, s);
    if (s === 'error') { locWorst = 'error'; locMissing++; }
    else if (s === 'warn' && locWorst !== 'error') locWorst = 'warn';
  });
  locWarnable.forEach(el => {
    if (!el) return;
    const s = checkField(el);
    setIndicator(el, s);
    if (s === 'warn' && locWorst !== 'error') locWorst = 'warn';
  });
  locOpt.forEach(el => setIndicator(el, checkField(el)));
  setPill('#pill-locale', locWorst);
  $('#counter-locale').textContent = locMissing ? `${locMissing} required missing` : (locWorst === 'warn' ? 'review yellow' : 'ok');

  // Installer cards section.
  const cards = $$('#installers .pc-installer-card');
  let instWorst = cards.length ? 'ok' : 'error';
  let instSummary = [];
  cards.forEach(card => {
    const fields = $$('input, select, textarea', card).filter(el => el.name);
    let cardWorst = 'ok';
    let cardErrors = 0;
    fields.forEach(el => {
      const s = checkField(el);
      setIndicator(el, s);
      if (s === 'error') { cardWorst = 'error'; cardErrors++; }
      else if (s === 'warn' && cardWorst !== 'error') cardWorst = 'warn';
    });
    // A card is also in error if no installer file is bound.
    if (!card.dataset.uploadId) { cardWorst = 'error'; cardErrors++; }
    // Upstream hash collision blocks publish unless the operator
    // ticks the override on the collision banner.
    if (card.dataset.collisionMatches && card.dataset.collisionOverride !== '1') {
      cardWorst = 'error'; cardErrors++;
    }
    const pill = card.querySelector('[data-card-pill]');
    if (pill) { pill.classList.remove('ok','warn','error'); pill.classList.add(cardWorst); }
    const tag = card.querySelector('[data-card-tag]');
    if (tag) {
      const arch = card.querySelector('select[name="Architecture"]')?.value || '?';
      const itype = card.querySelector('select[name="InstallerType"]')?.value || '?';
      const bytes = Number(card.dataset.uploadSize || 0);
      tag.textContent = card.dataset.uploadId
        ? `${itype}/${arch}, ${(bytes/1048576).toFixed(1)} MiB`
        : 'no file yet';
    }
    if (cardWorst === 'error' && instWorst !== 'error') instWorst = 'error';
    instSummary.push(cardErrors === 0 ? '✓' : `${cardErrors}✗`);
  });
  setPill('#pill-installers', instWorst);
  $('#counter-installers').textContent = cards.length ? `${cards.length} installer(s) [${instSummary.join(', ')}]` : 'add an installer (upload a file above)';

  // Additional locales (optional).
  const locCards = $$('#locales .pc-locale-card');
  let locCardsWorst = 'ok';
  locCards.forEach(card => {
    const fields = $$('input, textarea', card).filter(el => el.name);
    let cardWorst = 'ok';
    fields.forEach(el => {
      const s = checkField(el);
      setIndicator(el, s);
      if (s === 'error') cardWorst = 'error';
    });
    const pill = card.querySelector('[data-card-pill]');
    if (pill) { pill.classList.remove('ok','warn','error'); pill.classList.add(cardWorst); }
    const tag = card.querySelector('[data-card-tag]');
    if (tag) tag.textContent = card.querySelector('input[name="PackageLocale"]')?.value || '(no locale)';
    if (cardWorst === 'error') locCardsWorst = 'error';
  });
  setPill('#pill-locales', locCards.length ? locCardsWorst : 'ok');
  $('#counter-locales').textContent = locCards.length ? `${locCards.length} extra locale(s)` : 'none';

  // Overall + publish button.
  const worst = [idWorst, locWorst, instWorst, locCardsWorst].includes('error') ? 'error'
              : [idWorst, locWorst, instWorst, locCardsWorst].includes('warn')  ? 'warn'
              : 'ok';
  setPill('#pill-overall', worst);
  $('#counter-overall').textContent = worst === 'ok' ? 'ready to publish' : worst === 'warn' ? 'check yellow' : 'fix red';
  $('#publishBtn').disabled = (worst === 'error');
  $('#publishHint').textContent = worst === 'error'
    ? 'Fill the red required fields before publishing.'
    : worst === 'warn'
      ? 'Yellow recommendations are still publishable; review and proceed when ready.'
      : 'All required fields ok. Hit Publish.';
}

// ===== payload + publish + validate =====================================

function buildPayload() {
  const PackageIdentifier = $('#PackageIdentifier').value.trim();
  const PackageVersion    = $('#PackageVersion').value.trim();
  const DefaultLocale     = $('#DefaultLocale').value.trim() || 'en-US';

  const version = { PackageIdentifier, PackageVersion, DefaultLocale, ManifestType: 'version', ManifestVersion: SCHEMA_VERSION };

  const defaultLocale = {
    PackageIdentifier, PackageVersion, PackageLocale: DefaultLocale,
    ManifestType: 'defaultLocale', ManifestVersion: SCHEMA_VERSION,
    Publisher:        $('#loc_Publisher').value.trim(),
    PackageName:      $('#loc_PackageName').value.trim(),
    License:          $('#loc_License').value.trim(),
    ShortDescription: $('#loc_ShortDescription').value.trim(),
  };
  setIfFilled(defaultLocale, 'PublisherUrl',        $('#loc_PublisherUrl').value);
  setIfFilled(defaultLocale, 'PublisherSupportUrl', $('#loc_PublisherSupportUrl').value);
  setIfFilled(defaultLocale, 'PrivacyUrl',          $('#loc_PrivacyUrl').value);
  setIfFilled(defaultLocale, 'Author',              $('#loc_Author').value);
  setIfFilled(defaultLocale, 'PackageUrl',          $('#loc_PackageUrl').value);
  setIfFilled(defaultLocale, 'LicenseUrl',          $('#loc_LicenseUrl').value);
  setIfFilled(defaultLocale, 'Copyright',           $('#loc_Copyright').value);
  setIfFilled(defaultLocale, 'CopyrightUrl',        $('#loc_CopyrightUrl').value);
  setIfFilled(defaultLocale, 'Description',         $('#loc_Description').value);
  setIfFilled(defaultLocale, 'Moniker',             $('#loc_Moniker').value);
  setIfFilled(defaultLocale, 'ReleaseNotesUrl',     $('#loc_ReleaseNotesUrl').value);
  setIfFilled(defaultLocale, 'ReleaseNotes',        $('#loc_ReleaseNotes').value);
  setIfFilled(defaultLocale, 'InstallationNotes',   $('#loc_InstallationNotes').value);
  if ($('#loc_Tags').value.trim()) {
    defaultLocale.Tags = $('#loc_Tags').value.split(',').map(s => s.trim()).filter(Boolean);
  }

  const Installers = $$('#installers .pc-installer-card').map(buildInstallerEntry);
  const installer = { PackageIdentifier, PackageVersion, ManifestType: 'installer', ManifestVersion: SCHEMA_VERSION, Installers };

  const locales = $$('#locales .pc-locale-card').map(card => {
    const e = { PackageIdentifier, PackageVersion, ManifestType: 'locale', ManifestVersion: SCHEMA_VERSION };
    for (const inp of $$('input, textarea', card)) {
      const n = inp.name; if (!n) continue;
      const v = (inp.value || '').trim(); if (!v) continue;
      e[n] = v;
    }
    return e;
  });

  return { version, installer, defaultLocale, locales };
}

function buildInstallerEntry(card) {
  const e = {};
  for (const inp of $$('input, select, textarea', card)) {
    if (inp.type === 'file') continue;
    const n = inp.name; if (!n) continue;
    const v = (inp.value || '').trim();
    if (!v) continue;
    if (n === 'InstallerSuccessCodes') {
      e.InstallerSuccessCodes = v.split(',').map(s => Number(s.trim())).filter(Number.isFinite);
    } else if (n === 'ExpectedReturnCodes' || n === 'AppsAndFeaturesEntries' || n === 'NestedInstallerFiles' || n === 'Markets') {
      try { e[n] = JSON.parse(v); } catch { /* leave field unset rather than emit broken JSON */ }
    } else if (n === 'InstallModes' || n === 'Platform' || n === 'Commands' || n === 'Protocols' || n === 'FileExtensions' || n === 'UnsupportedArguments' || n === 'UnsupportedOSArchitectures') {
      e[n] = v.split(',').map(s => s.trim()).filter(Boolean);
    } else if (n.startsWith('sw_')) {
      e.InstallerSwitches = e.InstallerSwitches || {};
      e.InstallerSwitches[n.slice(3)] = v;
    } else {
      e[n] = v;
    }
  }
  if (card.dataset.sha256) e.InstallerSha256 = card.dataset.sha256;
  // Edit mode: re-use the InstallerUrl the previous publish stamped
  // (binary is unchanged on the nginx host). New-publish mode: use
  // a schema-valid placeholder that Format-RfCustomManifest rewrites
  // to <installer_base_url>/<pkg>/<ver>/<file> during the publish step.
  if (editMode.active && card.dataset.installerUrl) {
    e.InstallerUrl = card.dataset.installerUrl;
  } else {
    e.InstallerUrl = 'https://installer-url-rewritten-on-publish.invalid/file';
  }
  return e;
}

function setIfFilled(obj, key, value) { if (value && value.trim()) obj[key] = value.trim(); }

async function runValidate() {
  const out = $('#validateOutput');
  out.hidden = false;
  out.textContent = 'validating...';
  try {
    const r = await fetch(`${API}/custom/validate`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(buildPayload())
    });
    const body = await r.json();
    out.textContent = JSON.stringify(body, null, 2);
  } catch (err) {
    out.textContent = `validate error: ${err.message}`;
  }
}

async function runPublish() {
  const out = $('#validateOutput');
  const status = $('#publishStatus');
  status.hidden = false;
  status.className = 'pc-publish-status pending';
  status.innerHTML = editMode.active
    ? '<strong>Saving changes...</strong> Re-rendering YAML, committing to Gitea, refreshing the local catalog.'
    : '<strong>Publishing...</strong> Uploading installer, committing manifests to Gitea, updating the local catalog. This usually takes 5-30 seconds.';
  out.hidden = true;
  $('#publishBtn').disabled = true;
  try {
    const manifest = buildPayload();
    let r;
    if (editMode.active && editMode.customId) {
      // Edit existing custom: full manifest body to PUT /api/custom/<id>.
      // No installer uploads -- binary is unchanged.
      r = await fetch(`${API}/custom/${editMode.customId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ Manifest: manifest })
      });
    } else {
      const installerUploads = $$('#installers .pc-installer-card').map((card, idx) => ({
        LocalPath:      card.dataset.uploadPath,
        OriginalName:   card.dataset.originalName,
        Sha256:         card.dataset.sha256,
        SizeBytes:      Number(card.dataset.uploadSize),
        InstallerIndex: idx
      }));
      r = await fetch(`${API}/custom/publish`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ Manifest: manifest, InstallerUploads: installerUploads })
      });
    }
    const body = await r.json();
    if (!r.ok) throw new Error(body.error || r.statusText);
    // Success: structured status card with the row id, repo path, and a
    // one-click path back to the admin tab where the new row will appear.
    const pid    = body.PackageId    || manifest.version.PackageIdentifier;
    const ver    = body.Version      || manifest.version.PackageVersion;
    const cid    = body.CustomId     ? `#${body.CustomId}` : '';
    const repo   = body.RepoPath     || '(unknown)';
    const commit = body.GitCommitSha ? body.GitCommitSha.slice(0,12) : '(unknown)';
    const files  = (body.UploadedFiles && body.UploadedFiles.length)
      ? `<li>Installers uploaded: <code>${body.UploadedFiles.map(f => f.split('/').pop()).join('</code>, <code>')}</code></li>`
      : '';
    status.className = 'pc-publish-status ok';
    const headline = editMode.active ? 'Changes saved.' : 'Published successfully.';
    const followup = editMode.active
      ? 'The updated manifest will appear on the Subscriptions tab under <em>Operator-added custom apps</em>. Endpoints re-resolve on their next source refresh.'
      : 'The package will appear on the Subscriptions tab under <em>Operator-added custom apps</em>.';
    status.innerHTML = `
      <strong>${headline}</strong>
      <ul>
        <li>Package: <code>${escapeHtml(pid)}</code> @ <code>${escapeHtml(ver)}</code> ${cid}</li>
        <li>Repo path: <code>${escapeHtml(repo)}</code></li>
        <li>Git commit: <code>${escapeHtml(commit)}</code></li>
        ${files}
      </ul>
      <p>${followup}</p>
      <a class="pc-publish-cta" href="./">Back to admin (refreshes the list)</a>`;
    // Lock the form so the operator does not accidentally re-publish the
    // same upload (which would also collide on the SHA already-published
    // check) and so it is obvious the wizard is done.
    $('#publishBtn').disabled = true;
    $('#validateBtn').disabled = true;
  } catch (err) {
    status.className = 'pc-publish-status err';
    status.innerHTML = `
      <strong>Publish failed.</strong>
      <p><code>${escapeHtml(err.message)}</code></p>
      <p>Common causes: Gitea PAT expired, schema mismatch on a recently-renamed field. Hit Run server-side validate to see whether the manifest itself is the problem before retrying.</p>`;
    $('#publishBtn').disabled = false;
  }
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// ===== drop zone wiring + bootstrap ======================================

document.addEventListener('DOMContentLoaded', () => {
  const drop = $('#drop');
  const fileEl = $('#installerFile');
  drop.addEventListener('click', () => fileEl.click());
  fileEl.addEventListener('change', ev => { if (ev.target.files[0]) handleFile(ev.target.files[0]); });
  ['dragenter','dragover'].forEach(e => drop.addEventListener(e, ev => { ev.preventDefault(); drop.classList.add('over'); }));
  ['dragleave','drop'].forEach(e => drop.addEventListener(e, ev => { ev.preventDefault(); drop.classList.remove('over'); }));
  drop.addEventListener('drop', ev => { if (ev.dataTransfer.files[0]) handleFile(ev.dataTransfer.files[0]); });

  $('#addInstaller').addEventListener('click', addInstaller);
  $('#addLocale').addEventListener('click', addLocale);
  $('#validateBtn').addEventListener('click', runValidate);
  $('#publishBtn').addEventListener('click', runPublish);

  // Live re-eval on any top-level input change.
  document.addEventListener('input',  ev => { if (ev.target.closest('.pc-section')) recomputeAll(); });
  document.addEventListener('change', ev => { if (ev.target.closest('.pc-section')) recomputeAll(); });

  // Branch on ?edit=<customId>: edit mode preloads the form from an
  // existing custom package and skips the upload step entirely.
  const editCid = new URLSearchParams(window.location.search).get('edit');
  if (editCid && /^\d+$/.test(editCid)) {
    enterEditMode(parseInt(editCid, 10));
  } else {
    // New-publish flow: start with one empty installer card so the user
    // sees the shape, plus the prefix-hint warmup.
    addInstaller();
    recomputeAll();
    fetch(`${API}/config`).then(r => r.ok ? r.json() : null).then(cfg => {
      renderPrefixHint(cfg?.custom_publish?.package_identifier_prefix);
    }).catch(() => renderPrefixHint(''));
  }
});

// ===== edit mode ==========================================================

async function enterEditMode(customId) {
  editMode.active = true;
  editMode.customId = customId;

  // Visual + semantic switch BEFORE the fetch so the operator sees the
  // page is loading something specific, not a fresh publish.
  document.title = `Edit custom app, RingoSystems Heavy Industries`;
  const h1 = document.querySelector('header h1');
  if (h1) h1.textContent = 'Edit custom app';
  const sub = document.querySelector('header p.muted');
  if (sub) sub.innerHTML = `Editing an existing custom package. Installer binary is preserved; everything else is editable. <a href="./">back to admin</a>`;
  // The Installer file drop section is irrelevant in edit mode -- the
  // binary already lives on the nginx host and we re-use its SHA + URL
  // from the existing manifest. Collapse it out of the way.
  const dropSection = document.getElementById('drop')?.closest('.pc-section');
  if (dropSection) dropSection.hidden = true;
  // Rename the publish CTA so the action is unambiguous.
  const publishBtn = $('#publishBtn');
  if (publishBtn) publishBtn.textContent = 'Save changes';
  $('#publishHint').textContent = 'Editing existing manifest. Saving re-pushes YAML to Gitea; installer is unchanged.';

  try {
    const row = await fetch(`${API}/custom/${customId}`, { headers: { Accept: 'application/json' } })
      .then(r => { if (!r.ok) throw new Error(`fetch /custom/${customId} returned ${r.status}`); return r.json(); });
    populateFromManifest(row);
    recomputeAll();
  } catch (err) {
    const status = $('#publishStatus');
    status.hidden = false;
    status.className = 'pc-publish-status err';
    status.innerHTML = `<strong>Edit-mode load failed.</strong><p><code>${escapeHtml(err.message)}</code></p>`;
  }
}

function populateFromManifest(row) {
  if (!row || !row.Manifest) {
    throw new Error('Server did not return a parsed Manifest for this custom package.');
  }
  const m = row.Manifest;

  // ---- Version manifest (Identity card) ----
  setVal('#PackageIdentifier', m.version?.PackageIdentifier);
  setVal('#PackageVersion',    m.version?.PackageVersion);
  setVal('#DefaultLocale',     m.version?.DefaultLocale || 'en-US');
  // PackageIdentifier + PackageVersion are immutable in edit mode -- the
  // repo path manifests/<letter>/<vendor>/<package>/<version>/ and the
  // installer URL are both derived from these. Lock both.
  ['#PackageIdentifier', '#PackageVersion'].forEach(sel => {
    const el = $(sel);
    if (el) { el.readOnly = true; el.title = 'Immutable in edit mode. Republish under a new version to change.'; }
  });

  // ---- Default locale card ----
  const dl = m.defaultLocale || {};
  setVal('#loc_Publisher',         dl.Publisher);
  setVal('#loc_PackageName',       dl.PackageName);
  setVal('#loc_License',           dl.License);
  setVal('#loc_ShortDescription',  dl.ShortDescription);
  setVal('#loc_PublisherUrl',        dl.PublisherUrl);
  setVal('#loc_PublisherSupportUrl', dl.PublisherSupportUrl);
  setVal('#loc_PrivacyUrl',          dl.PrivacyUrl);
  setVal('#loc_Author',              dl.Author);
  setVal('#loc_PackageUrl',          dl.PackageUrl);
  setVal('#loc_LicenseUrl',          dl.LicenseUrl);
  setVal('#loc_Copyright',           dl.Copyright);
  setVal('#loc_CopyrightUrl',        dl.CopyrightUrl);
  setVal('#loc_Description',         dl.Description);
  setVal('#loc_Moniker',             dl.Moniker);
  setVal('#loc_ReleaseNotesUrl',     dl.ReleaseNotesUrl);
  setVal('#loc_ReleaseNotes',        dl.ReleaseNotes);
  setVal('#loc_InstallationNotes',   dl.InstallationNotes);
  if (Array.isArray(dl.Tags)) setVal('#loc_Tags', dl.Tags.join(', '));

  // ---- Installers ----
  // Wipe whatever the bootstrap left in #installers, then create one
  // card per Installers[] entry and fill it from the manifest. The
  // existing InstallerSha256 + InstallerUrl land on the card dataset
  // so buildInstallerEntry can echo them back on save.
  $('#installers').innerHTML = '';
  const installers = m.installer?.Installers || [];
  installers.forEach(inst => {
    const card = addInstaller();
    setCardField(card, 'select[name="Architecture"]',     inst.Architecture);
    setCardField(card, 'select[name="InstallerType"]',    inst.InstallerType);
    setCardField(card, 'select[name="Scope"]',            inst.Scope);
    setCardField(card, 'input[name="InstallerLocale"]',   inst.InstallerLocale);
    setCardField(card, 'select[name="UpgradeBehavior"]',  inst.UpgradeBehavior);
    setCardField(card, 'input[name="ProductCode"]',       inst.ProductCode);
    setCardField(card, 'input[name="UpgradeCode"]',       inst.UpgradeCode);
    setCardField(card, 'input[name="PackageFamilyName"]', inst.PackageFamilyName);
    setCardField(card, 'input[name="MinimumOSVersion"]',  inst.MinimumOSVersion);
    const sw = inst.InstallerSwitches || {};
    setCardField(card, 'input[name="sw_Silent"]',             sw.Silent);
    setCardField(card, 'input[name="sw_SilentWithProgress"]', sw.SilentWithProgress);
    setCardField(card, 'input[name="sw_Log"]',                sw.Log);
    setCardField(card, 'input[name="sw_InstallLocation"]',    sw.InstallLocation);
    setCardField(card, 'input[name="sw_Interactive"]',        sw.Interactive);
    setCardField(card, 'input[name="sw_Upgrade"]',            sw.Upgrade);
    setCardField(card, 'input[name="sw_Custom"]',             sw.Custom);
    if (Array.isArray(inst.InstallModes)) {
      setCardField(card, 'input[name="InstallModes"]', inst.InstallModes.join(','));
    }
    if (Array.isArray(inst.Commands))       setCardField(card, 'input[name="Commands"]',       inst.Commands.join(','));
    if (Array.isArray(inst.Protocols))      setCardField(card, 'input[name="Protocols"]',      inst.Protocols.join(','));
    if (Array.isArray(inst.FileExtensions)) setCardField(card, 'input[name="FileExtensions"]', inst.FileExtensions.join(','));
    if (Array.isArray(inst.Platform))       setCardField(card, 'input[name="Platform"]',       inst.Platform.join(','));
    if (Array.isArray(inst.InstallerSuccessCodes)) {
      setCardField(card, 'input[name="InstallerSuccessCodes"]', inst.InstallerSuccessCodes.join(','));
    }
    if (Array.isArray(inst.ExpectedReturnCodes) && inst.ExpectedReturnCodes.length) {
      setCardField(card, 'textarea[name="ExpectedReturnCodes"]', JSON.stringify(inst.ExpectedReturnCodes, null, 2));
    }
    if (Array.isArray(inst.AppsAndFeaturesEntries) && inst.AppsAndFeaturesEntries.length) {
      setCardField(card, 'textarea[name="AppsAndFeaturesEntries"]', JSON.stringify(inst.AppsAndFeaturesEntries, null, 2));
    }
    // Stash the installer's existing identity so buildInstallerEntry
    // echoes the same SHA + URL back to the server. The card looks
    // file-bound to recomputeAll (which requires dataset.uploadId).
    card.dataset.uploadId      = `existing-${inst.InstallerSha256 || 'installer'}`;
    if (inst.InstallerSha256) card.dataset.sha256 = inst.InstallerSha256;
    if (inst.InstallerUrl)    card.dataset.installerUrl = inst.InstallerUrl;
    card.dataset.uploadSize    = '0';
    card.dataset.originalName  = (inst.InstallerUrl || '').split('/').pop() || 'existing';
  });

  // ---- Additional locales ----
  $('#locales').innerHTML = '';
  const extras = m.locales || [];
  extras.forEach(loc => {
    addLocale();
    const card = $('#locales .pc-locale-card:last-child');
    if (!card) return;
    Object.entries(loc).forEach(([k, v]) => {
      if (k === 'ManifestType' || k === 'ManifestVersion' || k === 'PackageIdentifier' || k === 'PackageVersion') return;
      const el = card.querySelector(`input[name="${k}"], textarea[name="${k}"]`);
      if (el) el.value = (typeof v === 'string') ? v : JSON.stringify(v);
    });
  });
}

function setVal(sel, v) {
  if (v === undefined || v === null) return;
  const el = $(sel);
  if (el) el.value = String(v);
}
function setCardField(card, sel, v) {
  if (v === undefined || v === null) return;
  const el = card.querySelector(sel);
  if (el) el.value = (typeof v === 'string') ? v : String(v);
}
