#Requires -Version 7.4

<#
    RepoFabric module loader, UNRAID-local fork.
    Dot-sources Private/ first then Public/. Exports per the .psd1 manifest.
#>

$ErrorActionPreference = 'Stop'

$privateFiles = @()
$publicFiles  = @()

$privateRoot = Join-Path $PSScriptRoot 'Private'
$publicRoot  = Join-Path $PSScriptRoot 'Public'

if (Test-Path $privateRoot) {
    $privateFiles = Get-ChildItem -Path $privateRoot -Filter '*.ps1' -Recurse -File |
        Sort-Object FullName
}
if (Test-Path $publicRoot) {
    $publicFiles = Get-ChildItem -Path $publicRoot -Filter '*.ps1' -File |
        Sort-Object FullName
}

foreach ($file in @($privateFiles; $publicFiles)) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

# Module-scoped constants. No Windows local group; admin identity now comes
# from Entra users/groups configured in solution.yaml.
$script:RfModuleName = 'RepoFabric'
$script:RfEdition    = 'linux'
$script:RfStateRoot  = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
$script:RfCacheRoot  = if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) { $env:REPOFABRIC_MANIFEST_CACHE_DIR } else { '/var/cache/repofabric/manifests' }

# $env:COMPUTERNAME is Windows-only. The notification / heartbeat code
# embeds it in email subjects and bodies. Backfill it from .NET's
# cross-platform MachineName so every existing "Host: $env:COMPUTERNAME"
# string keeps working without per-call edits.
if (-not $env:COMPUTERNAME -or [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
    try { $env:COMPUTERNAME = [System.Environment]::MachineName } catch { $env:COMPUTERNAME = 'repofabric-linux' }
}

Export-ModuleMember -Function $publicFiles.BaseName
