function Send-RfRunNotification {
    <#
    .SYNOPSIS
        Sends the per-run "changes-or-errors-only" email notification.

    .DESCRIPTION
        - Subject: [!!! RepoFabric FAILURE] when status is failed/partial,
          [RepoFabric] OK (N changes) on a clean changes-only run.
        - Body assembled by Format-RfNotificationBody.
        - Skipped silently if SMTP is not configured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][hashtable]$Configuration
    )

    if (-not $Configuration.notifications -or -not $Configuration.notifications.smtp -or -not $Configuration.notifications.smtp.host) {
        Write-RfLog -Level Verbose -Message 'notifications.smtp not configured; skipping send.'
        return
    }

    $run = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT run_id AS id, * FROM run WHERE run_id = @id' -SqlParameters @{ id = $RunId } | Select-Object -First 1
    if (-not $run) { Write-RfLog -Level Warning -Message "Run #$RunId not found"; return }
    $events = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT event_id AS id, * FROM run_event WHERE run_id = @id ORDER BY event_id' -SqlParameters @{ id = $RunId }

    $body = Format-RfNotificationBody -Run $run -Events $events
    $subject = switch ($run.status) {
        'failed'    { "[!!! RepoFabric FAILURE] run #$RunId on $env:COMPUTERNAME" }
        'partial'   { "[!!! RepoFabric FAILURE] run #$RunId on $env:COMPUTERNAME (partial)" }
        'succeeded' { "[RepoFabric] OK ($($run.count_changed) changes) run #$RunId" }
        default     { "[RepoFabric] $($run.status) run #$RunId" }
    }

    Send-RfEmail -Configuration $Configuration -Subject $subject -Body $body
}
