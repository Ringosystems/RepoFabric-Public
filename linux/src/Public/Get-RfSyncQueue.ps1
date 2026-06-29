function Get-RfSyncQueue {
    <#
    .SYNOPSIS
        Reports the current sync_queue state plus a per-priority count of
        pending and running rows. Used by the GUI queue panel.
    .OUTPUTS
        PSCustomObject {pending, running, completed, failed, items[]}.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([int]$LastN = 50, [string]$DataSource)
    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }

    $counts = Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT state, COUNT(*) AS n FROM sync_queue GROUP BY state
'@
    $summary = @{ pending = 0; running = 0; completed = 0; failed = 0; cancelled = 0 }
    foreach ($r in @($counts)) { $summary[[string]$r.state] = [int]$r.n }

    $items = Invoke-RfSqliteQuery -DataSource $DataSource -Query @'
SELECT queue_id, subscription_id, priority, state, requested_at, started_at,
       completed_at, worker_id, trigger, failure_message
  FROM sync_queue
 ORDER BY (state='running') DESC, (state='pending') DESC, requested_at DESC
 LIMIT @n
'@ -SqlParameters @{ n = $LastN }

    return [PSCustomObject]@{
        Pending   = $summary.pending
        Running   = $summary.running
        Completed = $summary.completed
        Failed    = $summary.failed
        Cancelled = $summary.cancelled
        Items     = @($items)
    }
}
