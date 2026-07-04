#Requires -Version 5.1
<#
    RepoFabric.Client
    Configure a Windows endpoint to install from a self-hosted RepoFabric private
    WinGet source: register the source as Trusted, set silent-install defaults, map
    the Mark-of-the-Web Local Intranet zone for self-signed / non-standard-port hosts,
    and verify health. No server dependencies; runs on any Windows 10/11 endpoint that
    has WinGet (App Installer). From RingoSystems Heavy Industries.

    Project:       https://github.com/Ringosystems/RepoFabric-Public
    Container image: https://hub.docker.com/r/ringosystems/repofabric
#>

# ---- private helpers -------------------------------------------------------

function Get-RfWingetPath {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'winget' -ErrorAction SilentlyContinue }
    if (-not $cmd) {
        throw 'winget (App Installer) was not found on PATH. Install "App Installer" from the Microsoft Store, then retry.'
    }
    return $cmd.Source
}

function Assert-RfAdmin {
    param([string]$Action = 'perform this operation')
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to $Action. Re-run in an elevated PowerShell session."
    }
}

function Set-RfIntranetZone {
    # Map a URL origin (scheme + host + port) into the Local Intranet zone (value 1)
    # via the Site to Zone Assignment List, so WinGet's Mark-of-the-Web attachment
    # scan does not stall on installers from a self-signed, non-standard-port host.
    # The full URL is used because the per-host map cannot express a port.
    param([Parameter(Mandatory)][string]$Url)
    $origin = $Url
    try { $u = [Uri]$Url; $origin = $u.Scheme + '://' + $u.Authority } catch { }
    $zmk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey'
    if (-not (Test-Path $zmk)) { New-Item -Path $zmk -Force | Out-Null }
    New-ItemProperty -Path $zmk -Name $origin -Value '1' -PropertyType String -Force | Out-Null
    Write-Host "Mapped $origin to the Local Intranet zone."
}

# ---- public cmdlets --------------------------------------------------------

function Register-RfSource {
<#
.SYNOPSIS
    Register a RepoFabric private WinGet source on this endpoint, as a Trusted source.
.DESCRIPTION
    Registers a Microsoft.Rest WinGet source pointing at your RepoFabric instance and
    marks it Trusted so installs run without the source-trust prompt and skip the
    Mark-of-the-Web attachment scan. Optionally trusts a CA certificate (for self-signed
    instances) and maps the source and installer origins into the Local Intranet zone so
    large installers from a self-signed, non-standard-port host do not stall.
    Idempotent. Certificate and registry operations require an elevated session.
.PARAMETER Url
    The RepoFabric REST source URL, for example https://winget.contoso.com/api/
.PARAMETER Name
    Local source name. Default 'repofabric'.
.PARAMETER InstallerSite
    Optional installer origin (scheme://host[:port]) to map into the Intranet zone,
    for example https://installers.winget.contoso.com. Needed only for self-signed or
    non-standard-port hosts.
.PARAMETER CaCertPath
    Optional path to a PEM/CER CA certificate to import into LocalMachine\Root
    (for self-signed RepoFabric instances).
.PARAMETER MapIntranetZone
    Map the source URL origin (and InstallerSite, if supplied) into the Local Intranet zone.
.PARAMETER Untrusted
    Register the source WITHOUT --trust-level trusted (not recommended for RepoFabric).
.EXAMPLE
    Register-RfSource -Url https://winget.contoso.com/api/
.EXAMPLE
    Register-RfSource -Url https://winget.lab.local:8443/api/ -InstallerSite https://installers.lab.local:8443 -CaCertPath .\rf-ca.crt -MapIntranetZone
.LINK
    https://github.com/Ringosystems/RepoFabric-Public
.LINK
    https://hub.docker.com/r/ringosystems/repofabric
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Name = 'repofabric',
        [string]$InstallerSite,
        [string]$CaCertPath,
        [switch]$MapIntranetZone,
        [switch]$Untrusted
    )
    $winget = Get-RfWingetPath

    if ($CaCertPath) {
        Assert-RfAdmin -Action 'import a CA certificate into LocalMachine\Root'
        if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
        if ($PSCmdlet.ShouldProcess('LocalMachine\Root', "Import CA $CaCertPath")) {
            Import-Certificate -FilePath $CaCertPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
            Write-Host "Trusted CA '$CaCertPath' (LocalMachine\Root)."
        }
    }

    if ($PSCmdlet.ShouldProcess($Name, "Register WinGet source -> $Url")) {
        & $winget source remove --name $Name 2>$null | Out-Null
        $addArgs = @('source', 'add', '--name', $Name, '--arg', $Url, '--type', 'Microsoft.Rest', '--accept-source-agreements')
        if ($Untrusted) {
            & $winget @addArgs 2>$null | Out-Null
        } else {
            & $winget @addArgs --trust-level trusted 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'winget did not accept --trust-level (older build?); retrying without it.'
                & $winget @addArgs 2>$null | Out-Null
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "winget source add failed (exit $LASTEXITCODE). Confirm the host resolves (add a hosts entry for a self-signed hostname), the CA is trusted, and the URL ends in /api/."
        }
        Write-Host "Registered WinGet source '$Name' -> $Url"
    }

    if ($MapIntranetZone) {
        Assert-RfAdmin -Action 'map the Local Intranet zone (HKLM)'
        Set-RfIntranetZone -Url $Url
        if ($InstallerSite) { Set-RfIntranetZone -Url $InstallerSite }
    }
}

