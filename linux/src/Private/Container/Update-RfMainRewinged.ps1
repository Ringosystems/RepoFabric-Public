function Update-RfMainRewinged {
    <#
    .SYNOPSIS
        Restart the 'main' repo's Rewinged container so a freshly-published
        manifest is served.

    .DESCRIPTION
        The main Rewinged container (${REPOFABRIC_INSTANCE}-rewinged, provisioned
        by the compose file -- NOT the docker-driver, which refuses RepoId 'main')
        scans its -manifestPath ONLY at startup. Its fsnotify watch does not fire
        for the publisher's writes: the publisher and Rewinged bind-mount the same
        host manifest directory from different containers, and cross-container
        inotify does not propagate; Rewinged also exposes no poll option. So a
        restart is the only way to surface newly-published manifests (manifests-
        init in the compose file only guarantees the dir exists at boot; it does
        not make the watch fire).

        Called by the sync workers after a changed publish to the main repo.
        Throttled via a shared timestamp file so simultaneous workers collapse
        into roughly one restart per window; docker also serialises genuinely-
        concurrent restarts. Best-effort: any failure is swallowed -- the manifest
        is already durable in Gitea and on disk, so a later publish or a manual
        restart still surfaces it.

    .PARAMETER ThrottleSeconds
        Minimum seconds between restarts (collapses a burst of near-simultaneous
        worker publishes into one restart). Default 5.

    .OUTPUTS
        [bool] $true when a restart was issued, $false when throttled or on error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$ThrottleSeconds = 5)

    try {
        $stateDir = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
        $stamp = Join-Path $stateDir 'rewinged-last-reload'
        $now = Get-Date
        if (Test-Path $stamp) {
            $last = [datetime]::MinValue
            if ([datetime]::TryParse([System.IO.File]::ReadAllText($stamp), [ref]$last) -and
                ($now - $last).TotalSeconds -lt $ThrottleSeconds) {
                return $false
            }
        }
        # Claim this window before the (slow) restart so a parallel worker throttles.
        [System.IO.File]::WriteAllText($stamp, $now.ToString('o'))
        $inst = if ($env:REPOFABRIC_INSTANCE) { $env:REPOFABRIC_INSTANCE } else { 'repofabric' }
        # Arg-array invocation; the name is env-derived (not caller input).
        & docker restart --time 5 "$inst-rewinged" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
