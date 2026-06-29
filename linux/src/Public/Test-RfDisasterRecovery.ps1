function Test-RfDisasterRecovery {
    <#
    .SYNOPSIS
        Verifies the Gitea archive can rebuild a virtual repo end-to-end.

    .DESCRIPTION
        Phase D.7. Runs Restore-RfGiteaFromArchive into a temporary bare
        repo, runs 'git fsck --full', and compares the reconstructed
        head SHA against the snapshot's recorded head_commit_sha. A
        passing drill is byte-perfect proof that the archive contains
        every blob, commit, and parent edge needed to rebuild the
        repo. A failing drill means restore would fail in a real
        disaster.

        The drill never touches production Gitea; the reconstruction
        lives entirely on /tmp and is removed by default. Pass -Keep to
        leave the reconstructed bare repo on disk for inspection.

        Each drill writes a row to dr_drill_results with timing and
        outcome so the admin UI can show "last successful drill at
        <time>" per repo and red-banner stale or failed drills.

    .PARAMETER SnapshotId
        Optional. Specific snapshot to verify. If omitted, picks the
        most recent snapshot per (RepoId) and verifies each.

    .PARAMETER RepoId
        Optional. Constrain the drill to one virtual repo. Combine
        with -SnapshotId for a single-snapshot drill.

    .PARAMETER Keep
        Keep the reconstructed bare repo on disk after the drill.
        Useful for debugging a failure. Default is to remove it.

    .PARAMETER Connection
        Optional state DB path.

    .PARAMETER Configuration
        Optional resolved Configuration.

    .OUTPUTS
        Array of PSCustomObject, one per drill row written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject[]])]
    param(
        [Nullable[int]]$SnapshotId,
        [string]$RepoId,
        [switch]$Keep,
        [object]$Connection,
        [hashtable]$Configuration
    )

    if (-not $Connection)    { $Connection    = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    # Resolve which snapshots to drill.
    $snapshots = if ($SnapshotId) {
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT snapshot_id, repo_id, head_commit_sha
  FROM gitea_archive_snapshots
 WHERE snapshot_id = @id
'@ -SqlParameters @{ id = [int]$SnapshotId }
    } elseif ($RepoId) {
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT snapshot_id, repo_id, head_commit_sha
  FROM gitea_archive_snapshots
 WHERE repo_id = @rid
 ORDER BY snapshot_id DESC
 LIMIT 1
'@ -SqlParameters @{ rid = $RepoId }
    } else {
        # Latest snapshot per repo.
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT s.snapshot_id, s.repo_id, s.head_commit_sha
  FROM gitea_archive_snapshots s
  JOIN (SELECT repo_id, MAX(snapshot_id) AS max_id
          FROM gitea_archive_snapshots
         GROUP BY repo_id) m
    ON m.repo_id = s.repo_id AND m.max_id = s.snapshot_id
'@
    }

    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($snap in @($snapshots)) {
        if (-not $snap) { continue }
        $sid = [int]$snap.snapshot_id
        $rid = [string]$snap.repo_id
        $expectedHead = [string]$snap.head_commit_sha
        if (-not $PSCmdlet.ShouldProcess("Snapshot #$sid (repo '$rid')", 'DR drill')) { continue }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $actor = Get-RfCurrentIdentity
        $now = Get-RfTimestamp

        # Open drill row up front so a crash leaves a trace.
        $openRows = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT INTO dr_drill_results
    (started_at_utc, repo_id, snapshot_id, expected_head_sha, outcome, initiated_by_upn)
VALUES
    (@now, @rid, @sid, @head, 'in_progress', @actor)
RETURNING drill_id
'@ -SqlParameters @{ now = $now; rid = $rid; sid = $sid; head = $expectedHead; actor = $actor }
        $drillId = [int]$openRows[0].drill_id

        $tmpBare = Join-Path '/tmp' ("repofabric-drill-{0}-{1}" -f $sid, ([guid]::NewGuid().ToString('N').Substring(0,8)))
        $outcome = 'failed'
        $failure = $null
        $shaMatches = $false
        $fsckOk = $false
        $commitsWalked = 0
        $filesWritten = 0
        $bytesWritten = 0
        $reconstructedHead = $null

        try {
            $restore = Restore-RfGiteaFromArchive `
                -SnapshotId             $sid `
                -DestinationBareRepo    $tmpBare `
                -Connection             $Connection `
                -Configuration          $Configuration `
                -Confirm:$false
            $shaMatches = [bool]$restore.ShaMatches
            $commitsWalked = [int]$restore.CommitsWalked
            $filesWritten = [int]$restore.FilesWritten
            $bytesWritten = [int]$restore.BytesWritten
            $reconstructedHead = [string]$restore.ReconstructedHeadSha

            # fsck the reconstructed repo.
            $git = Get-Command git -ErrorAction Stop
            $fsckOut = & $git.Source --git-dir=$tmpBare fsck --full 2>&1
            $fsckOk = ($LASTEXITCODE -eq 0)

            if ($shaMatches -and $fsckOk) {
                $outcome = 'passed'
            } else {
                $outcome = 'failed'
                $details = @()
                if (-not $shaMatches) {
                    $details += ("Head SHA mismatch (expected={0}, reconstructed={1})" -f $expectedHead, $reconstructedHead)
                }
                if (-not $fsckOk) {
                    $details += ("git fsck failed: " + (($fsckOut | Out-String).Trim()))
                }
                $failure = $details -join ' | '
            }
        } catch {
            $outcome = 'failed'
            $failure = $_.Exception.Message
        } finally {
            $sw.Stop()
            if (Test-Path -LiteralPath $tmpBare) {
                if ($Keep -or $outcome -eq 'failed') {
                    Write-Information ("  [..] DR drill artifacts kept at $tmpBare (outcome=$outcome)") -InformationAction Continue
                } else {
                    Remove-Item -LiteralPath $tmpBare -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Invoke-RfSqliteQuery -DataSource $Connection -Query @'
UPDATE dr_drill_results
   SET ended_at_utc          = @end,
       reconstructed_head_sha = @rec,
       sha_matches            = @shaok,
       fsck_ok                = @fsckok,
       commits_walked         = @cw,
       files_written          = @fw,
       bytes_written          = @bw,
       duration_ms            = @dur,
       outcome                = @oc,
       failure_message        = @fail
 WHERE drill_id = @id
'@ -SqlParameters @{
                end    = (Get-Date).ToUniversalTime().ToString('o')
                rec    = if ($reconstructedHead) { $reconstructedHead } else { [DBNull]::Value }
                shaok  = if ($shaMatches) { 1 } else { 0 }
                fsckok = if ($fsckOk) { 1 } else { 0 }
                cw     = $commitsWalked
                fw     = $filesWritten
                bw     = $bytesWritten
                dur    = [int]$sw.Elapsed.TotalMilliseconds
                oc     = $outcome
                fail   = if ($failure) { $failure } else { [DBNull]::Value }
                id     = $drillId
            } | Out-Null
        }

        Write-RfAdminEvent -EventType 'dr_drill' -Subject ("snapshot #$sid ($rid)") -Actor $actor -Data @{
            drill_id       = $drillId
            snapshot_id    = $sid
            repo_id        = $rid
            outcome        = $outcome
            sha_matches    = $shaMatches
            fsck_ok        = $fsckOk
            commits_walked = $commitsWalked
            duration_ms    = [int]$sw.Elapsed.TotalMilliseconds
            failure        = $failure
        }

        $results.Add([PSCustomObject]@{
            DrillId              = $drillId
            SnapshotId           = $sid
            RepoId               = $rid
            ExpectedHeadSha      = $expectedHead
            ReconstructedHeadSha = $reconstructedHead
            ShaMatches           = $shaMatches
            FsckOk               = $fsckOk
            Outcome              = $outcome
            CommitsWalked        = $commitsWalked
            FilesWritten         = $filesWritten
            BytesWritten         = $bytesWritten
            DurationMs           = [int]$sw.Elapsed.TotalMilliseconds
            FailureMessage       = $failure
        }) | Out-Null
    }

    return @($results)
}
