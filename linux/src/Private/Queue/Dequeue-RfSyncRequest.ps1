function Dequeue-RfSyncRequest {
    <#
    .SYNOPSIS
        Atomically claims the highest-priority pending row for a worker.
    .DESCRIPTION
        Uses a single composed SQL batch (SELECT id then UPDATE state)
        wrapped in BEGIN/COMMIT so the claim is atomic from MySQLite's
        per-call perspective. SQLite's default locking serialises this
        across the worker pool.
    .PARAMETER WorkerId
        Identifier of the claiming worker, e.g. 'worker_2'.
    .OUTPUTS
        PSCustomObject {queue_id, subscription_id, priority, trigger} or
        $null when the queue is empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerId,
        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $now = Get-RfTimestamp

    # UPDATE with a correlated SELECT subquery and RETURNING is a single
    # atomic SQLite statement (SQLite wraps every statement in an implicit
    # transaction). No explicit BEGIN/COMMIT required; in fact, MySQLite's
    # Invoke-MySQLiteQuery is single-statement only and a BEGIN/COMMIT
    # wrapper makes it fail silently with the "times ('-1') must be
    # non-negative" error.
    $sql = @'
UPDATE sync_queue SET state='running', started_at=@now, worker_id=@wid
 WHERE queue_id = (
   SELECT queue_id FROM sync_queue
    WHERE state='pending'
    ORDER BY priority ASC, requested_at ASC
    LIMIT 1
 )
RETURNING queue_id, subscription_id, priority, trigger;
'@
    # MySQLite swallows UPDATE...RETURNING data; route through sqlite3
    # CLI (Invoke-RfSqliteReturning) so the worker actually sees which
    # row it just claimed.
    $rows = Invoke-RfSqliteReturning -DataSource $DataSource -Query $sql -SqlParameters @{ now = $now; wid = $WorkerId }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    $row = $rows[0]
    return [PSCustomObject]@{
        QueueId        = [int]$row.queue_id
        SubscriptionId = [int]$row.subscription_id
        Priority       = [int]$row.priority
        Trigger        = [string]$row.trigger
    }
}
