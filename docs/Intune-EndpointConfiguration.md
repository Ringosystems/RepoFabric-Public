# Intune Endpoint Configuration for RepoFabric

|     |     |
| --- | --- |
| **Document version** | 0.8.0 |
| **Status** | Deployable assets live under [`deploy/intune/`](../deploy/intune/). The smoke commands in [`deploy/intune/README.md`](../deploy/intune/README.md) are the documented check. |
| **Audience** | Windows endpoint administrators deploying the `repofabric` source to Intune-managed devices |

This document defines the Intune configuration that every Windows endpoint must receive in order to consume packages from a RepoFabric stack. The configuration enforces three guarantees:

1. **Trusted source auto-registration.** The `repofabric` REST source is registered on every device with `TrustLevel: Trusted` so that Mark-of-the-Web / SmartScreen cannot silently abort installs of unsigned MSIs served from the self-hosted origin.
2. **Mandatory integrity verification.** The rewinged TLS certificate chain is pinned in the source registration, and `EnableHashOverride` is disabled so that any installer whose SHA-256 does not match the manifest fails closed.
3. **Always-silent operations.** Every end-user `winget install`, `winget upgrade`, and `winget uninstall` invocation runs silently and non-interactively with no prompts, no agreement clicks, no installer UI, and no scope question. There are no options to forget.

Everything below is deployable from the Intune admin center; no on-host registry editing is needed.

---

## 1. What gets deployed

| # | Mechanism | What it does | Why this mechanism |
|---|---|---|---|
| 1 | **Settings Catalog profile** — `Desktop App Installer` category | Auto-registers the `repofabric` source as trusted with TLS cert pinning; disables hash override and local manifest files | Native CSP, MDM-enforced, survives `winget source reset` |
| 2 | **PowerShell platform script** (run-once, SYSTEM context) | Drops an all-users PowerShell profile defining `wgi` / `wgup` / `wgu` wrappers; writes `settings.json` to every user profile with `interactivity.disable: true`; maps `https://installers.winget.<domain>` into the machine-wide Intranet Zone | No CSP exists for "default winget install flags"; profile-level wrappers are the only way to force silent on user-initiated commands |
| 3 | **Intune Win32 app definition pattern** | Every repofabric-sourced app deployed by Intune itself uses the standard silent invocation as its `InstallCommandLine` / `UninstallCommandLine` | App-level enforcement of silent for Intune-driven installs (separate from the user-initiated CLI path) |

Together, components 1 + 2 + 3 enforce the goal: **every winget install, upgrade, and uninstall on a managed endpoint is always silent with no options.**

---

## 2. Component 1 — Settings Catalog profile (CSP)

### 2.1 Create the profile

In the Intune admin center:

1. **Devices → Configuration → Create → New Policy**
2. Platform: **Windows 10 and later**
3. Profile type: **Settings catalog**
4. Name: `REPOFABRIC — WinGet client configuration`
5. **+ Add settings** → search `Desktop App Installer` → expand the **Desktop App Installer** category

### 2.2 Settings to enable

Configure exactly these settings. Anything not listed should be left **Not configured** so machine defaults apply.

| Setting | Value | Purpose |
|---|---|---|
| **Enable App Installer** | `Enabled` | Master toggle — winget is permitted |
| **Enable Windows Package Manager Command Line Interfaces** | `Enabled` | `winget.exe` CLI is permitted |
| **Enable Default Source** | `Enabled` | Keep msstore default available |
| **Enable Microsoft Store Source** | `Enabled` | Keep msstore available |
| **Enable Additional Sources** | `Enabled` + JSON below | **Auto-registers the repofabric trusted source** |
| **Enable Allowed Sources** | `Enabled` + JSON allowlist | Locks source list so end users cannot add untrusted sources |
| **Enable Local Manifest Files** | `Disabled` | Blocks `winget install -m <file>` — endpoints can only install from registered sources |
| **Enable Hash Override** | `Disabled` | **Forces SHA-256 verification** — never silently allows a hash mismatch |
| **Enable Local Archive Malware Scan Override** | `Disabled` | Forces AV scan of archive installers |
| **Enable Bypass Certificate Pinning For Microsoft Store** | `Disabled` | Microsoft Store cert pinning stays on |
| **Source Auto Update Interval In Minutes** | `5` | Endpoint pulls the rewinged index every 5 minutes |

### 2.3 The `Enable Additional Sources` JSON

This is the heart of the policy. Paste the following as the value of `Enable Additional Sources` (replace `<your-domain>` and the cert block as described under §2.4):

