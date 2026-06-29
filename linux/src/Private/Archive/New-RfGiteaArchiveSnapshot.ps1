function New-RfGiteaArchiveSnapshot {
    <#
    .SYNOPSIS
        Records a recovery point in gitea_archive_snapshots.

    .DESCRIPTION
        Phase D.6. A snapshot ties a (repo_id, head_commit_sha) pair to a
        moment in time and an operator-meaningful reason. Restore picks
        a snapshot, walks gitea_archive_commits backwards from
        head_commit_sha following parent_shas_json, and reconstructs
        the tree on a clean Gitea repo via the archived blobs and files.

        Snapshot writes are best-effort and cheap (no network, no blob
        re-hash). Every call site that produced a new commit also
        records a snapshot pointing at that commit. The daily cron
        captures the current HEAD even if nothing else changed, so
        recovery has a 24-hour-or-better RPO without relying on
        publish frequency.

    .PARAMETER RepoId
        Virtual repo this snapshot belongs to.

    .PARAMETER HeadCommitSha
        The commit that was HEAD at snapshot time. Must already exist
        in gitea_archive_commits; otherwise the FK insert will fail.

    .PARAMETER Reason
        publish | promote | drift | daily | manual | pre_upgrade |
        restore_verification.

    .PARAMETER TriggerEventId
        Optional cross-reference into publish_events.publish_event_id or
        drift_events.drift_event_id depending on Reason.

    .PARAMETER Notes
        Free-form operator note.

    .PARAMETER Connection
        Optional state DB path.

    .OUTPUTS
        Int. snapshot_id of the new row.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$HeadCommitSha,
        [Parameter(Mandatory)]
        [ValidateSet('publish','promote','drift','daily','manual','pre_upgrade','restore_verification')]
        [string]$Reason,
        [Nullable[int]]$TriggerEventId,
        [string]$Notes = '',
        [object]$Connection
    )

    if (-not $Connection) { $Connection = Open-RfStateDatabase }

    # Per-repo rollups for the dashboard. Tied to the snapshot row
    # rather than computed live because the archive tables are
    # append-only; the totals only grow and we want to know
    # historical sizes for trend display later.
    $stats = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT
  (SELECT COUNT(*) FROM gitea_archive_commits WHERE repo_id = @rid)              AS commits_for_repo,
  (SELECT COUNT(*) FROM gitea_archive_blobs)                                     AS blobs_total,
  (SELECT COALESCE(SUM(content_size), 0) FROM gitea_archive_blobs)               AS bytes_total
'@ -SqlParameters @{ rid = $RepoId } | Select-Object -First 1

    $commitCount = if ($stats) { [int]$stats.commits_for_repo } else { 0 }
    $blobCount   = if ($stats) { [int]$stats.blobs_total }      else { 0 }
    $byteCount   = if ($stats) { [int64]$stats.bytes_total }    else { 0 }
    $branchRefs  = (ConvertTo-Json -InputObject @{ main = $HeadCommitSha } -Compress)

    $now = Get-RfTimestamp

    $rows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO gitea_archive_snapshots
    (repo_id, taken_at_utc, head_commit_sha, branch_refs_json,
     reason, trigger_event_id, commit_count, blob_count, total_size_bytes, notes)
VALUES
    (@rid, @now, @head, @refs,
     @reason, @trig, @cc, @bc, @bytes, @notes)
RETURNING snapshot_id
'@ -SqlParameters @{
        rid    = $RepoId
        now    = $now
        head   = $HeadCommitSha
        refs   = $branchRefs
        reason = $Reason
        trig   = if ($PSBoundParameters.ContainsKey('TriggerEventId') -and $null -ne $TriggerEventId) { [int]$TriggerEventId } else { [DBNull]::Value }
        cc     = $commitCount
        bc     = $blobCount
        bytes  = $byteCount
        notes  = $Notes
    }
    return [int]$rows[0].snapshot_id
}
