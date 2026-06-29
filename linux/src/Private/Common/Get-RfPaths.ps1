function Get-RfPaths {
    <#
    .SYNOPSIS
        Returns the canonical filesystem paths used by RepoFabric on
        the Linux UNRAID-local fork.

    .DESCRIPTION
        The Windows version rooted everything under %ProgramData%. The
        Linux fork roots everything under /var/lib/repofabric by default, with
        $env:REPOFABRIC_STATE_DIR allowing override. Cache is per-state-dir
        unless callers override via a Configuration object.

    .PARAMETER Configuration
        Optional. A hashtable shaped like the merged config from
        Get-RfConfiguration.

    .OUTPUTS
        PSCustomObject with named path properties.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [hashtable]$Configuration
    )

    # Linux default. Windows is unreachable in this fork; the path under
    # %ProgramData% would not be discoverable from a Linux container anyway.
    $installRoot = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }

    if ($Configuration -and $Configuration.paths) {
        $p = $Configuration.paths
        $cacheDir   = if ($p.cache_dir)   { [string]$p.cache_dir }   else { Join-Path $installRoot 'cache' }
        $stagingDir = if ($p.staging_dir) { [string]$p.staging_dir } else { Join-Path $installRoot 'staging' }
        $logDir     = if ($p.log_dir)     { [string]$p.log_dir }     else { Join-Path $installRoot 'logs' }
        $stateDb    = if ($p.state_db)    { [string]$p.state_db }    else { Join-Path $installRoot 'state.sqlite' }
        return [PSCustomObject]@{
            InstallRoot   = $installRoot
            StateDir      = $installRoot
            CacheDir      = $cacheDir
            StagingDir    = $stagingDir
            LogDir        = $logDir
            StateDb       = $stateDb
            ConfigDir     = Join-Path $installRoot 'config'
            ConfigFile    = Join-Path $installRoot 'config/service.yaml'
            ServiceConfig = Join-Path $installRoot 'config/service.yaml'
            SolutionConfig= Join-Path $installRoot 'config/solution.yaml'
            SubsFile      = Join-Path $installRoot 'subscriptions.yaml'
            KeysDir       = Join-Path $installRoot 'keys'
            UpstreamCache = Join-Path $cacheDir 'winget-pkgs'
            RefreshLock   = Join-Path $cacheDir '.refresh.lock'
            SyncLock      = Join-Path $installRoot '.sync.lock'
        }
    }

    [PSCustomObject]@{
        InstallRoot   = $installRoot
        StateDir      = $installRoot
        CacheDir      = Join-Path $installRoot 'cache'
        StagingDir    = Join-Path $installRoot 'staging'
        LogDir        = Join-Path $installRoot 'logs'
        StateDb       = Join-Path $installRoot 'state.sqlite'
        ConfigDir     = Join-Path $installRoot 'config'
        ConfigFile    = Join-Path $installRoot 'config/service.yaml'
        ServiceConfig = Join-Path $installRoot 'config/service.yaml'
        SolutionConfig= Join-Path $installRoot 'config/solution.yaml'
        SubsFile      = Join-Path $installRoot 'subscriptions.yaml'
        KeysDir       = Join-Path $installRoot 'keys'
        UpstreamCache = Join-Path $installRoot 'cache/winget-pkgs'
        RefreshLock   = Join-Path $installRoot 'cache/.refresh.lock'
        SyncLock      = Join-Path $installRoot '.sync.lock'
    }
}