function Unregister-RfSource {
<#
.SYNOPSIS
    Remove a RepoFabric WinGet source from this endpoint.
.PARAMETER Name
    Source name to remove. Default 'repofabric'.
.EXAMPLE
    Unregister-RfSource -Name repofabric
.LINK
    https://github.com/Ringosystems/RepoFabric-Public
#>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name = 'repofabric')
    $winget = Get-RfWingetPath
    if ($PSCmdlet.ShouldProcess($Name, 'Remove WinGet source')) {
        & $winget source remove --name $Name
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "winget source remove returned exit $LASTEXITCODE (the source may not exist)."
        } else {
            Write-Host "Removed WinGet source '$Name'."
        }
    }
}

function Get-RfSource {
<#
.SYNOPSIS
    List the RepoFabric (Microsoft.Rest) WinGet sources registered on this endpoint.
.PARAMETER Name
    Return only the source with this exact name.
.EXAMPLE
    Get-RfSource
.LINK
    https://github.com/Ringosystems/RepoFabric-Public
#>
    [CmdletBinding()]
    param([string]$Name)
    $winget = Get-RfWingetPath
    $raw = & $winget source export 2>$null | Out-String
    $sources = @()
    try { $sources = @($raw | ConvertFrom-Json) } catch { $sources = @() }
    foreach ($s in $sources) {
        if ($Name) { if ($s.Name -ne $Name) { continue } }
        elseif (-not ($s.Type -eq 'Microsoft.Rest' -or "$($s.Arg)" -match '/api')) { continue }
        [pscustomobject]@{
            Name     = $s.Name
            Argument = $s.Arg
            Type     = $s.Type
        }
    }
}

function Set-RfClientDefault {
<#
.SYNOPSIS
    Make WinGet installs silent, non-interactive, and machine-scoped on this endpoint.
.DESCRIPTION
    Writes winget settings.json (machine scope, interactivity disabled) so packages from
    the RepoFabric source install silently. AllUsers scope writes the default-user profile
    and every existing user profile (requires elevation); CurrentUser writes only the
    current user. Optionally installs wgi/wgu/wgup convenience wrappers into the all-users
    PowerShell profiles, and maps an installer origin into the Local Intranet zone.
    Mirrors the Intune platform script deploy/intune/Set-RfSilentDefaults.ps1.
.PARAMETER InstallerSite
    Optional installer origin to map into the Intranet zone (requires elevation).
.PARAMETER InstallWrappers
    Also add Install-/Uninstall-/Upgrade-WingetSilent wrappers (wgi/wgu/wgup) to the
    all-users PowerShell profiles.
.PARAMETER Scope
    'AllUsers' (default, requires elevation) or 'CurrentUser'.
.EXAMPLE
    Set-RfClientDefault
.EXAMPLE
    Set-RfClientDefault -Scope CurrentUser
.LINK
    https://github.com/Ringosystems/RepoFabric-Public
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$InstallerSite,
        [switch]$InstallWrappers,
        [ValidateSet('AllUsers', 'CurrentUser')][string]$Scope = 'AllUsers'
    )

    $settingsJson = @{
        '$schema'       = 'https://aka.ms/winget-settings.schema.json'
        installBehavior = @{ preferences = @{ scope = 'machine' } }
        interactivity   = @{ disable = $true }
    } | ConvertTo-Json -Depth 6
    $relPath = 'AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'

    if ($Scope -eq 'CurrentUser') {
        $target = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
        if ($PSCmdlet.ShouldProcess($target, 'Write winget settings.json (current user)')) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Set-Content -Path $target -Value $settingsJson -Encoding UTF8
            Write-Host "Wrote silent-install settings for the current user."
        }
    } else {
        Assert-RfAdmin -Action 'write machine-wide winget defaults (AllUsers)'
        if ($PSCmdlet.ShouldProcess('all users', 'Write winget settings.json')) {
            $defaultUserDir = Join-Path "$env:SystemDrive\Users\Default" (Split-Path -Parent $relPath)
            New-Item -ItemType Directory -Force -Path $defaultUserDir | Out-Null
            Set-Content -Path (Join-Path $defaultUserDir 'settings.json') -Value $settingsJson -Encoding UTF8
            Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin 'Default', 'Public', 'All Users', 'Default User' } |
                ForEach-Object {
                    $t = Join-Path $_.FullName $relPath
                    if (Test-Path (Split-Path -Parent $t)) {
                        Set-Content -Path $t -Value $settingsJson -Encoding UTF8
                    }
                }
            Write-Host "Wrote silent-install settings for the default and existing user profiles."
        }
    }

    if ($InstallWrappers) {
        $profileBody = @'
# --- REPOFABRIC always-silent winget wrappers ------------------------------------
function Install-WingetSilent { [CmdletBinding()] param([Parameter(Mandatory, Position = 0)][string]$Id, [Parameter(ValueFromRemainingArguments)]$Rest) & winget.exe install --id $Id --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --scope machine --exact @Rest }
function Uninstall-WingetSilent { [CmdletBinding()] param([Parameter(Mandatory, Position = 0)][string]$Id, [Parameter(ValueFromRemainingArguments)]$Rest) & winget.exe uninstall --id $Id --silent --disable-interactivity --exact @Rest }
function Upgrade-WingetSilent { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$Rest) & winget.exe upgrade --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --scope machine @Rest }
Set-Alias wgi Install-WingetSilent
Set-Alias wgu Uninstall-WingetSilent
Set-Alias wgup Upgrade-WingetSilent
# ---------------------------------------------------------------------------
'@
        $profileTargets = if ($Scope -eq 'CurrentUser') {
            @($PROFILE.CurrentUserAllHosts)
        } else {
            @("$env:windir\System32\WindowsPowerShell\v1.0\Profile.ps1", 'C:\Program Files\PowerShell\7\Profile.ps1')
        }
        foreach ($p in $profileTargets) {
            $dir = Split-Path -Parent $p
            if (-not (Test-Path $dir)) { continue }
            $existing = if (Test-Path $p) { Get-Content -Raw $p } else { '' }
            if ($existing -notmatch '# --- REPOFABRIC always-silent winget wrappers') {
                if ($PSCmdlet.ShouldProcess($p, 'Add winget silent wrappers')) {
                    Add-Content -Path $p -Value "`r`n$profileBody`r`n"
                    Write-Host "Added wgi/wgu/wgup wrappers to $p"
                }
            }
        }
    }

    if ($InstallerSite) {
        Assert-RfAdmin -Action 'map the Local Intranet zone (HKLM)'
        Set-RfIntranetZone -Url $InstallerSite
    }
}

