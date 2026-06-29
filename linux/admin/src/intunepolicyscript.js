// intunepolicyscript.js: generate a standalone PowerShell 5/7 script that
// applies the DesktopAppInstaller (winget) policy stack LOCALLY, i.e. the
// same settings the Intune Settings Catalog policy would push, written to the
// Group Policy registry under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller.
//
// This is a SEPARATE artifact from clientconfig.js (Configure-RfClient-*.ps1):
//   - clientconfig.js registers the source at RUNTIME (winget source add
//     --trust-level), applies silent defaults, and configures peer caching.
//   - this module enforces the POLICY layer (the lockdown toggles, the
//     policy-pinned source list, and the source auto-update interval) the way
//     the Intune policy does, for clients that are not Intune-managed.
//
// Registry model (winget Group Policy):
//   - Toggle policies  -> REG_DWORD value (1 enabled / 0 disabled) named after
//     the policy, directly under the AppInstaller key.
//   - Source-list policies (EnableAdditionalSources / EnableAllowedSources) ->
//     the Enable* DWORD turns the policy on, AND a subkey ("AdditionalSources"
//     / "AllowedSources") holds numbered REG_SZ values, each a JSON source
//     object. This matches the source descriptor in the Intune endpoint doc.
//   - SourceAutoUpdateInterval -> REG_DWORD minutes.

// PowerShell registry-drive form (note the ':' after HKLM). Without the
// colon, PowerShell resolves the path against the FileSystem provider, whose
// Set-ItemProperty has no -Type parameter -- the script then fails with
// "A parameter cannot be found that matches parameter name 'Type'" and
// New-Item silently creates a junk HKLM\ folder tree in the cwd. The colon is
// what binds these cmdlets to the Registry provider.
const POLICY_KEY = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppInstaller';

// The full toggle stack with recommended secure defaults (from
// docs/Intune-EndpointConfiguration.md). Operators can override each via a
// script parameter so the ENTIRE stack is settable.
//   true  => enabled  (DWORD 1)
//   false => disabled (DWORD 0)
const TOGGLES = [
  { name: 'EnableAppInstaller',                               default: true,  help: 'Master switch: winget is permitted.' },
  { name: 'EnableWindowsPackageManagerCommandLineInterfaces', default: true,  help: 'winget.exe CLI is permitted.' },
  { name: 'EnableSettings',                                   default: true,  help: 'Allow winget settings.' },
  { name: 'EnableDefaultSource',                              default: true,  help: 'Keep the default winget source available.' },
  { name: 'EnableMicrosoftStoreSource',                       default: true,  help: 'Keep the msstore source available.' },
  { name: 'EnableAdditionalSources',                          default: true,  help: 'Honor the policy-pinned private source list.' },
  { name: 'EnableAllowedSources',                             default: false, help: 'Lock the source allowlist (off by default so public sources are not removed).' },
  { name: 'EnableLocalManifestFiles',                         default: false, help: 'Block winget install -m <file>.' },
  { name: 'EnableHashOverride',                               default: false, help: 'Force SHA-256 verification; never allow a hash mismatch.' },
  { name: 'EnableLocalArchiveMalwareScanOverride',            default: false, help: 'Force AV scan of archive installers.' },
  { name: 'EnableBypassCertificatePinningForMicrosoftStore',  default: false, help: 'Keep Microsoft Store certificate pinning on.' },
  { name: 'EnableExperimentalFeatures',                       default: false, help: 'Disable experimental winget features.' },
  { name: 'EnableMSAppInstallerProtocol',                     default: false, help: 'Disable the ms-appinstaller: protocol handler (attack surface).' },
];

