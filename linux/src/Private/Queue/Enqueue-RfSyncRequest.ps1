function Enqueue-RfSyncRequest {
    <#
    .SYNOPSIS
        Inserts a pending row into sync_queue.
    .PARAMETER SubscriptionId
        Target subscription.
    .PARAMETER Priority
        0=force, 50=manual, 100=scheduled. Lower = sooner.
    .PARAMETER Trigger
        Audit string. 'force', 'manual', 'scheduled', or operator-supplied.
    .PARAMETER RepoId
        Virtual repo this request belongs to. Defaults to the subscription's
        repo_id (resolved via SELECT) if not supplied; falls back to 'main'.
    .OUTPUTS
        Inserted queue_id.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$SubscriptionId,
        [ValidateRange(0, 1000)][int]$Priority = 50,
        [string]$Trigger = 'manual',
        [string]$RepoId,
        [string]$DataSource
    )

    if (-not $DataSource) { $DataSource = Open-RfStateDatabase }
    $now = Get-RfTimestamp

    if ([string]::IsNullOrWhiteSpace($RepoId)) {
        try {
            $sub = Invoke-RfSqliteQuery -DataSource $DataSource -Query 'SELECT repo_id FROM subscription WHERE subscription_id = @sid' -SqlParameters @{ sid = $SubscriptionId } | Select-Object -First 1
            if ($sub -and $sub.repo_id) { $RepoId = [string]$sub.repo_id }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($RepoId)) { $RepoId = 'main' }
    }

    # MySQLite swallows RETURNING-clause data; route through the sqlite3
    # CLI (Invoke-RfSqliteReturning) to actually receive the new id.
    $rows = Invoke-RfSqliteReturning -DataSource $DataSource -Query @'
INSERT INTO sync_queue (subscription_id, priority, state, requested_at, trigger, repo_id)
VALUES (@sid, @pri, 'pending', @now, @trg, @rid)
RETURNING queue_id;
'@ -SqlParameters @{ sid = $SubscriptionId; pri = $Priority; now = $now; trg = $Trigger; rid = $RepoId }

    return [int]$rows[0].queue_id
}
