function Start-RfSyncJob {
    <#
    .SYNOPSIS
        Runs Sync-RfSubscriptions inside a Start-ThreadJob runspace and
        returns immediately, letting the HttpListener thread keep serving
        status polls.

    .DESCRIPTION
        Sync-RfSubscriptions can run for many minutes (especially with
        -ForceIndexRefresh, which subsumes the full upstream walk). NPM's
        proxy_read_timeout (~60s) closes the connection long before the
        work completes, so the browser sees 504 while the publisher is
        still running. This wrapper offloads the work to a ThreadJob and
        the operator polls the shared status file for progress.

        Module-private commands (Write-RfIndexRefreshStatus, etc.) are
        dispatched through the module's session state via & (Get-Module ...)
        because the ThreadJob's scriptblock runs in the worker runspace's
        TOP-LEVEL scope, where Import-Module only exposes the manifest's
        FunctionsToExport list and private helpers are invisible.

    .PARAMETER ForceIndexRefresh
        Forwarded to Sync-RfSubscriptions.

    .PARAMETER SkipIndexRefresh
        Forwarded to Sync-RfSubscriptions.

    .PARAMETER SubscriptionId
        Optional integer array of subscription ids to sync.
    #>
    [CmdletBinding()]
    param(
        [switch]$ForceIndexRefresh,
        [switch]$SkipIndexRefresh,
        [int[]]$SubscriptionId
    )

    $current = Get-RfIndexRefreshStatus
    $terminalPhases = @('idle','complete','failed','unknown')
    if ($current.phase -and ($terminalPhases -notcontains $current.phase)) {
        return [PSCustomObject]@{
            accepted = $false
            reason   = 'already_running'
            status   = $current
        }
    }

    $module = Get-Module RepoFabric
    if (-not $module) { throw 'RepoFabric module is not loaded in this session; cannot start ThreadJob.' }
    $psd1Path = $module.Path

    # Linux-aware log path; $env:ProgramData is Windows-only and was null
    # on the linux fork, causing Join-Path to throw at refresh kick-off.
    $stateRoot = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
    $logForInit = Join-Path $stateRoot 'logs/threadjob-debug.log'
    $initScript = [scriptblock]::Create(@"
try { Add-Content -LiteralPath '$logForInit' -Value ("{0} init: starting import of $psd1Path" -f (Get-Date).ToString('o')) -ErrorAction SilentlyContinue } catch {}
Import-Module '$psd1Path' -Force -ErrorAction Stop
try { Add-Content -LiteralPath '$logForInit' -Value ("{0} init: module imported OK" -f (Get-Date).ToString('o')) -ErrorAction SilentlyContinue } catch {}
"@)
    $job = Start-ThreadJob -Name 'repofabric-sync' -InitializationScript $initScript -ScriptBlock {
        param([bool]$Force, [bool]$Skip, [int[]]$SubIds, [string]$LogPath)
        $logPath = $LogPath
        function Log-Debug($msg) {
            try { Add-Content -LiteralPath $logPath -Value ("{0} sync: {1}" -f (Get-Date).ToString('o'), $msg) -ErrorAction SilentlyContinue } catch {}
        }

        # Resolve the module object IN THIS RUNSPACE; the InitializationScript
        # already imported it. Subsequent & $mod { ... } invocations execute in
        # the module's session state where private functions are visible.
        $mod = Get-Module RepoFabric
        if (-not $mod) {
            Log-Debug "FATAL: RepoFabric module not loaded in worker runspace"
            return
        }
        function Invoke-RfStatusWrite {
            param([hashtable]$Params)
            & $mod ([scriptblock]::Create('param($p) Write-RfIndexRefreshStatus @p')) $Params
        }

        Log-Debug "thread started Force=$Force Skip=$Skip Subs=$($SubIds -join ',')"
        try {
            Invoke-RfStatusWrite @{ Phase = 'starting'; MarkStart = $true; Message = 'Sync starting' }
            # Trigger must be one of {scheduled,manual,force} per Sync-RfSubscriptions
            # ValidateSet. Web-initiated runs surface as 'manual' in the audit row.
            $syncArgs = @{ Trigger = 'manual'; Confirm = $false }
            if ($Force)                              { $syncArgs.ForceIndexRefresh = $true }
            if ($Skip)                               { $syncArgs.SkipIndexRefresh  = $true }
            if ($SubIds -and $SubIds.Count -gt 0)    { $syncArgs.SubscriptionId    = $SubIds }
            Log-Debug "calling Sync-RfSubscriptions"
            $result = Sync-RfSubscriptions @syncArgs
            Log-Debug ("Sync-RfSubscriptions returned status={0}" -f $result.Status)
            Invoke-RfStatusWrite @{
                Phase    = 'complete'
                MarkEnd  = $true
                Message  = ("Sync done: status={0} changed={1} failed={2}" -f $result.Status, $result.Counters.Changed, $result.Counters.Failed)
            }
        } catch {
            $errMsg = $_.Exception.Message
            Log-Debug "FAILED: $errMsg"
            try {
                Invoke-RfStatusWrite @{
                    Phase     = 'failed'
                    MarkEnd   = $true
                    ErrorText = $errMsg
                    Message   = ("Sync failed: " + $errMsg)
                }
            } catch {
                Log-Debug "ALSO failed writing status: $($_.Exception.Message)"
            }
        }
    } -ArgumentList @([bool]$ForceIndexRefresh, [bool]$SkipIndexRefresh, $SubscriptionId, $logForInit)

    Write-RfIndexRefreshStatus -Phase 'starting' -Total 0 -Processed 0 `
        -Message ("Sync job #{0} accepted (ForceIndexRefresh={1}, SkipIndexRefresh={2})" -f $job.Id, $ForceIndexRefresh, $SkipIndexRefresh) -MarkStart

    Start-Sleep -Milliseconds 800
    if ($job.State -eq 'Failed') {
        $errOut = if ($job.JobStateInfo.Reason) { $job.JobStateInfo.Reason.Message } else { ($job.ChildJobs.Error | Out-String).Trim() }
        if (-not $errOut) { $errOut = 'ThreadJob failed at startup with no error stream' }
        Write-RfIndexRefreshStatus -Phase 'failed' -MarkEnd -ErrorText $errOut `
            -Message "ThreadJob failed at startup: $errOut"
        return [PSCustomObject]@{ accepted = $false; reason = 'job_failed_at_start'; status = (Get-RfIndexRefreshStatus) }
    }

    return [PSCustomObject]@{
        accepted = $true
        job_id   = $job.Id
        status   = (Get-RfIndexRefreshStatus)
    }
}
