#requires -Version 7.0
<#
.SYNOPSIS
    Interactively generate a correct RepoFabric .env file (instead of hand-editing
    .env.example in a text editor).

.DESCRIPTION
    Collects the handful of values RepoFabric actually needs and writes a clean
    .env next to docker-compose.yml. It writes LF line endings with no BOM so the
    file is valid on the Linux host that runs the stack (a CRLF .env puts a stray
    carriage return in every value and breaks docker compose).

    Microsoft sign-in and the Gitea token are deliberately NOT asked for: the
    wizard's Identity step generates the Entra app for you, and the bundled Gitea
    is auto-provisioned. You are only prompted for what must be decided up front.

    Run it with no arguments for a guided Q&A, or pass any value as a parameter to
    skip that question. Add -NoPrompt to fail (rather than prompt) on anything
    missing -- useful for automation.

.EXAMPLE
    ./deploy/New-RepoFabricEnv.ps1
    Guided setup, writing ../.env relative to this script.

.EXAMPLE
    ./deploy/New-RepoFabricEnv.ps1 -Mode proxy -Instance repofabric-test -Domain winget-test.example.com
    Side-by-side test instance behind your own reverse proxy.

.NOTES
    After it writes .env:
      greenfield ->  docker compose --profile proxy up -d
      proxy/side ->  docker compose up -d
    then open  https://<domain>/setup/