```json
{
  "Sources": [
    {
      "Name": "repofabric",
      "Arg": "https://winget.<your-domain>/api/",
      "Type": "Microsoft.Rest",
      "Data": "",
      "Identifier": "WingetRepoSync.Production",
      "TrustLevel": ["Trusted"],
      "Explicit": false,
      "CertificatePinning": {
        "Chains": [
          {
            "Chain": [
              {
                "Validation": ["Subject", "Issuer", "PublicKey"],
                "EmbeddedCertificate": "<base64-DER-of-rewinged-leaf-or-issuer-cert>"
              }
            ]
          }
        ]
      }
    }
  ]
}
```

Field-by-field:

| Field | Why this value |
|---|---|
| `Name` | The friendly name end users see in `winget source list` |
| `Arg` | Public HTTPS URL of the rewinged endpoint behind NPM. Trailing slash required. |
| `Type` | `Microsoft.Rest` — the protocol rewinged speaks |
| `Identifier` | Stable opaque ID. Used by winget to detect that the source is already registered; changing it forces a re-registration. |
| `TrustLevel: ["Trusted"]` | **The critical flag.** Tells winget to skip the IAttachmentExecute/SmartScreen path that silently aborts unsigned-MSI installs. Without this, the install pipeline reaches the MOTW step and exits with no error. |
| `Explicit: false` | Source is included in default search (`winget install <id>` without `--source repofabric` still hits it) |
| `CertificatePinning` | Locks the source to a specific TLS chain. Even if DNS is hijacked or a rogue CA mis-issues, winget refuses to contact the source unless the presented chain matches. |

### 2.4 Producing the `EmbeddedCertificate` value

