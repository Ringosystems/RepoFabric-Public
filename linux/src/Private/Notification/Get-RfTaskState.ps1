function Get-RfTaskState {
    <#
    .SYNOPSIS
        Reports on each repofabric cron job's health based on log file mtime.

    .DESCRIPTION
        Cron jobs live in linux/crontab and run as the repofabric user. Each
        job redirects stdout+stderr to a log file under
        /var/lib/repofabric/logs/, so the file's mtime is a reliable proxy
        for "when did this job last fire". Staleness is mtime against the
        expected cadence.

        Tolerance cycles vary by job: chatty short-cadence jobs (catalog
        walker, drift detection) tolerate a handful of missed ticks; slow
        wall-clock jobs (popularity, weekly upstream scan) tolerate just
        one missed run since the next correct fire is up to a week away.
    #>
    [CmdletBinding()]
    param(
        [string[]]$TaskName = @(
            'cron-catalog',
            'cron-sync',
            'cron-archive',
            'cron-drift',
            'cron-popularity',
            'cron-upstream-scan'
        )
    )

    $now = (Get-Date).ToUniversalTime()
    $logDir = if ($env:REPOFABRIC_STATE_DIR) { Join-Path $env:REPOFABRIC_STATE_DIR 'logs' } else { '/var/lib/repofabric/logs' }

    $known = @{
        'cron-catalog'        = @{ LogFile = (Join-Path $logDir 'cron-catalog.log');        Cadence = [timespan]::FromMinutes(5);   ToleranceCycles = 4 }
        'cron-sync'           = @{ LogFile = (Join-Path $logDir 'cron-sync.log');           Cadence = [timespan]::FromHours(6);     ToleranceCycles = 2 }
        'cron-archive'        = @{ LogFile = (Join-Path $logDir 'cron-archive.log');        Cadence = [timespan]::FromHours(24);    ToleranceCycles = 2 }
        'cron-drift'          = @{ LogFile = (Join-Path $logDir 'cron-drift.log');          Cadence = [timespan]::FromMinutes(15);  ToleranceCycles = 4 }
        'cron-popularity'     = @{ LogFile = (Join-Path $logDir 'cron-popularity.log');     Cadence = [timespan]::FromHours(24);    ToleranceCycles = 2 }
        'cron-upstream-scan'  = @{ LogFile = (Join-Path $logDir 'cron-upstream-scan.log');  Cadence = [timespan]::FromDays(7);      ToleranceCycles = 1 }
    }
    foreach ($name in @($known.Keys)) {
        $known[$name].Name = $name
    }

    $out = @()
    foreach ($name in $TaskName) {
        $cfg = $known[$name]
        if (-not $cfg) {
            $out += [PSCustomObject]@{
                Name      = $name
                Present   = $false
                Severity  = 'critical'
                StaleBy   = $null
                Message   = "Unknown task '$name'; no Linux-fork mapping defined"
                Signature = "repofabric:task-unknown:$name"
            }
            continue
        }

        $logFile = $cfg.LogFile
        $cadence = $cfg.Cadence
        $tol     = $cfg.ToleranceCycles

        $lastWrite = $null
        if (Test-Path -LiteralPath $logFile) {
            try { $lastWrite = (Get-Item -LiteralPath $logFile).LastWriteTimeUtc } catch { }
        }

        # No log file yet is normal on a fresh install. Report as Present
        # but with 'ok' severity until the first cron tick is overdue.
        $expected = if ($lastWrite) { $lastWrite + $cadence } else { $null }
        $staleBy  = if ($expected -and $expected -lt $now) { $now - $expected } else { $null }

        $severity = 'ok'
        $message  = if ($lastWrite) { "OK; last write $lastWrite UTC" } else { 'OK; no log entries yet (cron not fired since boot)' }
        if ($staleBy) {
            $cycles   = [int][Math]::Floor($staleBy.TotalMinutes / $cadence.TotalMinutes)
            if ($cycles -ge ($tol * 4))      { $severity = 'critical' }
            elseif ($cycles -ge ($tol * 2))  { $severity = 'error' }
            elseif ($cycles -ge $tol)        { $severity = 'warning' }
            $message = "Stale by $($staleBy.ToString('d\.hh\:mm')); $cycles cadence cycles overdue. Check supervisorctl repofabric:cron status."
        }

        $sig = "repofabric:task:$name|severity:$severity|stale-cycles:" + ($staleBy ? [int]([Math]::Floor($staleBy.TotalMinutes / $cadence.TotalMinutes)) : 0)
        $sig = ($sig -replace '\s', '_').Substring(0, [Math]::Min(200, $sig.Length))

        $out += [PSCustomObject]@{
            Name        = $name
            Present     = $true
            LastRunTime = $lastWrite
            NextRunTime = $expected
            LastResult  = 0
            Cadence     = $cadence
            StaleBy     = $staleBy
            Severity    = $severity
            Message     = $message
            Signature   = $sig
        }
    }
    $out
}