#>
[CmdletBinding()]
param(
    [ValidateSet('greenfield', 'proxy')] [string]$Mode,
    [string]$Domain,
    [string]$AcmeEmail,
    [string]$SessionSecret,
    [string]$Instance,
    [string]$StateRoot,
    [string]$AppdataRoot,
    [string]$AdminPort,
    [string]$InstallersPort,
    [string]$RewingedPort,
    [string]$GiteaPort,
    [string]$EntraTenantId,
    [string]$EntraClientId,
    [string]$EntraClientSecret,
    [string]$GiteaPat,
    [string]$Path,
    [switch]$NoPrompt,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- standard host ports (the primary 'repofabric' instance) ----------------
$DEFAULT_PORTS = @{ Admin = '8086'; Installers = '8091'; Rewinged = '8090'; Gitea = '3030' }
$DEFAULT_STATE = '/mnt/cache/appdata/repofabric-linux'   # UNRAID layout
$DEFAULT_APPDATA = '/mnt/user/appdata/repofabric'

# --- helpers ----------------------------------------------------------------
function New-SessionSecret {
    # 32 random bytes -> 64 lowercase hex chars (equivalent to: openssl rand -hex 32).
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Test-Domain { param([string]$v) $v -match '^(?=.{1,253}$)([A-Za-z0-9](([A-Za-z0-9-]*[A-Za-z0-9])?)\.)+[A-Za-z]{2,}$' }
function Test-Email  { param([string]$v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' }
function Test-Port   { param([string]$v) ($v -match '^\d+$') -and ([int]$v -ge 1) -and ([int]$v -le 65535) }
function Test-Instance { param([string]$v) $v -match '^[a-z0-9][a-z0-9-]*$' }   # docker name-safe

function Resolve-Value {
    param(
        [string]$Name,
        [string]$Prompt,
        [string]$Provided,
        [string]$Default = '',
        [scriptblock]$Validate,
        [string]$ValidateHint = 'That value is not valid.',
        [switch]$Required
    )
    # 1) supplied via parameter -> validate and use.
    if (-not [string]::IsNullOrWhiteSpace($Provided)) {
        $v = $Provided.Trim()
        if ($Validate -and -not (& $Validate $v)) { throw "$Name`: $ValidateHint (got '$v')" }
        return $v
    }
    # 2) non-interactive.
    if ($NoPrompt) {
        if (-not [string]::IsNullOrWhiteSpace($Default)) { return $Default }
        if ($Required) { throw "$Name is required but was not provided (running with -NoPrompt)." }
        return ''
    }
    # 3) prompt, looping until valid.
    while ($true) {
        $tag = if ($Default) { " [$Default]" } elseif ($Required) { ' (required)' } else { ' (optional, press Enter to skip)' }
        $raw = Read-Host "$Prompt$tag"
        $v = if ([string]::IsNullOrWhiteSpace($raw)) { $Default } else { $raw.Trim() }
        if ([string]::IsNullOrWhiteSpace($v)) {
            if ($Required) { Write-Host '  This value is required.' -ForegroundColor Yellow; continue }
            return ''
        }
        if ($Validate -and -not (& $Validate $v)) { Write-Host "  $ValidateHint" -ForegroundColor Yellow; continue }
        return $v
    }
}

function Confirm-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    if ($NoPrompt -or $Force) { return $DefaultYes }
    $tag = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $raw = (Read-Host "$Prompt [$tag]").Trim().ToLower()
        if ($raw -eq '') { return $DefaultYes }
        if ($raw -in @('y', 'yes')) { return $true }
        if ($raw -in @('n', 'no')) { return $false }
    }
}

# --- resolve target path ----------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $repoRoot '.env' }

Write-Host ''
Write-Host 'RepoFabric .env generator' -ForegroundColor Cyan
Write-Host '-------------------------'

# --- mode -------------------------------------------------------------------
if (-not $Mode) {
    if ($NoPrompt) { throw 'A -Mode (greenfield|proxy) is required with -NoPrompt.' }
    Write-Host ''
    Write-Host 'How will HTTPS be handled?'
    Write-Host '  1) Greenfield  - this host owns ports 80/443; use the bundled Caddy (automatic HTTPS).'
    Write-Host '  2) Behind a proxy / side-by-side - you already run a reverse proxy, or want a 2nd instance.'
    while (-not $Mode) {
        switch ((Read-Host 'Choose 1 or 2').Trim()) {
            '1' { $Mode = 'greenfield' }
            '2' { $Mode = 'proxy' }
        }
    }
}
$greenfield = ($Mode -eq 'greenfield')
Write-Host ("Mode: {0}" -f $(if ($greenfield) { 'greenfield (bundled Caddy)' } else { 'behind your own proxy / side-by-side' })) -ForegroundColor DarkGray

# --- core values ------------------------------------------------------------
$domain = Resolve-Value -Name 'REPOFABRIC_DOMAIN' -Prompt 'Public hostname operators + endpoints use (e.g. winget.example.com)' `
    -Provided $Domain -Validate ${function:Test-Domain} -ValidateHint 'Expected a DNS hostname like winget.example.com.' -Required

# NB: result variables must NOT match a parameter name -- PowerShell variables are
# case-insensitive, so $acmeEmail would alias the $AcmeEmail parameter and clobber it.
$acmeOut = ''
if ($greenfield) {
    $acmeOut = Resolve-Value -Name 'REPOFABRIC_ACME_EMAIL' -Prompt "Email for the Let's Encrypt certificate (expiry notices)" `
        -Provided $AcmeEmail -Validate ${function:Test-Email} -ValidateHint 'Expected an email address.' -Required
}

# session secret: offer to generate.
$secret = $SessionSecret
if ([string]::IsNullOrWhiteSpace($secret)) {
    if (Confirm-YesNo 'Generate a random session secret automatically?' $true) {
        $secret = New-SessionSecret
        Write-Host '  Generated a 64-character session secret.' -ForegroundColor DarkGray
    }
    else {
        $secret = Resolve-Value -Name 'REPOFABRIC_SESSION_SECRET' -Prompt 'Paste a session secret (64 hex chars; run: openssl rand -hex 32)' `
            -Provided '' -Validate { param($v) $v -match '^[0-9a-fA-F]{32,}$' } -ValidateHint 'Expected at least 32 hex characters.' -Required
    }
}

# --- instance + ports + storage --------------------------------------------
$defInstance = if ($greenfield) { 'repofabric' } else { 'repofabric-test' }
$instance = Resolve-Value -Name 'REPOFABRIC_INSTANCE' -Prompt 'Instance name (namespaces containers, network, volumes)' `
    -Provided $Instance -Default $defInstance -Validate ${function:Test-Instance} -ValidateHint 'Use lowercase letters, digits and hyphens.'

# For a side-by-side instance, suggest distinct ports + storage so it cannot
# collide with a running one; for the primary instance keep the standard values.
$sideBySide = (-not $greenfield) -and ($instance -ne 'repofabric')
$portDefaults = if ($sideBySide) {
    @{ Admin = '8096'; Installers = '8101'; Rewinged = '8100'; Gitea = '3040' }
}
else { $DEFAULT_PORTS }

$ports = @{}
$portProvided = -not ([string]::IsNullOrWhiteSpace($AdminPort) -and [string]::IsNullOrWhiteSpace($InstallersPort) -and [string]::IsNullOrWhiteSpace($RewingedPort) -and [string]::IsNullOrWhiteSpace($GiteaPort))
$customizePorts = $sideBySide -or $portProvided -or (-not $greenfield -and (Confirm-YesNo 'Customize host ports?' $false))
if ($customizePorts) {
    if ($sideBySide) { Write-Host '  Side-by-side: these MUST differ from the running instance.' -ForegroundColor Yellow }
    $ports.Admin = Resolve-Value -Name 'REPOFABRIC_ADMIN_HOST_PORT' -Prompt '  Admin UI host port' -Provided $AdminPort -Default $portDefaults.Admin -Validate ${function:Test-Port} -ValidateHint 'Port 1-65535.'
    $ports.Installers = Resolve-Value -Name 'REPOFABRIC_INSTALLERS_HOST_PORT' -Prompt '  Installer file-server host port' -Provided $InstallersPort -Default $portDefaults.Installers -Validate ${function:Test-Port} -ValidateHint 'Port 1-65535.'
    $ports.Rewinged = Resolve-Value -Name 'REPOFABRIC_REWINGED_HOST_PORT' -Prompt '  rewinged host port' -Provided $RewingedPort -Default $portDefaults.Rewinged -Validate ${function:Test-Port} -ValidateHint 'Port 1-65535.'
    $ports.Gitea = Resolve-Value -Name 'REPOFABRIC_GITEA_HOST_PORT' -Prompt '  Gitea host port' -Provided $GiteaPort -Default $portDefaults.Gitea -Validate ${function:Test-Port} -ValidateHint 'Port 1-65535.'
}

# storage roots: default to instance-suffixed paths so two instances never share state.
$defState = if ($instance -eq 'repofabric') { $DEFAULT_STATE } else { "/mnt/cache/appdata/$instance-linux" }
$defAppdata = if ($instance -eq 'repofabric') { $DEFAULT_APPDATA } else { "/mnt/user/appdata/$instance" }
$storageProvided = -not ([string]::IsNullOrWhiteSpace($StateRoot) -and [string]::IsNullOrWhiteSpace($AppdataRoot))
$customizeStorage = $sideBySide -or $storageProvided -or (Confirm-YesNo "Set storage paths? (defaults: $defState, $defAppdata)" $false)
$stateOut = ''
$appdataOut = ''
if ($customizeStorage) {
    $stateOut = Resolve-Value -Name 'REPOFABRIC_STATE_ROOT' -Prompt '  State root (SSD; service state)' -Provided $StateRoot -Default $defState
    $appdataOut = Resolve-Value -Name 'REPOFABRIC_APPDATA_ROOT' -Prompt '  Appdata root (bulk; manifests + installer cache + gitea)' -Provided $AppdataRoot -Default $defAppdata
}

# --- optional pre-seeded Entra / external Gitea (advanced) -------------------
# Only written if explicitly provided via parameters; the prompts default to the
# automated paths and stay blank.
$entraTid = $EntraTenantId; $entraCid = $EntraClientId; $entraSecret = $EntraClientSecret
$giteaPat = $GiteaPat

# --- build .env -------------------------------------------------------------
$startCmd = if ($greenfield) { 'docker compose --profile proxy up -d' } else { 'docker compose up -d' }
$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$s = '') $lines.Add($s) }

Add-Line '# RepoFabric environment - generated by deploy/New-RepoFabricEnv.ps1'
Add-Line ("# Mode: {0}" -f $(if ($greenfield) { 'greenfield (bundled Caddy, automatic HTTPS)' } else { 'behind your own reverse proxy / side-by-side' }))
Add-Line ("# Start:  {0}" -f $startCmd)
Add-Line '# Then open  https://<domain>/setup/  and follow the wizard.'
Add-Line ''
Add-Line '# ---- required ----'
Add-Line "REPOFABRIC_DOMAIN=$domain"
if ($greenfield) { Add-Line "REPOFABRIC_ACME_EMAIL=$acmeOut" }
Add-Line "REPOFABRIC_SESSION_SECRET=$secret"
Add-Line ''
Add-Line '# ---- Microsoft sign-in: leave blank and generate it in the wizard Identity step ----'
Add-Line "REPOFABRIC_ENTRA_TENANT_ID=$entraTid"
Add-Line "REPOFABRIC_ENTRA_CLIENT_ID=$entraCid"
Add-Line "REPOFABRIC_ENTRA_CLIENT_SECRET=$entraSecret"
Add-Line ''
Add-Line '# ---- Gitea is auto-provisioned; leave unset. Set only to use your OWN Gitea token. ----'
if ([string]::IsNullOrWhiteSpace($giteaPat)) { Add-Line '#REPOFABRIC_GITEA_PAT=' } else { Add-Line "REPOFABRIC_GITEA_PAT=$giteaPat" }
Add-Line ''
Add-Line '# ---- instance / side-by-side ----'
Add-Line "REPOFABRIC_INSTANCE=$instance"
if ($ports.Count -gt 0) {
    Add-Line "REPOFABRIC_ADMIN_HOST_PORT=$($ports.Admin)"
    Add-Line "REPOFABRIC_INSTALLERS_HOST_PORT=$($ports.Installers)"
    Add-Line "REPOFABRIC_REWINGED_HOST_PORT=$($ports.Rewinged)"
    Add-Line "REPOFABRIC_GITEA_HOST_PORT=$($ports.Gitea)"
}
if ($customizeStorage) {
    Add-Line ''
    Add-Line '# ---- storage (must differ between instances) ----'
    Add-Line "REPOFABRIC_STATE_ROOT=$stateOut"
    Add-Line "REPOFABRIC_APPDATA_ROOT=$appdataOut"
}
$content = ($lines -join "`n") + "`n"

# --- confirm + write (LF, no BOM) ------------------------------------------
Write-Host ''
Write-Host "About to write $Path :" -ForegroundColor Cyan
Write-Host ($content -replace '(REPOFABRIC_SESSION_SECRET=)(.*)', '$1********') -ForegroundColor DarkGray

if ((Test-Path -LiteralPath $Path) -and -not $Force) {
    if (-not (Confirm-YesNo "$Path already exists. Back it up and overwrite?" $true)) {
        Write-Host 'Aborted; existing .env left untouched.' -ForegroundColor Yellow
        return
    }
}
if (Test-Path -LiteralPath $Path) {
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $backup = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Host "Backed up existing .env -> $backup" -ForegroundColor DarkGray
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)

Write-Host ''
Write-Host "Wrote $Path" -ForegroundColor Green
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  cd `"$repoRoot`""
Write-Host "  $startCmd"
Write-Host "  # then open  https://$domain/setup/"
