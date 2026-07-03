// Config layer for the UNRAID-local admin.
//
// Sources, in order of precedence (later wins):
//   1. Hard defaults below.
//   2. Environment (.env, the only place secrets live).
//   3. /var/lib/repofabric/config/service.yaml (operator-editable runtime knobs).
//   4. /var/lib/repofabric/config/solution.yaml (auth, targets, notifications).
//
// Setup mode: if /var/lib/repofabric/setup-mode exists, the YAML files are not
// read (they may not exist yet), and the server boots a minimal Entra-less
// wizard surface instead. The wizard writes the YAML files and removes
// the flag, then the operator restarts the container.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import yaml from 'js-yaml';

const STATE_DIR = process.env.REPOFABRIC_STATE_DIR || '/var/lib/repofabric';
const CONFIG_DIR = path.join(STATE_DIR, 'config');
const SERVICE_YAML = path.join(CONFIG_DIR, 'service.yaml');
const SOLUTION_YAML = path.join(CONFIG_DIR, 'solution.yaml');
const SETUP_MODE_FLAG = path.join(STATE_DIR, 'setup-mode');
const SETUP_COMPLETE_FLAG = path.join(CONFIG_DIR, 'setup.complete');
const SETUP_TOKEN_FILE = path.join(STATE_DIR, 'setup-token.txt');

function need(name) {
  const v = process.env[name];
  if (!v || v.trim() === '') {
    console.error(`FATAL: required env var ${name} is missing.`);
    process.exit(2);
  }
  return v;
}

function opt(name, fallback) {
  const v = process.env[name];
  return (v && v.trim() !== '') ? v : fallback;
}

function readYamlIfPresent(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return yaml.load(fs.readFileSync(file, 'utf8')) || {};
  } catch (err) {
    console.error(`[config] failed to read ${file}:`, err.message);
    return null;
  }
}

