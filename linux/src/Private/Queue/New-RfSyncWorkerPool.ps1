function New-RfSyncWorkerPool {
    <#
    .SYNOPSIS
        Spawns N ThreadJob workers that pull from sync_queue and run
        acquire+build+publish per subscription.

    .DESCRIPTION
        Each worker loops:
          1. Dequeue-RfSyncRequest -WorkerId $id
          2. If a row was claimed, run Invoke-RfAcquire, Invoke-RfBuild,
             Invoke-RfPublish for the subscription, then mark complete.
          3. If no row was claimed, sleep $IdleSleepMs then loop.
          4. Honour the shared stop signal (file flag or hashtable).

        Returns the list of ThreadJob objects so callers can monitor or
        stop the pool. Pool resizing is implemented by stopping the pool
        and starting a new one with the new size.

    .PARAMETER Size
        Worker count. Bounded by config service.sync.worker_pool_size.
    .PARAMETER StopFlagPath
        File path whose existence signals all workers to drain and exit.
        Default: <state>/queue.stop
    .PARAMETER IdleSleepMs
        Sleep when the queue is empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$Size,
        [string]$StopFlagPath,
        # 2500ms strikes a balance: low enough that a force-sync runs
        # within ~3s of the GUI click, high enough that 4 workers do not
        # hammer SQLite hard enough to provoke contention against the
        # cron walker. With Invoke-RfSqliteReturning's 10s busy_timeout
        # prelude, contention now self-resolves rather than throwing.
        [int]$IdleSleepMs = 2500
    )

    if (-not $StopFlagPath) {
        $paths = Get-RfPaths
        $StopFlagPath = Join-Path $paths.StateDir 'queue.stop'
    }
    if (Test-Path $StopFlagPath) { Remove-Item -Path $StopFlagPath -Force }

    # Self-heal: any row in sync_queue.state='running' with no completed_at
    # is the ghost of a worker killed by a bridge restart or container
    # reboot. Same hazard exists on the run table: status='running' with
    # no ended_utc. Reset both at pool boot so the new workers start clean.
    try {
        $dbPath = Open-RfStateDatabase
        Invoke-RfSqliteQuery -DataSource $dbPath -Query @'
UPDATE sync_queue
   SET state='pending', started_at=NULL, worker_id=NULL
 WHERE state='running' AND completed_at IS NULL
'@ | Out-Null
        Invoke-RfSqliteQuery -DataSource $dbPath -Query @'
UPDATE run
   SET status='cancelled',
       ended_utc=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
       summary='Cancelled at bridge restart; no live worker'
 WHERE status='running' AND ended_utc IS NULL
'@ | Out-Null
    } catch {
        Write-Warning "Worker pool orphan-reset skipped: $($_.Exception.Message)"
    }

    $modulePath = (Get-Module RepoFabric).Path
    if (-not $modulePath) {
        $modulePath = Join-Path $PSScriptRoot '..' '..' 'RepoFabric.psd1' | Resolve-Path
    }
    # ThreadJob stdout/stderr streams never reach supervisord. Funnel
    # every meaningful event to a shared per-pool debug log so failures
    # in dequeue or in the acquire/build/publish phases are diagnosable
    # without having to Receive-Job from another pwsh.
    $debugLog = Join-Path (Get-RfPaths).LogDir 'sync-workers.log'

    $workers = for ($i = 1; $i -le $Size; $i++) {
        $workerId = "worker_$i"
        Start-ThreadJob -Name $workerId -ArgumentList $workerId, $StopFlagPath, $IdleSleepMs, $modulePath, $debugLog -ScriptBlock {
            param($wid, $stopPath, $idleMs, $mp, $logPath)
            $log = {
                param([string]$msg)
                try {
                    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'), $wid, $msg
                    [System.IO.File]::AppendAllText($logPath, $line + "`n")
                } catch { }
            }
            try {
                Import-Module $mp -ErrorAction Stop
                & $log 'worker booted; module imported'
            } catch {
                & $log ("FATAL module import: " + $_.Exception.Message)
                return
            }

            # Dequeue/Enqueue/Complete are Private/ functions, not exported
            # by the manifest, so they are not visible to direct calls from
            # this scriptblock's scope. Invoke everything inside the module's
            # own scope via & (Get-Module RepoFabric) { ... }, which is
            # how Private functions become reachable from external callers.
            $mod = Get-Module RepoFabric
            if (-not $mod) {
                & $log 'FATAL Get-Module RepoFabric returned $null after Import-Module'
                return
            }

            while (-not (Test-Path $stopPath)) {
                try {
                    $req = & $mod { param($w) Dequeue-RfSyncRequest -WorkerId $w } $wid
                    if (-not $req) { Start-Sleep -Milliseconds $idleMs; continue }
                    & $log ("dequeued queue_id={0} subscription_id={1} priority={2}" -f $req.QueueId, $req.SubscriptionId, $req.Priority)

                    # Map queue priority to a run trigger label so the Runs
                    # tab makes sense at a glance.
                    #   priority 0   = force-sync   -> 'force'   (operator-driven, highest urgency)
                    #   priority 50  = manual sync  -> 'manual'
                    #   priority 100 = cron sync    -> 'scheduled'
                    $runTrigger = switch ([int]$req.Priority) {
                        0   { 'force' }
                        50  { 'manual' }
                        100 { 'scheduled' }
                        default { 'manual' }
                    }

                    # Open a run row up front so the Runs tab sees the
                    # work in progress in real time.
                    $runId = $null
                    try {
                        $dbPath = & $mod { Open-RfStateDatabase }
                        $runId  = & $mod { param($db, $kind, $trg, $actor) Start-RfRun -Connection $db -Kind $kind -Trigger $trg -Actor $actor } `
                            $dbPath 'sync' $runTrigger $wid
                        & $log ("opened run #{0} for queue_id={1}" -f $runId, $req.QueueId)
                    } catch {
                        & $log ("Start-RfRun threw: {0} (continuing without run row)" -f $_.Exception.Message)
                    }

                    $runStatus  = 'failed'
                    $runChanged = 0
                    $runFailed  = 0
                    $runSkipped = 0

                    try {
                        & $log ("phase: acquire sid={0}" -f $req.SubscriptionId)
                        $acq = & $mod { param($s) Invoke-RfAcquire -SubscriptionId $s } $req.SubscriptionId
                        & $log ("acquire outcome={0} version={1}" -f $acq.Outcome, $acq.Version)
                        if ($acq -and $acq.Outcome -eq 'succeeded') {
                            & $log ("phase: build sid={0} version={1}" -f $req.SubscriptionId, $acq.Version)
                            $bld = & $mod { param($s, $v) Invoke-RfBuild -SubscriptionId $s -Version $v } $req.SubscriptionId $acq.Version
                            if (-not $bld -or -not $bld.TransformationId) {
                                throw "Build phase returned no TransformationId (got: $bld)"
                            }
                            & $log ("phase: publish transformation_id={0} version={1}" -f $bld.TransformationId, $acq.Version)
                            $pub = & $mod { param($t) Invoke-RfPublish -TransformationId $t } ([int]$bld.TransformationId)
                            $runStatus  = 'succeeded'
                            # Distinguish "actually published something new" from
                            # "publication already exists; nothing to do". The
                            # latter is the "correct state" path: force-syncs
                            # against an unchanged subscription must not show
                            # as 'changed' in the activity feed.
                            if ($pub -and ($pub.Skipped -or $pub.Outcome -eq 'already_published')) {
                                $runSkipped = 1
                                & $log ("publish outcome=already_published sid={0} version={1}" -f $req.SubscriptionId, $acq.Version)
                            } else {
                                $runChanged = 1
                            }
                        } else {
                            # Acquire returned no new version (already up to date,
                            # or skipped). That is a "correct state" no-op for
                            # the run, not a change.
                            $runStatus  = 'succeeded'
                            $runSkipped = 1
                        }
                        & $mod { param($q) Complete-RfSyncRequest -QueueId $q -State 'completed' } $req.QueueId
                        & $log ("completed queue_id={0}" -f $req.QueueId)
                    } catch {
                        $errMsg = $_.Exception.Message
                        & $log ("FAILED queue_id={0}: {1}" -f $req.QueueId, $errMsg)
                        $runStatus = 'failed'
                        $runFailed = 1
                        try { & $mod { param($q, $m) Complete-RfSyncRequest -QueueId $q -State 'failed' -FailureMessage $m } $req.QueueId $errMsg } catch {
                            & $log ("Complete-RfSyncRequest fail-path also threw: " + $_.Exception.Message)
                        }
                    }

                    # Finalise the run row regardless of outcome.
                    if ($runId) {
                        try {
                            $dbPath2 = & $mod { Open-RfStateDatabase }
                            & $mod { param($db, $rid, $st, $ct) Complete-RfRun -Connection $db -RunId $rid -Status $st -Counters $ct } `
                                $dbPath2 $runId $runStatus @{ Changed = $runChanged; Failed = $runFailed; Skipped = $runSkipped }
                            & $log ("closed run #{0} status={1}" -f $runId, $runStatus)
                        } catch {
                            & $log ("Complete-RfRun threw: " + $_.Exception.Message)
                        }
                    }
                } catch {
                    & $log ("top-level error: " + $_.Exception.Message)
                    Start-Sleep -Milliseconds $idleMs
                }
            }
            & $log 'worker exiting (stop flag observed)'
        }
    }
    return @($workers)
}
