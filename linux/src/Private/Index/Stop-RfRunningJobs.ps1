function Stop-RfRunningJobs {
    <#
    .SYNOPSIS
        Hard-stops any in-flight sync or index-refresh ThreadJobs and writes
        a terminal 'failed' status so the next operation can dispatch.

    .DESCRIPTION
        The Start-Rf*Job wrappers gate every new dispatch on the on-disk
        status JSON: phase in {idle, complete, failed, unknown} means free,
        anything else means another op is in flight. When a ThreadJob crashes
        without writing a terminal status (or hangs while the operator waits),
        the gate is closed forever from the listener's point of view.

        This helper exits that wedge:
            1. Iterates every PowerShell job whose name is 'repofabric-sync' or
               'repofabric-index-refresh' and calls Stop-Job + Remove-Job on each.
            2. Writes the status JSON as phase='failed', MarkEnd, with the
               supplied reason. The next Start-Rf*Job call sees a terminal
               phase and is allowed to dispatch.

        Returns a hashtable with the count of jobs stopped and the new status.

    .PARAMETER Reason
        Human-readable text written into the status JSON's error + message
        fields. Surfaced in the operator UI.
    #>
    [CmdletBinding()]
    param(
        [string]$Reason = 'Operator cancelled'
    )

    $names = @('repofabric-sync', 'repofabric-index-refresh')
    $stopped = 0
    foreach ($n in $names) {
        $jobs = @(Get-Job -Name $n -ErrorAction SilentlyContinue)
        foreach ($j in $jobs) {
            try {
                if ($j.State -in @('Running','NotStarted','Suspended','Disconnected')) {
                    Stop-Job -Job $j -ErrorAction SilentlyContinue
                }
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
                $stopped++
            } catch {
                # Best-effort; if removal fails we still want to clear status.
            }
        }
    }

    # Stop-Job is async with respect to OS-level child processes. A killed
    # sparse-checkout job can leave a live git process holding .git/*.lock
    # files, which then blocks the next refresh with "Unable to create
    # index.lock: File exists". Clean those out so the next attempt is
    # not poisoned. The clone dir itself is preserved.
    try {
        $paths = Get-RfPaths
        $gitDir = Join-Path $paths.UpstreamCache 'winget-pkgs' | Join-Path -ChildPath '.git'
        if (Test-Path -LiteralPath $gitDir) {
            $locks = @(Get-ChildItem -Path $gitDir -Filter '*.lock' -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($lock in $locks) {
                try {
                    Remove-Item -LiteralPath $lock.FullName -Force -ErrorAction SilentlyContinue
                    Write-RfLog -Level Information -Message "Cleaned stale git lock: $($lock.FullName)"
                } catch { }
            }
        }
    } catch {
        # Lock cleanup is best-effort. Failure here just means the next
        # refresh might hit the same lock; we still cleared the in-process
        # job state above, so the operator can retry.
    }

    # Force the on-disk status to a terminal state so the gate reopens, even
    # if no live jobs existed (the wedge could have come from a publisher
    # restart while a stale 'starting' row was on disk).
    try {
        Write-RfIndexRefreshStatus `
            -Phase 'failed' `
            -MarkEnd `
            -ErrorText $Reason `
            -Message ("Cancelled by operator (stopped {0} job{1}): {2}" -f $stopped, $(if ($stopped -eq 1) { '' } else { 's' }), $Reason)
    } catch {
        # If status writing itself fails, log it but still return; the caller
        # can decide whether to surface a 500.
    }

    [PSCustomObject]@{
        stopped = $stopped
        status  = (Get-RfIndexRefreshStatus)
    }
}
