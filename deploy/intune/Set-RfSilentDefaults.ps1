<#
.SYNOPSIS
  Forces every winget install, upgrade, and uninstall on this endpoint to be
  silent and non-interactive, for all users. Deployed via Intune as a SYSTEM-
  context platform script (or run-once Win32 app).

.DESCRIPTION
  Idempotent. Safe to re-run. Logs to
  C:\ProgramData\REPOFABRIC\Logs\Set-RfSilentDefaults.log

  Companion to the Settings Catalog profile in
  deploy/intune/repofabric-additional-sources.json. See
  docs/Intune-EndpointConfiguration.md for the full design.

.PARAMETER InstallerSite
  Base URL (scheme, host, and port) of the installer download endpoint to map into
  the machine-wide Intranet Zone. The full URL is used so a non-standard port is
  honored (the per-host zone map cannot express a port). Default:
  'https://installers.winget.example.com'.

.NOTES
  Operated by RingoSystems Heavy Industries.
#>
[CmdletBinding()]
param(
    [string]$InstallerSite = 'https://installers.winget.example.com'
)

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
Set-Alias wgi  Install-WingetSilent
Set-Alias wgu  Uninstall-WingetSilent
Set-Alias wgup Upgrade-WingetSilent
# ---------------------------------------------------------------------------
'@

    $profileTargets = @(
        "$env:windir\System32\WindowsPowerShell\v1.0\Profile.ps1",
        'C:\Program Files\PowerShell\7\Profile.ps1'
    )

    foreach ($p in $profileTargets) {
        $dir = Split-Path -Parent $p
        if (-not (Test-Path $dir)) { continue }
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
        '$schema'       = 'https://aka.ms/winget-settings.schema.json'
        installBehavior = @{ preferences = @{ scope = 'machine' } }
        interactivity   = @{ disable = $true }
    } | ConvertTo-Json -Depth 6

    $relPath = 'AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'

    $defaultUserDir = "$env:SystemDrive\Users\Default\$(Split-Path -Parent $relPath)"
    $null = New-Item -ItemType Directory -Force -Path $defaultUserDir
    Set-Content -Path (Join-Path $defaultUserDir 'settings.json') -Value $settings -Encoding UTF8

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

    # --- 3. Intranet Zone: map the installer site at machine scope -----------
    # Site to Zone Assignment List (ZoneMapKey), keyed on the FULL URL (scheme, host,
    # and port). The Intranet Zone is the low-risk zone whose downloads skip the
    # attachment scan, so winget's Mark-of-the-Web step does not stall on installers
    # from this origin. The per-host map cannot express a non-standard port; the
    # full-URL list can.
    $installerOrigin = $InstallerSite
    try { $u = [Uri]$InstallerSite; $installerOrigin = $u.Scheme + '://' + $u.Authority } catch { }
    $zmk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey'
    $null = New-Item -Path $zmk -Force
    New-ItemProperty -Path $zmk -Name $installerOrigin -Value '1' -PropertyType String -Force | Out-Null
    Write-Host "Mapped $installerOrigin to the Intranet Zone (HKLM)"

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
