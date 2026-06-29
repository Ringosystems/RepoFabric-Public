function Start-RfIndexRefreshJob {
    <#
    .SYNOPSIS
        Kicks off Update-RfUpstreamIndex inside a Start-ThreadJob runspace so
        the HttpListener thread is free to keep serving status polls.

    .DESCRIPTION
        HttpListener is single-threaded by default. A synchronous index
        refresh blocks every other API call for the duration of the walk
        (~5 minutes on the full winget-pkgs tree). This wrapper runs the
        same work in a ThreadJob so the bridge stays responsive.

        Returns the freshly-started job's state OR, if a refresh is already
        in progress, returns a sentinel object describing the conflict so
        the caller can return 409 to the client.

    .PARAMETER Full
        Forwarded to Update-RfUpstreamIndex. -Full triggers a TRUNCATE.
    #>
    [CmdletBinding()]
    param(
        [switch]$Full
    )

    # Reject concurrent runs based on the status file's terminal-phase signal.
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

    # Resolve the log path Linux-style. The Windows version used
    # $env:ProgramData which does not exist on Linux, leading to a null
    # Join-Path Path argument. The repofabric state dir always exists at this
    # point (Open-RfStateDatabase ran during bridge boot).
    $stateRoot = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
    $logForInit = Join-Path $stateRoot 'logs/threadjob-debug.log'

    # ThreadJob runs inside the same process, but each runspace needs the
    # module re-imported because module state is per-runspace.
    $initScript = [scriptblock]::Create(@"
try { Add-Content -LiteralPath '$logForInit' -Value ("{0} init: starting import of $psd1Path" -f (Get-Date).ToString('o')) -ErrorAction SilentlyContinue } catch {}
Import-Module '$psd1Path' -Force -ErrorAction Stop
try { Add-Content -LiteralPath '$logForInit' -Value ("{0} init: module imported OK" -f (Get-Date).ToString('o')) -ErrorAction SilentlyContinue } catch {}
"@)
    $job = Start-ThreadJob -Name 'repofabric-index-refresh' -InitializationScript $initScript -ScriptBlock {
        param([bool]$Full, [string]$LogPath)
        $logPath = $LogPath
        function Log-Debug($msg) {
            try { Add-Content -LiteralPath $logPath -Value ("{0} refresh: {1}" -f (Get-Date).ToString('o'), $msg) -ErrorAction SilentlyContinue } catch {}
        }

        # Resolve the module so private functions like Write-RfIndexRefreshStatus
        # can be invoked via & $mod { ... }. The worker runspace's top-level scope
        # only sees the manifest's exported functions; private helpers must be
        # dispatched through the module's session state.
        $mod = Get-Module RepoFabric
        if (-not $mod) {
            Log-Debug "FATAL: RepoFabric module not loaded in worker runspace"
            return
        }
        function Invoke-RfStatusWrite {
            param([hashtable]$Params)
            & $mod ([scriptblock]::Create('param($p) Write-RfIndexRefreshStatus @p')) $Params
        }

        Log-Debug "thread started Full=$Full"
        try {
            if ($Full) { Update-RfUpstreamIndex -Full -Confirm:$false }
            else       { Update-RfUpstreamIndex       -Confirm:$false }
            Log-Debug "refresh completed"
        } catch {
            $errMsg = $_.Exception.Message
            Log-Debug "FAILED: $errMsg"
            try {
                Invoke-RfStatusWrite @{
                    Phase     = 'failed'
                    MarkEnd   = $true
                    ErrorText = $errMsg
                    Message   = ("Refresh failed: " + $errMsg)
                }
            } catch {
                Log-Debug "ALSO failed writing status: $($_.Exception.Message)"
            }
        }
    } -ArgumentList @([bool]$Full, $logForInit)

    Write-RfIndexRefreshStatus -Phase 'starting' -Total 0 -Processed 0 `
        -Message ("Refresh job #{0} accepted; sparse-checkout next" -f $job.Id) -MarkStart

    # Give the ThreadJob a moment to crash if InitializationScript fails.
    # We want a same-cycle failure to surface immediately in the status file
    # rather than leaving the operator staring at 'starting' forever.
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
