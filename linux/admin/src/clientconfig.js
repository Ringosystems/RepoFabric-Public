// clientconfig.js: generate standalone PowerShell 5/7 client configuration
// scripts, one per winget repo.
//
// Each generated script is self-contained and, when run elevated on a Windows
// client, applies ALL of the prescribed RepoFabric client settings for one
// repo:
//
//   1. Registers the repo's winget REST source as Trusted (trust-level), with
//      a fallback for winget builds that predate --trust-level.
//   2. Applies the always-silent winget defaults (all-users PowerShell profile
//      wrappers, machine-scope + interactivity.disable settings.json for the
//      default user and existing users, and the installer host added to the
//      machine Intranet Zone). Mirrors deploy/intune/Set-RfSilentDefaults.ps1.
//   3. When peer caching is enabled for the deployment, configures BranchCache
//      distributed mode, BITS Peercaching, Delivery Optimization Download
//      Mode 1, and the BranchCache firewall rule groups. Mirrors the verified
//      peer-caching lab configuration.
//
// This is the non-Intune path: clients that are not Intune-managed get the
// same posture by running the script (interactively, via GPO logon script,
// SCCM, RMM, etc.). Intune-managed clients use the Settings Catalog policy
// (source + integrity) plus this script as a platform script for the silent
// defaults and peer-caching registry that no CSP covers.

const SOURCE_TYPE = 'Microsoft.Rest';