function psSingleQuote(value) {
  const s = String(value ?? '');
  if (/[\r\n\0]/.test(s)) throw new Error(`value contains illegal control characters: ${JSON.stringify(s)}`);
  return "'" + s.replace(/'/g, "''") + "'";
}

function psComment(value) {
  return String(value ?? '').replace(/[\r\n\0]+/g, ' ').replace(/#>/g, '# >');
}

// Build the JSON source descriptor winget's GP source list expects. Matches
// the shape in docs/Intune-EndpointConfiguration.md (section 2.3).
function sourceDescriptorJson({ sourceName, sourceUrl, sourceIdentifier }) {
  const arg = sourceUrl.endsWith('/') ? sourceUrl : sourceUrl + '/';
  return JSON.stringify({
    Name: sourceName,
    Arg: arg,
    Type: 'Microsoft.Rest',
    Data: '',
    Identifier: sourceIdentifier,
    TrustLevel: ['Trusted'],
    Explicit: false,
  });
}

export function intunePolicyScriptFilename(repo) {
  const id = String(repo?.RepoId || repo?.repoId || 'repo')
    .replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  return `Set-RfWingetPolicy-${id || 'repo'}.ps1`;
}

// Build the policy-applier script for one repo.
// opts: { repo, sourceUrl, sourceName, sourceIdentifier, autoUpdateMinutes }
export function buildIntunePolicyScript(opts = {}) {
  const repo = opts.repo || {};
  const repoId = String(repo.RepoId || repo.repoId || 'repo');
  const displayName = psComment(repo.DisplayName || repo.displayName || repoId);
  const sourceUrl = opts.sourceUrl;
  if (!sourceUrl) throw new Error('buildIntunePolicyScript requires a sourceUrl');
  const sourceName = opts.sourceName || 'repofabric';
  const sourceIdentifier = opts.sourceIdentifier || `RfPrivate.${repoId}`;
  const autoUpdateMinutes = Number.isFinite(opts.autoUpdateMinutes) ? opts.autoUpdateMinutes : 5;
  const srcJson = sourceDescriptorJson({ sourceName, sourceUrl, sourceIdentifier });

  const L = [];
  const q = psSingleQuote;

  L.push('#requires -Version 5.1');
  L.push('#requires -RunAsAdministrator');
  L.push('<#');
  L.push('.SYNOPSIS');
  L.push(`    Applies the DesktopAppInstaller (winget) policy stack for the RepoFabric`);
  L.push(`    repo "${displayName}" to the local Group Policy registry.`);
  L.push('    Generated by RepoFabric (RingoSystems Heavy Industries). Windows PowerShell 5.1 and 7+.');
  L.push('.DESCRIPTION');
  L.push('    The non-Intune equivalent of importing the Settings Catalog policy: writes');
  L.push('    HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppInstaller. Toggle policies are');
  L.push('    REG_DWORD; the private REST source is pinned via the AdditionalSources list.');
  L.push('    Separate from Configure-RfClient-*.ps1 (which does runtime source-add, silent');
  L.push('    defaults, and peer caching). Idempotent.');
  L.push('#>');
  L.push('[CmdletBinding()]');
  L.push('param(');
  // Per-toggle params so the whole stack is settable.
  for (const t of TOGGLES) {
    L.push(`  # ${t.help}`);
    L.push(`  [bool]$${t.name} = $${t.default ? 'true' : 'false'},`);
  }
  L.push(`  [int]$SourceAutoUpdateMinutes = ${autoUpdateMinutes},`);
  L.push(`  [string]$SourceName       = ${q(sourceName)},`);
  L.push(`  [string]$SourceArg        = ${q(sourceUrl.endsWith('/') ? sourceUrl : sourceUrl + '/')},`);
  L.push(`  [string]$SourceIdentifier = ${q(sourceIdentifier)},`);
  L.push('  # When set, also writes the AllowedSources list (private + winget + msstore)');
  L.push('  # so EnableAllowedSources can lock the source set without losing public sources.');
  L.push('  [switch]$IncludePublicInAllowedSources');
  L.push(')');
  L.push('');
  L.push("$ErrorActionPreference = 'Stop'");
  L.push(`$Key = ${q(POLICY_KEY)}`);
  L.push('function Write-Ok { param([string]$m) Write-Host ("[ok] " + $m) -ForegroundColor Green }');
  L.push('function Write-Step { param([string]$m) Write-Host ("[rf] " + $m) -ForegroundColor Cyan }');
  L.push('');
  L.push('Write-Step ("Applying DesktopAppInstaller policy to " + $Key)');
  L.push('if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }');
  L.push('');

  // ---- toggles ----
  L.push('# --- Toggle policies (REG_DWORD 1=enabled / 0=disabled) -------------------');
  L.push('$toggles = [ordered]@{');
  for (const t of TOGGLES) {
    L.push(`  ${t.name} = $${t.name}`);
  }
  L.push('}');
  L.push('foreach ($name in $toggles.Keys) {');
  L.push('  $val = if ($toggles[$name]) { 1 } else { 0 }');
  L.push('  Set-ItemProperty -Path $Key -Name $name -Type DWord -Value $val');
  L.push('}');
  L.push('Write-Ok ("Set " + $toggles.Count + " toggle policies")');
  L.push('');

  // ---- auto update interval ----
  L.push('# --- Source auto-update interval (minutes) --------------------------------');
  L.push('Set-ItemProperty -Path $Key -Name "SourceAutoUpdateInterval" -Type DWord -Value $SourceAutoUpdateMinutes');
  L.push('Write-Ok ("SourceAutoUpdateInterval = " + $SourceAutoUpdateMinutes + " min")');
  L.push('');

  // ---- additional sources list (the pinned private source) ----
  L.push('# --- AdditionalSources: pin the private REST source -----------------------');
  L.push('# winget reads source-list policies from a subkey holding numbered REG_SZ');
  L.push('# values, each a JSON source descriptor.');
  L.push(`$sourceJson = ${q(srcJson)}`);
  L.push('$addKey = Join-Path $Key "AdditionalSources"');
  L.push('if (-not (Test-Path $addKey)) { New-Item -Path $addKey -Force | Out-Null }');
  L.push('New-ItemProperty -Path $addKey -Name "1" -Value $sourceJson -PropertyType String -Force | Out-Null');
  L.push('Write-Ok ("Pinned source " + $SourceName + " via AdditionalSources policy")');
  L.push('');

  // ---- allowed sources lockdown (optional) ----
  L.push('# --- AllowedSources: optional source allowlist lockdown -------------------');
  L.push('if ($EnableAllowedSources) {');
  L.push('  $allowKey = Join-Path $Key "AllowedSources"');
  L.push('  if (-not (Test-Path $allowKey)) { New-Item -Path $allowKey -Force | Out-Null }');
  L.push('  Remove-ItemProperty -Path $allowKey -Name * -ErrorAction SilentlyContinue');
  L.push('  New-ItemProperty -Path $allowKey -Name "1" -Value $sourceJson -PropertyType String -Force | Out-Null');
  L.push('  if ($IncludePublicInAllowedSources) {');
  L.push('    $winget  = \'{"Name":"winget","Arg":"https://cdn.winget.microsoft.com/cache","Type":"Microsoft.PreIndexed.Package","Data":"","Identifier":"Microsoft.Winget.Source_8wekyb3d8bbwe","Explicit":false}\'');
  L.push('    $msstore = \'{"Name":"msstore","Arg":"https://storeedgefd.dsx.mp.microsoft.com/v9.0","Type":"Microsoft.Rest","Data":"","Identifier":"StoreEdgeFD","Explicit":false}\'');
  L.push('    New-ItemProperty -Path $allowKey -Name "2" -Value $winget  -PropertyType String -Force | Out-Null');
  L.push('    New-ItemProperty -Path $allowKey -Name "3" -Value $msstore -PropertyType String -Force | Out-Null');
  L.push('  }');
  L.push('  Write-Ok "AllowedSources allowlist written"');
  L.push('} else {');
  L.push('  Write-Step "EnableAllowedSources is off; not locking the source allowlist"');
  L.push('}');
  L.push('');

  // ---- summary ----
  L.push('Write-Step "Done. winget honors these policies on next launch. Current view:"');
  L.push('& winget.exe --info 2>$null | Select-String -Pattern "Group Policy|Admin Setting|Policy" -SimpleMatch');
  L.push('Write-Ok "Policy stack applied. Run \'winget source list\' to confirm the pinned source."');
  L.push('');

  return L.join('\r\n');
}