The embedded certificate is a base64-encoded DER blob of either the leaf certificate currently served by `winget.<your-domain>` or its issuing CA. Pinning the issuer is more durable (survives Let's Encrypt renewals); pinning the leaf is stricter.

From any Windows machine with PowerShell 7:

```powershell
# Pin the issuer (recommended for LE-rotated leafs)
$req = [System.Net.HttpWebRequest]::Create('https://winget.<your-domain>/api/information')
$req.GetResponse() | Out-Null
$leaf  = $req.ServicePoint.Certificate
$chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
$chain.Build([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($leaf)) | Out-Null
$issuer = $chain.ChainElements[1].Certificate    # 0=leaf, 1=issuer, 2=root
[Convert]::ToBase64String($issuer.RawData)       # paste this into EmbeddedCertificate
```

Re-run this whenever the rewinged certificate chain changes (rarely — only on CA rotation, not on every LE renewal if you pin the issuer).

### 2.5 The `Enable Allowed Sources` JSON

Paste the same source object (without `CertificatePinning`) into `Enable Allowed Sources` to lock the source allowlist so end users cannot `winget source add` arbitrary additional repos:

```json
{
  "Sources": [
    { "Name": "winget", "Arg": "https://cdn.winget.microsoft.com/cache", "Type": "Microsoft.PreIndexed.Package", "Identifier": "Microsoft.Winget.Source_8wekyb3d8bbwe" },
    { "Name": "msstore", "Arg": "https://storeedgefd.dsx.mp.microsoft.com/v9.0", "Type": "Microsoft.Rest", "Identifier": "StoreEdgeFD" },
    { "Name": "repofabric", "Arg": "https://winget.<your-domain>/api/", "Type": "Microsoft.Rest", "Identifier": "WingetRepoSync.Production" }
  ]
}
```

### 2.6 Assignment

Assign the profile to the `All Devices` group (or a pilot ring first). Devices receive it on their next MDM sync; force one with `dsregcmd /refreshprt` or `Sync` from the Company Portal app.

---

## 3. Component 2 — PowerShell platform script for always-silent CLI

Component 1 covers the source registration and integrity. It does **not** force `winget install` / `upgrade` / `uninstall` to run silently when invoked interactively by a user, because winget has no policy for default CLI flags. The fix is a SYSTEM-context PowerShell script that drops profile-level wrappers and a global `settings.json`.

### 3.1 Create the script

In the Intune admin center:

1. **Devices → Scripts and remediations → Platform scripts → Add → Windows 10 and later**
2. Name: `REPOFABRIC — Force silent winget CLI`
3. Upload `Set-RfSilentDefaults.ps1` (canonical contents below)
4. Settings:
   - **Run this script using the logged on credentials**: `No` (run as SYSTEM)
   - **Enforce script signature check**: `Yes` if you sign your scripts (recommended), otherwise `No`
   - **Run script in 64 bit PowerShell host**: `Yes`
5. Assign to `All Devices`

### 3.2 `Set-RfSilentDefaults.ps1`

```powershell
<#
.SYNOPSIS
  Forces every winget install, upgrade, and uninstall on this endpoint to be
  silent and non-interactive, for all users. Deployed via Intune as a SYSTEM-
  context platform script.

.NOTES
  Idempotent. Safe to re-run. Logs to
  C:\ProgramData\REPOFABRIC\Logs\Set-RfSilentDefaults.log
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$logDir = 'C:\ProgramData\REPOFABRIC\Logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
Start-Transcript -Path (Join-Path $logDir 'Set-RfSilentDefaults.log') -Append

try {
    # --- 1. All-users PowerShell profile (Windows PowerShell 5.1 + pwsh 7) ---
    $profileBody = @'
# --- REPOFABRIC always-silent winget wrappers ------------------------------------
# Deployed by Intune. Do not edit on-host; changes are overwritten on next sync.
function Install-WingetSilent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Id,
        [Parameter(ValueFromRemainingArguments)] $Rest
    )
    & winget.exe install --id $Id --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements `
        --scope machine --exact @Rest
}
function Uninstall-WingetSilent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Id,
        [Parameter(ValueFromRemainingArguments)] $Rest
    )
    & winget.exe uninstall --id $Id --silent --disable-interactivity `
        --exact @Rest
}
function Upgrade-WingetSilent {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] $Rest)
    & winget.exe upgrade --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements `
        --scope machine @Rest
}
Set-Alias wgi Install-WingetSilent
Set-Alias wgu Uninstall-WingetSilent
Set-Alias wgup Upgrade-WingetSilent
# ---------------------------------------------------------------------------
'@

    $profileTargets = @(
        "$env:windir\System32\WindowsPowerShell\v1.0\Profile.ps1",    # 5.1 all-users
        'C:\Program Files\PowerShell\7\Profile.ps1'                   # pwsh 7 all-users
    )

    foreach ($p in $profileTargets) {
        $dir = Split-Path -Parent $p
        if (-not (Test-Path $dir)) { continue }   # pwsh 7 may not be installed
        $existing = if (Test-Path $p) { Get-Content -Raw $p } else { '' }
        if ($existing -notmatch '# --- REPOFABRIC always-silent winget wrappers') {
            Add-Content -Path $p -Value "`r`n$profileBody`r`n"
            Write-Host "Added wrappers to $p"
        } else {
            Write-Host "Wrappers already present in $p"
        }
    }

    # --- 2. winget settings.json for the default user profile + all existing ---
    $settings = @{
        '$schema'         = 'https://aka.ms/winget-settings.schema.json'
        installBehavior   = @{ preferences = @{ scope = 'machine' } }
        interactivity     = @{ disable = $true }
    } | ConvertTo-Json -Depth 6

    $relPath = 'AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'

    # Default user profile (applies to all new users)
    $defaultUserDir = "$env:SystemDrive\Users\Default\$(Split-Path -Parent $relPath)"
    $null = New-Item -ItemType Directory -Force -Path $defaultUserDir
    Set-Content -Path (Join-Path $defaultUserDir 'settings.json') -Value $settings -Encoding UTF8

    # Existing user profiles
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'Default', 'Public', 'All Users', 'Default User' } |
        ForEach-Object {
            $target = Join-Path $_.FullName $relPath
            $targetDir = Split-Path -Parent $target
            if (Test-Path $targetDir) {
                Set-Content -Path $target -Value $settings -Encoding UTF8
                Write-Host "Wrote settings.json for $($_.Name)"
            }
        }

    # --- 3. Intranet Zone: map the installer site at machine scope -------------
    # Adjust the URL before deploying; this complements (does not replace) the
    # cert-pinning in the Settings Catalog profile. The Site to Zone Assignment List
    # is keyed on the FULL URL (scheme, host, and port), so a non-standard port is
    # honored; the Intranet Zone is the low-risk zone whose downloads skip the
    # attachment scan, so winget's Mark-of-the-Web step does not stall.
    $installerSite = 'https://installers.winget.example.com'
    $zmk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey'
    $null = New-Item -Path $zmk -Force
    New-ItemProperty -Path $zmk -Name $installerSite -Value '1' -PropertyType String -Force | Out-Null  # 1 = Intranet Zone
    Write-Host "Mapped $installerSite to the Intranet Zone (HKLM)"

    Write-Host 'Set-RfSilentDefaults: success'
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
```

Edit the `$installerSite` value before uploading to match your deployment.

### 3.3 What this gives end users

After the script lands (next MDM sync after assignment), every PowerShell session — including the built-in 5.1 host and pwsh 7 — has:

```powershell
wgi <PackageId>          # silent install (machine scope), no prompts
wgup                     # silent upgrade-all
wgu <PackageId>          # silent uninstall
```

The `settings.json` also makes raw `winget install <id>` silent-ish: `--accept-package-agreements --accept-source-agreements --disable-interactivity` are implied by `interactivity.disable: true`, so the only thing missing is `--silent` itself. Train users to use `wgi` / `wgup` / `wgu` for fully zero-prompt operation, or accept the one progress bar that raw `winget install` will show.

UAC for machine-scope installs is the one prompt that cannot be suppressed by configuration — that is a Windows kernel-level prompt, not a winget one. To eliminate it as well, either:

- Use `--scope user` (lose machine-wide installs), or
- Deploy the package through Intune as a Win32 app (component 3), which runs as SYSTEM and never prompts.

---

## 4. Component 3 — Intune Win32 app deployment pattern

For applications that should be pushed by Intune itself (rather than being available for user-initiated install via the CLI), use this canonical Win32 app definition. This is the recommended deployment path for any package that should land on every endpoint without user action.

### 4.1 Standard install / uninstall command lines

| Field | Value |
|---|---|
| **Install command** | `winget install --id <PackageId> --version <Version> --source repofabric --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --scope machine --exact` |
| **Uninstall command** | `winget uninstall --id <PackageId> --source repofabric --silent --disable-interactivity --exact` |
| **Install behavior** | `System` |
| **Device restart behavior** | `App install may force a device restart` (only if any repofabric package legitimately needs reboot; otherwise `No specific action`) |

### 4.2 Detection rule

Use a PowerShell script detection that asks winget directly:

```powershell
$id = '<PackageId>'
$ver = '<Version>'
$out = & winget list --id $id --exact --source repofabric --accept-source-agreements 2>$null
if ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($ver)) {
    Write-Output 'Installed'
    exit 0
}
exit 1
```

### 4.3 Requirements

- **Operating system architecture**: as required by the package
- **Minimum operating system**: Windows 10 1809 (winget pre-installed via Microsoft.DesktopAppInstaller from there onward)
- **Additional requirement rules**: PowerShell script asserting `winget source list` includes `repofabric` (defense-in-depth against assignment ordering issues — the Settings Catalog profile from §2 should land first, but assert it)

---

## 5. Verification

After all three components are assigned and an endpoint has completed an MDM sync, validate from the endpoint:

```powershell
# 1. Source is registered, trusted, and pinned
winget source list
#   NAME    ARGUMENT                                  EXPLICIT  TRUSTLEVEL
#   ...
#   repofabric    https://winget.example.com/api/      false     Trusted

