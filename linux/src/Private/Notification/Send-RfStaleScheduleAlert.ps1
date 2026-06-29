function Send-RfStaleScheduleAlert {
    <#
    .SYNOPSIS
        Sends a stale-schedule email alert (parallel to the admin Activity tab banner).

    .DESCRIPTION
        - Severity: warning | error | critical (based on cadence overdue
          ratio computed by Get-RfTaskState; passed in by caller).
        - Suppression: at most one alert per condition-signature every 24h.
          The 'notification_state' table records last_sent_utc keyed by
          signature.
        - All-clear: when a previously-alerted signature is no longer
          stale, a 'recovered' email goes out and the row is removed.

    .PARAMETER Signature
        Stable hash uniquely identifying the stale condition.

    .PARAMETER Severity
        warning | error | critical

    .PARAMETER Message
        Human-readable description of the stale condition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][hashtable]$Configuration,
        [Parameter(Mandatory)][string]$Signature,
        [Parameter(Mandatory)][ValidateSet('warning','error','critical')][string]$Severity,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllClear
    )

    if (-not $Configuration.notifications.smtp.host) { return }

    $now = [DateTime]::UtcNow
    $row = Invoke-RfSqliteQuery -DataSource $Connection -Query 'SELECT * FROM notification_state WHERE signature = @s' -SqlParameters @{ s = $Signature } | Select-Object -First 1

    if ($AllClear) {
        if (-not $row) { return }
        $subject = "[RepoFabric] Stale-schedule cleared: $env:COMPUTERNAME"
        $body = "The previously-stale schedule has recovered.`n`nSignature: $Signature`n`n$Message"
        try { Send-RfEmail -Configuration $Configuration -Subject $subject -Body $body } catch {}
        Invoke-RfSqliteQuery -DataSource $Connection -Query 'DELETE FROM notification_state WHERE signature = @s' -SqlParameters @{ s = $Signature } | Out-Null
        return
    }

    if ($row) {
        $last = [DateTime]::Parse($row.last_sent_utc, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        if (($now - $last).TotalHours -lt 24) {
            Write-RfLog -Level Verbose -Message "Suppressing stale alert for $Signature (last sent $last UTC)."
            return
        }
    }

    $prefix = switch ($Severity) {
        'critical' { '[!!! RepoFabric CRITICAL]' }
        'error'    { '[!!! RepoFabric ERROR]' }
        'warning'  { '[RepoFabric WARNING]' }
    }
    $subject = "$prefix Schedule stale: $env:COMPUTERNAME"
    $body = "Severity: $Severity`nSignature: $Signature`n`n$Message`n`nResolve by inspecting cron status inside the container: docker exec repofabric-linux supervisorctl status, then docker exec repofabric-linux crontab -u repofabric -l."

    try { Send-RfEmail -Configuration $Configuration -Subject $subject -Body $body } catch { return }

    if ($row) {
        Invoke-RfSqliteQuery -DataSource $Connection -Query 'UPDATE notification_state SET severity=@sev, last_sent_utc=@ts, message=@m WHERE signature=@s' -SqlParameters @{ sev=$Severity; ts=(Get-RfTimestamp); m=$Message; s=$Signature } | Out-Null
    } else {
        Invoke-RfSqliteQuery -DataSource $Connection -Query 'INSERT INTO notification_state (signature, severity, last_sent_utc, message) VALUES (@s,@sev,@ts,@m)' -SqlParameters @{ s=$Signature; sev=$Severity; ts=(Get-RfTimestamp); m=$Message } | Out-Null
    }
}
