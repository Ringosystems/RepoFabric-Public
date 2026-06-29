function Update-RfTaskStateAlerts {
    <#
    .SYNOPSIS
        Walks the cron job log files, emits stale-schedule alerts for any
        that are overdue, and emits all-clear alerts for previously-stale
        signatures that have recovered.

    .DESCRIPTION
        Wired into the hourly crontab. Pulls per-task state from
        Get-RfTaskState (which derives staleness from cron log file
        mtimes), then for each row:
          - severity in warning/error/critical -> Send-RfStaleScheduleAlert
            with the row's Signature, Severity, and Message. The 24h
            suppression window inside Send-RfStaleScheduleAlert keeps the
            operator from getting spammed.
          - severity = ok -> Send-RfStaleScheduleAlert -AllClear if the
            signature exists in notification_state.

        The 'ok' branch needs the signature shape Send-RfStaleScheduleAlert
        produced when the row was originally stale. Get-RfTaskState rebuilds
        the same signature so the lookup works.

    .PARAMETER TaskName
        Override the default set of known cron tasks. Default covers every
        current crontab entry in linux/crontab.
    #>
    [CmdletBinding(SupportsShouldProcess)]
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

    $config = Get-RfConfiguration
    $conn = Open-RfStateDatabase
    try {
        $states = Get-RfTaskState -TaskName $TaskName
        foreach ($s in $states) {
            if (-not $s.Present) {
                if ($PSCmdlet.ShouldProcess($s.Name, "Send stale alert ($($s.Severity))")) {
                    Send-RfStaleScheduleAlert -Connection $conn -Configuration $config -Signature $s.Signature -Severity $s.Severity -Message $s.Message
                }
                continue
            }
            if ($s.Severity -eq 'ok') {
                if ($PSCmdlet.ShouldProcess($s.Name, 'Send all-clear if previously stale')) {
                    Send-RfStaleScheduleAlert -Connection $conn -Configuration $config -Signature $s.Signature -Severity 'warning' -Message $s.Message -AllClear
                }
            } else {
                if ($PSCmdlet.ShouldProcess($s.Name, "Send stale alert ($($s.Severity))")) {
                    Send-RfStaleScheduleAlert -Connection $conn -Configuration $config -Signature $s.Signature -Severity $s.Severity -Message $s.Message
                }
            }
        }
    } finally {
        if ($conn) { try { $conn.Close() } catch {} }
    }
}