// Sanitize a value destined for a single-quoted PowerShell string literal:
// double any embedded single quotes. Throw on control chars / newlines so a
// malformed repo field can never break out of the literal.
function psSingleQuote(value) {
  const s = String(value ?? '');
  if (/[\r\n\0]/.test(s)) throw new Error(`value contains illegal control characters: ${JSON.stringify(s)}`);
  return "'" + s.replace(/'/g, "''") + "'";
}

// Sanitize a value destined for the inside of a PowerShell block comment
// (<# ... #>). Strip line breaks and control chars, and neutralize any "#>"
// so it cannot terminate the comment block early.
function psComment(value) {
  return String(value ?? '')
    .replace(/[\r\n\0]+/g, ' ')
    .replace(/#>/g, '# >');
}

// Derive the public REST source URL for a repo from its hostname.
// Falls back to an explicit sourceUrl override when provided.
export function repoSourceUrl(repo, override) {
  if (override) return override;
  const host = repo?.Hostname || repo?.hostname;
  if (!host) return null;
  const scheme = /^https?:\/\//i.test(host) ? '' : 'https://';
  const base = (scheme + host).replace(/\/+$/, '');
  return base + '/api/';
}

// A winget source name must be a single token (no spaces). Derive a stable,
// distinct name per repo so multiple repos can coexist on one client.
export function repoSourceName(repo) {
  const id = String(repo?.RepoId || repo?.repoId || repo?.DisplayName || '')
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return id ? `repofabric-${id}` : 'repofabric';
}

export function clientConfigFilename(repo) {
  const id = String(repo?.RepoId || repo?.repoId || 'repo')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return `Configure-RfClient-${id || 'repo'}.ps1`;
}

// Resolve the installer site to map into the Intranet Zone, as an origin URL
// (scheme://host[:port], port included when non-default). Prefer an explicit
// installer base URL; otherwise derive the origin from the source URL (the source
// host serves installers absent a dedicated installers.<domain>), so MOTW does not
// abort unsigned-MSI installs served from it.
function resolveInstallerSite(sourceUrl, installerSite) {
  const originOf = (u) => { try { const x = new URL(String(u)); return x.protocol + '//' + x.host; } catch { return ''; } };
  return installerSite ? originOf(installerSite) : originOf(sourceUrl);
}

// Build one client-config .ps1 for a single repo. Returns the script text.
//
// opts:
//   repo                 the virtual-repo object (RepoId, DisplayName, Hostname)
//   sourceUrl            override REST URL (else derived from repo.Hostname)
//   sourceName           override winget source name (else derived)
//   sourceIdentifier     winget source identifier (default RfPrivate.<RepoId>)
//   installerSite        installer base URL mapped into the Intranet Zone (else derived from sourceUrl)
//   peerdistEnabled      include the BranchCache/BITS/DO peer-caching block
//   sourceAutoUpdateMinutes  not embedded in script (CSP-only); kept for parity
export function buildClientConfigScript(opts = {}) {
  const repo = opts.repo || {};
  const sourceUrl = repoSourceUrl(repo, opts.sourceUrl);
  if (!sourceUrl) throw new Error('cannot resolve a source URL: repo has no Hostname and no sourceUrl override given');
  const sourceName = opts.sourceName || repoSourceName(repo);
  const repoId = String(repo.RepoId || repo.repoId || 'repo');
  const sourceIdentifier = opts.sourceIdentifier || `RfPrivate.${repoId}`;
  const installerSite = resolveInstallerSite(sourceUrl, opts.installerSite);
  const displayName = psComment(repo.DisplayName || repo.displayName || repoId);
  const peerdist = opts.peerdistEnabled === true;

  const L = [];
  const q = psSingleQuote;

  L.push('#requires -Version 5.1');
  L.push('#requires -RunAsAdministrator');
  L.push('<#');
  L.push('.SYNOPSIS');
  L.push(`    Configures this Windows client for the RepoFabric winget repo "${displayName}".`);
  L.push('    Generated by RepoFabric (RingoSystems Heavy Industries). Runs on Windows');
  L.push('    PowerShell 5.1 and PowerShell 7+.');
  L.push('.DESCRIPTION');
  L.push('    Registers the private winget REST source as Trusted, applies the');
  L.push('    always-silent winget defaults, and (when enabled) configures');
  L.push('    BranchCache + BITS + Delivery Optimization peer caching so this');
  L.push('    client shares installer blocks with peers on its subnet.');
  L.push('    Idempotent: safe to re-run.');
  L.push('#>');
  L.push('[CmdletBinding()]');
  L.push('param(');
  L.push(`  [string]$SourceName       = ${q(sourceName)},`);
  L.push(`  [string]$SourceArg        = ${q(sourceUrl)},`);
  L.push(`  [string]$SourceIdentifier = ${q(sourceIdentifier)},`);
  L.push(`  [string]$InstallerSite    = ${q(installerSite)},`);
  // The peer-caching default tracks the deployment's peerdist setting at
  // generation time; the operator can still flip it per-run.
  L.push(`  [bool]$EnablePeerCaching  = $${peerdist ? 'true' : 'false'},`);
  // Off by default: removing public sources is a deliberate lockdown that also
  // stops "winget upgrade --all" from touching Store apps. Opt in explicitly.
  L.push('  [switch]$ExclusiveSource');
  L.push(')');
  L.push('');
  L.push("$ErrorActionPreference = 'Stop'");
  L.push('$script:RfWarnings = @()');
  L.push('function Write-Step { param([string]$m) Write-Host ("[rf] " + $m) -ForegroundColor Cyan }');
  L.push('function Write-Ok   { param([string]$m) Write-Host ("[ok] " + $m) -ForegroundColor Green }');
  L.push('function Write-Warn { param([string]$m) $script:RfWarnings += $m; Write-Host ("[warn] " + $m) -ForegroundColor Yellow }');
  L.push('');
  L.push('Write-Step ("Configuring this client for RepoFabric source \"" + $SourceName + "\" (" + $SourceArg + ")")');
  L.push('');

  // ---- Step 1: winget present ----
  L.push('# --- 1. Ensure winget is available ---------------------------------------');
  L.push('$winget = Get-Command winget.exe -ErrorAction SilentlyContinue');
  L.push('if (-not $winget) {');
  L.push('  throw "winget.exe not found. Install App Installer (Microsoft.DesktopAppInstaller) from the Microsoft Store or via Add-AppxPackage, then re-run."');
  L.push('}');
  L.push('Write-Ok ("winget present: " + (& winget.exe --version))');
  L.push('');

  // ---- Step 2: register the REST source as trusted ----
  L.push('# --- 2. Register the private REST source as Trusted -----------------------');
  L.push('$existing = (& winget.exe source list) 2>&1 | Out-String');
  L.push('if ($existing -match ("(?im)^\\s*" + [regex]::Escape($SourceName) + "\\s")) {');
  L.push('  Write-Step ("Source " + $SourceName + " already present; refreshing")');
  L.push('  & winget.exe source update --name $SourceName 2>&1 | Out-Null');
  L.push('  Write-Ok "Source refreshed"');
  L.push('} else {');
  L.push('  # Newer winget supports --trust-level trusted. Older builds reject the');
  L.push('  # flag; fall back to a plain add (the source still registers, just');
  L.push('  # without the trusted attribute - SmartScreen may then prompt).');
  L.push('  $addArgs = @("source","add","--name",$SourceName,"--arg",$SourceArg,"--type",' + q(SOURCE_TYPE) + ',"--accept-source-agreements")');
  L.push('  & winget.exe @addArgs --trust-level trusted 2>&1 | Out-Null');
  L.push('  if ($LASTEXITCODE -ne 0) {');
  L.push('    Write-Warn "winget did not accept --trust-level (older build?); retrying without it"');
  L.push('    & winget.exe @addArgs 2>&1 | Out-Null');
  L.push('    if ($LASTEXITCODE -ne 0) { throw ("winget source add failed with exit " + $LASTEXITCODE) }');
  L.push('  }');
  L.push('  Write-Ok ("Registered source " + $SourceName)');
  L.push('}');
  L.push('');

  // ---- Step 3: optional public-source lockdown ----
  L.push('# --- 3. Optional: lock to the private source only -------------------------');
  L.push('if ($ExclusiveSource) {');
  L.push('  foreach ($pub in @("msstore","winget")) {');
  L.push('    $cur = (& winget.exe source list) 2>&1 | Out-String');
  L.push('    if ($cur -match ("(?im)^\\s*" + [regex]::Escape($pub) + "\\s")) {');
  L.push('      & winget.exe source remove --name $pub 2>&1 | Out-Null');
  L.push('      if ($LASTEXITCODE -eq 0) { Write-Ok ("Removed public source " + $pub) }');
  L.push('      else { Write-Warn ("Could not remove public source " + $pub) }');
  L.push('    }');
  L.push('  }');
  L.push('}');
  L.push('');

  // ---- Step 4: always-silent winget defaults ----
  L.push('# --- 4. Always-silent winget defaults (all users) -------------------------');
  // LITERAL here-string (@' ... '@): the body contains $Id / $Rest / @Rest that
  // are part of the wrapper functions and MUST survive verbatim into the profile.
  // An expandable here-string (@" "@) would interpolate them to empty at run time,
  // writing a corrupt profile (e.g. "[string]$Id" -> "[string]") that breaks every
  // future PowerShell session. Do not change @' to @".
  L.push("$profileBody = @'");
  L.push('# --- REPOFABRIC always-silent winget wrappers -------------------------------');
  L.push('# Deployed by RepoFabric. Do not edit on-host; re-running the config script overwrites.');
  L.push('function Install-WingetSilent { [CmdletBinding()] param([Parameter(Mandatory,Position=0)][string]$Id,[Parameter(ValueFromRemainingArguments)]$Rest)');
  L.push('  & winget.exe install --id $Id --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --scope machine --exact @Rest }');
  L.push('function Upgrade-WingetSilent { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$Rest)');
  L.push('  & winget.exe upgrade --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --scope machine @Rest }');
  L.push('function Uninstall-WingetSilent { [CmdletBinding()] param([Parameter(Mandatory,Position=0)][string]$Id,[Parameter(ValueFromRemainingArguments)]$Rest)');
  L.push('  & winget.exe uninstall --id $Id --silent --disable-interactivity --exact @Rest }');
  L.push('Set-Alias wgi Install-WingetSilent -Scope Global');
  L.push('Set-Alias wgup Upgrade-WingetSilent -Scope Global');
  L.push('Set-Alias wgu Uninstall-WingetSilent -Scope Global');
  L.push('# --- END REPOFABRIC winget wrappers -----------------------------------------');
  L.push("'@");
  L.push('$profileTargets = @(');
  L.push('  (Join-Path $env:windir "System32\\WindowsPowerShell\\v1.0\\Profile.ps1"),');
  L.push('  "C:\\Program Files\\PowerShell\\7\\Profile.ps1"');
  L.push(')');
  // Self-heal: strip ANY existing RepoFabric block (including the older,
  // possibly $-corrupted format whose end marker was a bare dashed line) before
  // writing the fresh one. Anchored on the stable Set-Alias line, which carries
  // no $ vars and therefore survives even in corrupted profiles. This makes
  // re-running the script repair machines that ran the earlier broken version.
  L.push('$rfStrip = "(?s)\\r?\\n?# --- REPOFABRIC always-silent winget wrappers.*?Set-Alias wgu Uninstall-WingetSilent -Scope Global(\\r?\\n#[^\\r\\n]*)?"');
  L.push('foreach ($p in $profileTargets) {');
  L.push('  $dir = Split-Path -Parent $p');
  L.push('  if (-not (Test-Path $dir)) { continue }');
  L.push('  $cur = if (Test-Path $p) { Get-Content -Raw $p -ErrorAction SilentlyContinue } else { "" }');
  L.push('  if ($null -eq $cur) { $cur = "" }');
  L.push('  $cleaned = [regex]::Replace($cur, $rfStrip, "")');
  L.push('  $new = ($cleaned.TrimEnd() + "`r`n`r`n" + $profileBody + "`r`n").TrimStart([char]13,[char]10)');
  L.push('  Set-Content -Path $p -Value $new -Encoding UTF8');
  L.push('  Write-Ok ("Refreshed silent winget wrappers in " + $p)');
  L.push('}');
  L.push('');
  L.push('$settingsJson = @"');
  L.push('{');
  L.push('  "`$schema": "https://aka.ms/winget-settings.schema.json",');
  L.push('  "installBehavior": { "preferences": { "scope": "machine" } },');
  L.push('  "interactivity": { "disable": true }');
  L.push('}');
  L.push('"@');
  L.push('$rel = "AppData\\Local\\Packages\\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\\LocalState\\settings.json"');
  L.push('$defDir = Join-Path $env:SystemDrive ("Users\\Default\\" + (Split-Path -Parent $rel))');
  L.push('New-Item -ItemType Directory -Force -Path $defDir | Out-Null');
  L.push('Set-Content -Path (Join-Path $defDir "settings.json") -Value $settingsJson -Encoding UTF8');
  L.push('Get-ChildItem (Join-Path $env:SystemDrive "Users") -Directory -ErrorAction SilentlyContinue |');
  L.push('  Where-Object { $_.Name -notin @("Default","Public","All Users","Default User") } |');
  L.push('  ForEach-Object {');
  L.push('    $tgt = Join-Path $_.FullName $rel');
  L.push('    if (Test-Path (Split-Path -Parent $tgt)) { Set-Content -Path $tgt -Value $settingsJson -Encoding UTF8 }');
  L.push('  }');
  L.push('Write-Ok "Applied machine-scope + non-interactive winget settings.json"');
  L.push('');
  // Map the RepoFabric site(s) into the Intranet Zone via the Site to Zone
  // Assignment List (ZoneMapKey), keyed on the FULL URL (scheme + host + port). The
  // Intranet Zone is the low-risk zone whose downloads skip the attachment scan, so
  // winget's Mark-of-the-Web step does not stall on installers from this origin. The
  // per-host map (ZoneMap\\Domains) cannot express a non-standard port, so the
  // full-URL list is used here, for both the source and the installer site.
  L.push('# --- Intranet Zone: map the RepoFabric site(s) so MOTW does not stall (machine scope) ---');
  L.push('$rfSites = @()');
  L.push('foreach ($u in @($SourceArg, $InstallerSite)) {');
  L.push('  if ($u) { try { $x = [Uri]$u; $rfSites += ($x.Scheme + "://" + $x.Authority) } catch { } }');
  L.push('}');
  L.push('$rfSites = $rfSites | Select-Object -Unique');
  L.push('if ($rfSites) {');
  L.push('  $zmk = "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\ZoneMapKey"');
  L.push('  New-Item -Path $zmk -Force | Out-Null');
  L.push('  foreach ($s in $rfSites) {');
  L.push('    New-ItemProperty -Path $zmk -Name $s -Value "1" -PropertyType String -Force | Out-Null');
  L.push('    Write-Ok ("Mapped " + $s + " to the Intranet Zone (HKLM)")');
  L.push('  }');
  L.push('}');
  L.push('');

  // ---- Step 5: peer caching ----
  L.push('# --- 5. Peer caching (BranchCache + BITS + Delivery Optimization) ---------');
  L.push('if ($EnablePeerCaching) {');
  L.push('  try { Enable-BCDistributed -Force -ErrorAction Stop | Out-Null; Write-Ok "BranchCache distributed mode enabled" }');
  L.push('  catch { Write-Warn ("Enable-BCDistributed failed: " + $_.Exception.Message) }');
  L.push('  try { Set-BCDataCacheEntryMaxAge -TimeoutDays 90 -Force -ErrorAction Stop | Out-Null } catch {}');
  L.push('  $bitsKey = "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\BITS"');
  L.push('  if (-not (Test-Path $bitsKey)) { New-Item -Path $bitsKey -Force | Out-Null }');
  L.push('  Set-ItemProperty -Path $bitsKey -Name EnablePeerCaching  -Type DWord -Value 1');
  L.push('  Set-ItemProperty -Path $bitsKey -Name DisableBranchCache -Type DWord -Value 0');
  L.push('  $doKey = "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization"');
  L.push('  if (-not (Test-Path $doKey)) { New-Item -Path $doKey -Force | Out-Null }');
  L.push('  Set-ItemProperty -Path $doKey -Name DODownloadMode -Type DWord -Value 1');
  L.push('  foreach ($g in @("BranchCache - Content Retrieval (Uses HTTP)","BranchCache - Peer Discovery (Uses WSD)")) {');
  L.push('    try { Enable-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue } catch {}');
  L.push('  }');
  L.push('  Write-Ok "BITS Peercaching + DO Download Mode 1 + BranchCache firewall rules applied"');
  L.push('} else {');
  L.push('  Write-Step "Peer caching not enabled for this deployment; skipping BranchCache/BITS/DO"');
  L.push('}');
  L.push('');

  // ---- Step 6: summary ----
  L.push('# --- 6. Summary -----------------------------------------------------------');
  L.push('Write-Step "Current winget sources:"');
  L.push('& winget.exe source list');
  L.push('if ($script:RfWarnings.Count -gt 0) {');
  L.push('  Write-Host ""; Write-Warn ("Completed with " + $script:RfWarnings.Count + " warning(s):")');
  L.push('  $script:RfWarnings | ForEach-Object { Write-Host ("    - " + $_) -ForegroundColor Yellow }');
  L.push('} else {');
  L.push('  Write-Ok "Client configuration complete with no warnings."');
  L.push('}');
  L.push('');

  return L.join('\r\n');
}

// Enumerate per-repo client-config targets from the virtual-repo list and the
// deployment config. Returns one descriptor per repo (skipping repos with no
// resolvable hostname, with a note).
export function listClientConfigTargets(repos, { peerdistEnabled = false, installerHost = '' } = {}) {
  const list = Array.isArray(repos) ? repos : [];
  return list.map(repo => {
    const sourceUrl = repoSourceUrl(repo);
    return {
      repoId: repo.RepoId || repo.repoId || null,
      displayName: repo.DisplayName || repo.displayName || repo.RepoId || repo.repoId || 'repo',
      sourceUrl,
      sourceName: repoSourceName(repo),
      filename: clientConfigFilename(repo),
      peerdistEnabled: !!peerdistEnabled,
      installerHost,
      ready: !!sourceUrl,
      note: sourceUrl ? null : 'no Hostname configured for this repo',
    };
  });
}