export function loadConfig() {
  const inSetupMode = fs.existsSync(SETUP_MODE_FLAG) || !fs.existsSync(SETUP_COMPLETE_FLAG);
  const service = inSetupMode ? {} : (readYamlIfPresent(SERVICE_YAML) || {});
  const solution = inSetupMode ? {} : (readYamlIfPresent(SOLUTION_YAML) || {});

  const cfg = {
    inSetupMode,
    paths: { stateDir: STATE_DIR, configDir: CONFIG_DIR, serviceYaml: SERVICE_YAML,
             solutionYaml: SOLUTION_YAML, setupModeFlag: SETUP_MODE_FLAG,
             setupCompleteFlag: SETUP_COMPLETE_FLAG, setupTokenFile: SETUP_TOKEN_FILE },

    // Always required from env (so the container can boot at all)
    port:           parseInt(opt('PORT', '8086'), 10),
    // Normalize the public base URL ONCE here so a trailing slash can never reach
    // any consumer. auth.js (redirectUri / logout) and entra-helper.js
    // (buildAzScripts / redirectUriFor) both derive the Entra redirect URI from
    // this value; if one stripped a trailing slash and the other did not, Entra
    // would register a clean URI but MSAL would send a double-slash one and reject
    // sign-in with AADSTS50011. Stripping trailing slashes at the source keeps the
    // registered and transmitted redirect URIs byte-identical.
    publicBaseUrl:  need('REPOFABRIC_ADMIN_PUBLIC_URL').replace(/\/+$/, ''),
    // Plain-HTTP port the installer server is published on (sandbox only) so
    // clients can fetch the bootstrap script before they trust the self-signed
    // CA. Advertised to the SPA via /admin/api/features. Inert in production.
    publicHttpPort: parseInt(opt('REPOFABRIC_PUBLIC_HTTP_PORT', '8080'), 10),
    sessionSecret:  need('REPOFABRIC_SESSION_SECRET'),
    cookieSecure:   opt('REPOFABRIC_COOKIE_SECURE', 'true') === 'true',

    // Deployment profile. Default 'production' (Entra-only, external reverse
    // proxy). 'sandbox' is the throwaway, non-enterprise all-in-one deployment
    // (see ../../sandbox): it enables local-admin sign-in and a permit-invalid-
    // SSL escape hatch. The profile is set by the deployment platform, never the
    // wizard, so the same image behaves identically in production unless the env
    // var is explicitly set to 'sandbox'.
    // A sandbox can be GRADUATED to the recommended/production profile in place
    // via the Settings "Upgrade to Recommended" panel, which writes
    // deployment_profile: production into solution.yaml once every readiness check
    // passes. That override wins over the env so the flip (Entra-only sign-in,
    // sandbox affordances off) takes effect on the next node-admin reload without
    // rebuilding the container; the compose env can be aligned at leisure.
    deploymentProfile: (solution.deployment_profile === 'production')
      ? 'production'
      : opt('REPOFABRIC_DEPLOYMENT_PROFILE', 'production'),
    isSandbox: (solution.deployment_profile !== 'production')
      && opt('REPOFABRIC_DEPLOYMENT_PROFILE', 'production') === 'sandbox',

    // Solution-wide display timezone (FD-026). RepoFabric is the authority for
    // the WHOLE fabric: the selected zone governs RepoFabric, ConfigFabric
    // (sidecar or cross-host), and DSCForge. Selected in settings (service.yaml
    // `timezone`), falling back to the container TZ env, then UTC. Never assume a
    // locale-specific zone (no America/New_York default). Exposed on /healthz and
    // /admin/api/features so the SPA and peers consume this single value.
    timezone:       (service.timezone || opt('TZ', '') || 'UTC'),

    // Bridge to the loopback pwsh listener
    publisherUrl:   opt('REPOFABRIC_PUBLISHER_URL', 'http://127.0.0.1:8085').replace(/\/$/, ''),
    publisherToken: opt('REPOFABRIC_PUBLISHER_TOKEN', ''),

    // Cross-host M2M bridge legs (catalog:read / audit:write). These are mounted
    // pre-auth (no operator session) ONLY when the operator has provisioned the
    // matching scoped token — provisioning a scoped token IS the opt-in to expose
    // that leg cross-host. The Node admin does NOT validate the token or
    // substitute the full publisher token: it forwards the caller's Bearer (and
    // any RFC 9421 signature headers + raw body) through verbatim to the loopback
    // pwsh listener, whose RfBridgeCapability gate is the sole authority on which
    // token grants which leg (M6 least-privilege preserved end to end).
    bridgeLegs: {
      catalogRead: opt('REPOFABRIC_CATALOG_READ_TOKEN', '') !== '',
      auditWrite:  opt('REPOFABRIC_AUDIT_WRITE_TOKEN',  '') !== '',
    },

    // Entra credentials. Sourced from solution.yaml first, env vars as
    // fallback. The wizard's Save persists tenant_id, client_id, and
    // client_secret into solution.yaml; env vars are an alternative for
    // operators who prefer not to keep secrets in YAML.
    entra: {
      tenantId:     solution.auth?.tenant_id     || opt('REPOFABRIC_ENTRA_TENANT_ID', ''),
      clientId:     solution.auth?.client_id     || opt('REPOFABRIC_ENTRA_CLIENT_ID', ''),
      clientSecret: solution.auth?.client_secret || opt('REPOFABRIC_ENTRA_CLIENT_SECRET', ''),
    },

    // Auth lists are sourced from solution.yaml (post-setup). Env vars
    // REPOFABRIC_BOOTSTRAP_ALLOWED_* seed the first save in the wizard only.
    auth: {
      allowedUsers: (solution.auth?.allowed_users || []).map(s => String(s).toLowerCase()),
      allowedGroups: (solution.auth?.allowed_groups || []).map(g => ({
        id: g.id,
        display_name: g.display_name || g.name || g.id,
      })),
      // Read-only operators: admitted to sign in but blocked from every
      // mutating /admin request by the role gate in server.js.
      readonlyUsers: (solution.auth?.readonly_users || []).map(s => String(s).toLowerCase()),
      readonlyGroups: (solution.auth?.readonly_groups || []).map(g => ({
        id: g.id,
        display_name: g.display_name || g.name || g.id,
      })),
    },

    // Target endpoints (from solution.yaml; env vars are seeds for the wizard)
    targets: {
      giteaBaseUrl:      solution.targets?.gitea_base_url      || opt('REPOFABRIC_GITEA_BASE_URL', ''),
      giteaRepo:         solution.targets?.gitea_repo          || opt('REPOFABRIC_GITEA_REPO', ''),
      rewingedUrl:       solution.targets?.rewinged_url        || opt('REPOFABRIC_REWINGED_URL', ''),
      installerBaseUrl:  solution.targets?.installer_base_url  || opt('REPOFABRIC_INSTALLER_BASE_URL', ''),
      manifestMountPath: solution.targets?.manifest_mount_path || opt('REPOFABRIC_MANIFEST_CACHE_DIR', '/var/cache/repofabric/manifests'),
    },

    // Service runtime knobs (from service.yaml)
    service: {
      workerPoolSize:           service.sync?.worker_pool_size           || parseInt(opt('REPOFABRIC_BOOTSTRAP_WORKER_POOL_SIZE', '4'), 10),
      scheduleCron:             service.sync?.schedule_cron              || '0 */6 * * *',
      indexRefreshThresholdHrs: service.sync?.index_refresh_threshold_hours || 6,
      preferredArchitectures:   service.defaults?.preferred_architectures || ['x64', 'x86', 'arm64'],
      defaultLocales:           service.defaults?.locales                || ['en-US'],
      retentionCount:           service.defaults?.retention_count        || 3,
      defaultScope:             service.defaults?.scope                  || 'machine',
      logLevel:                 service.logging?.level                   || 'info',
    },

    // Installer endpoint knobs. The peerdist flag controls whether the
    // installer route answers "Accept-Encoding: peerdist" with a
    // "Content-Encoding: peerdist" MS-PCCRC v1.0 Content Information body
    // for BranchCache and Delivery Optimization. Default is false so a fresh
    // deploy ships in baseline-collection mode; the operator flips it on
    // after the 24 to 48 hour baseline window. See docs/0.8.0-bandwidth-plan.md.
    installers: {
      peerdist: {
        enabled: service.installers?.peerdist?.enabled === true,
      },
    },

    // Upload limit for the custom-publish wizard
    uploadMaxBytes: parseInt(solution.container?.upload_max_bytes || opt('REPOFABRIC_UPLOAD_MAX_BYTES', '2147483648'), 10),

    // Sandbox-only settings (deployment profile 'sandbox'). The local-admin
    // credential lives under solution.yaml `sandbox.local_admin`, written by the
    // setup wizard as a scrypt hash (never plaintext). A production solution.yaml
    // simply has no `sandbox` key, so this block is empty and unused.
    sandbox: {
      localAdmin: {
        username:     solution.sandbox?.local_admin?.username || '',
        passwordHash: solution.sandbox?.local_admin?.password_hash || '',
      },
    },

    // ConfigFabric absorption (the M6 bolt-on, tight sidecar). When enabled,
    // this RepoFabric image co-hosts ConfigFabric's pwsh bridge on loopback
    // :8089 (a supervisord program), the admin SPA gains ConfigFabric's tabs,
    // and the M2M lock/audit seams run container-loopback. Default OFF, so a
    // standalone RepoFabric deploy is byte-identical to before. See the 0.8.1
    // entry in CHANGELOG.md, deploy/integration/, and the ConfigFabric section
    // of linux/.env.example for the full integration wiring.
    configfabric: {
      // One switch drives the whole co-host: this Node SPA/API surface AND the
      // entrypoint/supervisord that start CF's pwsh bridge. service.yaml is the
      // canonical knob; CONFIGFABRIC_ENABLED=true (set in compose) is honoured
      // too so the container layer and the Node layer agree from one value.
      enabled:        service.configfabric?.enabled === true || opt('CONFIGFABRIC_ENABLED', '') === 'true',
      // CF's loopback pwsh bridge inside this container (distinct from RF's 8085).
      publisherUrl:   opt('CONFIGFABRIC_PUBLISHER_URL', 'http://127.0.0.1:8089').replace(/\/$/, ''),
      publisherToken: opt('CONFIGFABRIC_PUBLISHER_TOKEN', ''),
      // Compliance-ingest bearer (Azure Function dual-write) and bolt-on bearer
      // (RepoFabric prune gate -> CF lock evaluate/override). The bolt-on bearer
      // is RF's own publisher token by contract, so both fabrics share it.
      ingestToken:    opt('CONFIGFABRIC_INGEST_TOKEN', ''),
      boltOnToken:    opt('REPOFABRIC_PUBLISHER_TOKEN', ''),
      // Entra group type-ahead prefix for the assignment picker (CF parity).
      groupPrefix:    opt('CONFIGFABRIC_GROUP_PREFIX', ''),
    },
  };

  return cfg;
}