# 2. Hash override is disabled (should print false)
winget settings export | ConvertFrom-Json |
    Select-Object -ExpandProperty installBehavior |
    Select-Object -ExpandProperty disableInstallNotes  # or inspect full JSON

# 3. Wrappers are present in the all-users profile
Get-Content "$env:windir\System32\WindowsPowerShell\v1.0\Profile.ps1" |
    Select-String 'REPOFABRIC always-silent'

# 4. End-to-end smoke
wgi Mozilla.Firefox                # silent install
wgu Mozilla.Firefox                # silent uninstall
```

A green run on all four checks indicates the endpoint configuration is correctly applied.

---

## 6. Rollback

To remove the configuration cleanly:

1. **Unassign** the Settings Catalog profile from §2. Devices lose the additional source on next sync. Manually run `winget source remove repofabric` to remove the orphaned registration.
2. **Unassign** the platform script from §3. The script does not self-uninstall the profile edits; deploy a sibling script that strips the `# --- REPOFABRIC always-silent winget wrappers` block from each profile target and deletes the `settings.json` blobs if a full rollback is needed.
3. **Retire** any Win32 apps that depend on the `repofabric` source first, otherwise their detection rules will fail and Intune will report install failures.

---

## 7. Historical open items

- [x] Publish the Settings Catalog `Enable Additional Sources` and `Enable Allowed Sources` JSON templates as importable files under [`deploy/intune/`](../deploy/intune/) (`repofabric-additional-sources.json`, `repofabric-allowed-sources.json`)
- [x] Ship [`deploy/intune/Set-RfSilentDefaults.ps1`](../deploy/intune/Set-RfSilentDefaults.ps1) as a parameterizable script (`-InstallerHost`)
- [x] Endpoint validation is the smoke command set in section 5, also captured in [`deploy/intune/README.md`](../deploy/intune/README.md). There is no automated endpoint integration test; the documented manual smoke run is the check.
- [ ] Produce a signed `.intunewin` package of `Set-RfSilentDefaults.ps1` so the Intune script signature check can be enabled (deferred to tenant administrator, requires the tenant's script-signing cert)
- [ ] Decide whether to extend the configuration to cover Microsoft Defender SmartScreen overrides at the network level (currently relies on `TrustLevel: Trusted` only)
