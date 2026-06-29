function Get-RfRunReport {
    <#
    .SYNOPSIS
        Returns a detailed report for a run, including all per-subscription events.

    .PARAMETER RunId
        Specific run ID. Without it, returns the most recent N runs as summaries.

    .PARAMETER Last
        With -RunId omitted: number of recent runs to summarize. Default 10.

    .PARAMETER FailuresOnly
        With -RunId set: include only failed events.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Recent')]
    param(
        [Parameter(ParameterSetName = 'Specific', Mandatory)]
        [int]$RunId,

        [Parameter(ParameterSetName = 'Recent')]
        [int]$Last = 10,

        [Parameter(ParameterSetName = 'Specific')]
        [switch]$FailuresOnly
    )

    $conn = Open-RfStateDatabase
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Recent') {
            $rows = Invoke-RfSqliteQuery -DataSource $conn -Query @'
SELECT run_id AS id, kind, trigger, actor, status, started_utc, ended_utc, count_succeeded, count_failed, count_skipped, count_changed, summary
  FROM run
 ORDER BY run_id DESC
 LIMIT @n
'@ -SqlParameters @{ n = $Last }
            return $rows
        }

        $run = Invoke-RfSqliteQuery -DataSource $conn -Query 'SELECT run_id AS id, * FROM run WHERE run_id = @id' -SqlParameters @{ id = $RunId } | Select-Object -First 1
        if (-not $run) { throw "Run #$RunId not found." }

        $eventsSql = 'SELECT event_id AS id, * FROM run_event WHERE run_id = @id'
        if ($FailuresOnly) { $eventsSql += " AND outcome = 'failed'" }
        $eventsSql += ' ORDER BY event_id'
        $events = Invoke-RfSqliteQuery -DataSource $conn -Query $eventsSql -SqlParameters @{ id = $RunId }

        [PSCustomObject]@{
            Run    = $run
            Events = @($events)
            Counts = @{
                Succeeded = ($events | Where-Object outcome -eq 'succeeded').Count
                Failed    = ($events | Where-Object outcome -eq 'failed').Count
                Skipped   = ($events | Where-Object outcome -eq 'skipped').Count
                Changed   = ($events | Where-Object outcome -eq 'changed').Count
            }
        }
    } finally {
    }
}