function Test-RfClientHealth {
<#
.SYNOPSIS
    Verify this endpoint is configured to install from a RepoFabric source.
.DESCRIPTION
    Reports on: winget presence, whether the named RepoFabric source is registered,
    whether its REST endpoint responds, whether machine-scope silent defaults are set,
    and whether the source origin is mapped into the Local Intranet zone. Returns one
    result object per check.
.PARAMETER Name
    Source name to check. Default 'repofabric'.
.EXAMPLE
    Test-RfClientHealth | Format-Table
.LINK
    https://github.com/Ringosystems/RepoFabric-Public
#>
    [CmdletBinding()]
    param([string]$Name = 'repofabric')

    $results = New-Object System.Collections.Generic.List[object]
    function Add-Result { param($n, $ok, $detail) $results.Add([pscustomobject]@{ Check = $n; Status = $(if ($ok) { 'Pass' } else { 'Fail' }); Detail = $detail }) }

    $winget = $null
    try { $winget = Get-RfWingetPath; Add-Result 'winget present' $true $winget }
    catch { Add-Result 'winget present' $false $_.Exception.Message; return $results }

    $src = Get-RfSource -Name $Name | Select-Object -First 1
    Add-Result "source '$Name' registered" ([bool]$src) $(if ($src) { $src.Argument } else { 'not registered' })

    if ($src -and $src.Argument) {
        try {
            $probe = ($src.Argument.TrimEnd('/')) + '/information'
            $resp = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Add-Result 'source REST endpoint responds' ($resp.StatusCode -eq 200) "HTTP $($resp.StatusCode) from $probe"
        } catch {
            Add-Result 'source REST endpoint responds' $false $_.Exception.Message
        }
    }

    $userSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    Add-Result 'silent defaults present' (Test-Path $userSettings) $userSettings

    if ($src -and $src.Argument) {
        $origin = $src.Argument
        try { $u = [Uri]$src.Argument; $origin = $u.Scheme + '://' + $u.Authority } catch { }
        $zmk = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey'
        $mapped = $false
        try { $mapped = [bool](Get-ItemProperty -Path $zmk -Name $origin -ErrorAction Stop) } catch { }
        Add-Result 'Intranet zone mapped' $mapped $origin
    }

    return $results
}

Export-ModuleMember -Function Register-RfSource, Unregister-RfSource, Get-RfSource, Set-RfClientDefault, Test-RfClientHealth
