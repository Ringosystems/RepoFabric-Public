function Send-RfHeartbeat {
    <#
    .SYNOPSIS
        Sends a heartbeat email if no notification has gone out in the last 7
        days, confirming the host is alive.

    .DESCRIPTION
        Wired into the daily crontab in linux/crontab. If any email (per-run
        or stale-schedule) has been sent within the suppression window, the
        heartbeat is suppressed. Otherwise it sends a brief "things are
        quiet, here's the last successful run" message.

    .PARAMETER WindowDays
        Suppression window. Default 7.
    #>
    [CmdletBinding()]
    param(
        [int]$WindowDays = 7
    )

    $conn = Open-RfStateDatabase
    $config = Get-RfConfiguration
    try {
        if (-not $config.notifications.smtp.host) {
            Write-RfLog -Level Verbose -Message 'SMTP not configured; heartbeat suppressed.'
            return
        }

        $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $WindowDays).ToString('o')
        $recentNotif = Invoke-RfSqliteQuery -DataSource $conn -Query 'SELECT MAX(last_sent_utc) AS t FROM notification_state WHERE last_sent_utc >= @c' -SqlParameters @{ c = $cutoff }
        $recentRun   = Invoke-RfSqliteQuery -DataSource $conn -Query 'SELECT MAX(ended_utc) AS t FROM run WHERE ended_utc >= @c AND (count_changed > 0 OR count_failed > 0)' -SqlParameters @{ c = $cutoff }

        if (($recentNotif.t) -or ($recentRun.t)) {
            Write-RfLog -Level Verbose -Message "Heartbeat suppressed: notification activity within last $WindowDays days."
            return
        }

        $lastRun = Invoke-RfSqliteQuery -DataSource $conn -Query 'SELECT run_id AS id, kind, status, started_utc, ended_utc, count_succeeded, count_failed, count_skipped, count_changed FROM run ORDER BY run_id DESC LIMIT 1' | Select-Object -First 1
        $body = if ($lastRun) {
            @"
RepoFabric heartbeat — no changes or errors in the last $WindowDays days.

Host        : $env:COMPUTERNAME
Last run    : #$($lastRun.id) ($($lastRun.kind), $($lastRun.status))
Started     : $($lastRun.started_utc)
Ended       : $($lastRun.ended_utc)
Counters    : succeeded=$($lastRun.count_succeeded) failed=$($lastRun.count_failed) correct=$($lastRun.count_skipped) changed=$($lastRun.count_changed)

The service is alive and operating normally.
"@
        } else {
            "RepoFabric heartbeat from $env:COMPUTERNAME — no runs recorded yet."
        }

        Send-RfEmail -Configuration $config -Subject "[RepoFabric] Heartbeat OK on $env:COMPUTERNAME" -Body $body
    } finally {
    }
}