export const config = loadConfig();

// Live read of the selected display timezone (FD-026): re-reads service.yaml so a
// Settings change is reflected on the next /healthz or features fetch without a
// Node restart. Falls back to the value loaded at boot (TZ env, then UTC).
export function currentTimezone() {
  try {
    const svc = readYamlIfPresent(SERVICE_YAML);
    if (svc && svc.timezone) return String(svc.timezone);
  } catch { /* fall through to the cached value */ }
  return config.timezone;
}

// M2M bolt-on readiness self-check (RepoFabric#16). Reports the PRESENCE (never
// the value) of the shared bolt-on bearer + integration state, and surfaces the
// silent-failure misconfig the hard way otherwise: integration enabled but the
// bearer UNSET -> every inbound CF->RF lock-gate / audit call 401s before the
// signature is ever checked. Mirrors ConfigFabric's m2mReadinessWarnings so both
// fabrics report M2M wiring identically. Pure function — safe to call anywhere.
export function m2mReadiness(cfg = config) {
  const cf = cfg.configfabric || {};
  const boltOnTokenSet = !!(cf.boltOnToken && String(cf.boltOnToken).trim() !== '');
  const ingestTokenSet = !!(cf.ingestToken && String(cf.ingestToken).trim() !== '');
  const configfabricEnabled = cf.enabled === true;
  const legs = cfg.bridgeLegs || {};
  const catalogReadLeg = legs.catalogRead === true;
  const auditWriteLeg  = legs.auditWrite === true;
  const warnings = [];
  if (configfabricEnabled && !boltOnTokenSet) {
    warnings.push('configfabric integration is enabled but the bolt-on bearer (REPOFABRIC_PUBLISHER_TOKEN) is UNSET — inbound lock-gate / audit calls will 401 before any signature is checked.');
  }
  // L6: the compliance-ingest seam fails closed (503) without its own token, so
  // surface that the same way as the bolt-on bearer rather than only at the route.
  if (configfabricEnabled && !ingestTokenSet) {
    warnings.push('configfabric integration is enabled but CONFIGFABRIC_INGEST_TOKEN is UNSET — the compliance dual-write ingest will 503.');
  }
  // L2: report the cross-host bridge legs so the operator can confirm over HTTP
  // (and at boot) which legs are wired, not just the absorption bolt-on bearer.
  return { configfabricEnabled, boltOnTokenSet, ingestTokenSet, catalogReadLeg, auditWriteLeg, warnings };
}

// 0.9.0 (FD-031 program): a half-set integration is a boot-time fatal, not a
// silent runtime degrade. When ConfigFabric integration is ENABLED, a missing
// required token means inbound calls would 401 (bolt-on bearer) or the
// compliance ingest would 503 (ingest token). Returns the fatal conditions so
// the server can refuse to boot; empty when integration is off or fully wired.
export function m2mFatals(cfg = config) {
  const cf = cfg.configfabric || {};
  if (cf.enabled !== true) return [];
  const isSet = (v) => !!(v && String(v).trim() !== '');
  const fatals = [];
  if (!isSet(cf.boltOnToken)) {
    fatals.push('CONFIGFABRIC_ENABLED=true but the bolt-on bearer (REPOFABRIC_PUBLISHER_TOKEN) is UNSET; inbound lock-gate/audit calls would 401.');
  }
  if (!isSet(cf.ingestToken)) {
    fatals.push('CONFIGFABRIC_ENABLED=true but CONFIGFABRIC_INGEST_TOKEN is UNSET; the compliance dual-write ingest would 503.');
  }
  return fatals;
}

// Atomic YAML write helper used by the setup wizard and Solution Config save.
// `mode` defaults to 0o640; callers persisting a file that holds a credential
// (solution.yaml carries the Gitea PAT and the Entra client secret) pass 0o600.
// fs.writeFileSync's mode is masked by the process umask, so chmod the temp file
// explicitly before the rename to guarantee the requested bits regardless of umask.
export function writeYamlAtomic(file, obj, mode = 0o640) {
  const tmp = file + '.tmp';
  const body = yaml.dump(obj, { lineWidth: 120, noRefs: true, sortKeys: false });
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(tmp, body, { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, file);
}

export function readSetupToken() {
  try {
    if (!fs.existsSync(SETUP_TOKEN_FILE)) return null;
    return fs.readFileSync(SETUP_TOKEN_FILE, 'utf8').trim() || null;
  } catch { return null; }
}

export function markSetupComplete() {
  fs.writeFileSync(SETUP_COMPLETE_FLAG, new Date().toISOString() + '\n', { mode: 0o640 });
  try { fs.unlinkSync(SETUP_MODE_FLAG); } catch {}
  try { fs.unlinkSync(SETUP_TOKEN_FILE); } catch {}
}

// Re-enter the first-run wizard from an authenticated admin session.
// Touches the setup-mode flag and generates a fresh setup token; the
// container's normal admin surface keeps running until the operator
// restarts it (so we do not strand them mid-session). The wizard
// requires the token, which gets printed to the container console
// so the operator can lift it the same way as on first boot.
export function reEnterSetupMode() {
  // 48-byte url-safe token, matching the first-boot token shape.
  const buf = crypto.randomBytes(36);
  const token = buf.toString('base64url').slice(0, 48);
  fs.mkdirSync(path.dirname(SETUP_MODE_FLAG), { recursive: true });
  fs.writeFileSync(SETUP_MODE_FLAG, new Date().toISOString() + '\n', { mode: 0o640 });
  fs.writeFileSync(SETUP_TOKEN_FILE, token + '\n', { mode: 0o600 });
  // Mirror to the container console so the same operator instructions
  // ("paste the token from docker logs") apply to a re-entry.
  console.log(`[repofabric-admin] Setup re-entered by operator. Token: ${token}`);
  return { token };
}
