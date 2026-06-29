function New-RfArchiveSnapshot {
    <#
    .SYNOPSIS
        Takes a Gitea archive snapshot for one or every active virtual repo.

    .DESCRIPTION
        Phase D.6 daily cron entry plus the operator-facing manual
        snapshot button. For each active virtual repo, looks up the
        current HEAD via Gitea's API, archives the commit if it is
        not already in gitea_archive_commits (most days it is, since
        publish/promote/drift hooks keep the table fresh), then writes
        a gitea_archive_snapshots row with the chosen Reason.

        Idempotent: snapshots are append-only, so calling this multiple
        times in a day produces multiple snapshot rows pointing at the
        same HEAD if nothing changed. That is by design; the rows form
        a "we checked at this time" audit trail in addition to the
        recovery-point function.

    .PARAMETER RepoId
        Optional. Scope to a single virtual repo. Default iterates every
        active row in virtual_repos.

    .PARAMETER Reason
        publish | promote | drift | daily | manual | pre_upgrade |
        restore_verification. Defaults to 'manual' so direct operator
        invocations are correctly tagged; the cron passes 'daily'.

    .PARAMETER Notes
        Free-form operator note recorded on every snapshot row written.

    .PARAMETER Configuration
        Optional resolved Configuration.

    .PARAMETER Connection
        Optional state DB path.

    .OUTPUTS
        PSCustomObject:
          * ReposCovered    int
          * SnapshotsTaken  int
          * Errors          array of per-repo error strings (non-fatal)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoId,
        [ValidateSet('publish','promote','drift','daily','manual','pre_upgrade','restore_verification')]
        [string]$Reason = 'manual',
        [string]$Notes = '',
        [hashtable]$Configuration,
        [object]$Connection
    )

    if (-not $Connection)    { $Connection    = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    $target = $Configuration.target
    foreach ($req in 'gitea_url','gitea_pat','gitea_user') {
        if (-not $target.$req) { throw "New-RfArchiveSnapshot needs target.$req in configuration." }
    }

    $repos = if ($RepoId) {
        @(Get-RfVirtualRepo -RepoId $RepoId -DataSource $Connection)
    } else {
        @(Get-RfVirtualRepo -DataSource $Connection | Where-Object { $_.Status -eq 'active' })
    }

    $baseUrl = ([string]$target.gitea_url).TrimEnd('/')
    $authHeader = 'Basic ' + [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("$($target.gitea_user):$($target.gitea_pat)"))
    $headers = @{ Authorization = $authHeader; Accept = 'application/json' }

    $reposCovered  = 0
    $snapshotsTaken = 0
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($repo in @($repos)) {
        if (-not $repo -or -not $repo.GiteaRepoPath) { continue }
        if (-not $PSCmdlet.ShouldProcess($repo.RepoId, "Snapshot ($Reason)")) { continue }
        $reposCovered++

        try {
            # Latest commit on main = HEAD.
            $url = "$baseUrl/api/v1/repos/$($repo.GiteaRepoPath)/commits?sha=main&limit=1"
            $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop
            if (-not $resp -or -not $resp[0] -or -not $resp[0].sha) {
                $errors.Add(("[{0}] no commits on main yet; nothing to snapshot." -f $repo.RepoId)) | Out-Null
                continue
            }
            $headSha = [string]$resp[0].sha

            # Archive the commit if it is new. Existing commits short-
            # circuit inside Save-RfGiteaArchiveCommit via the early
            # idempotency check, so this is cheap when nothing changed.
            $null = Save-RfGiteaArchiveCommit `
                -RepoId        $repo.RepoId `
                -CommitSha     $headSha `
                -Source        'snapshot_backfill' `
                -Configuration $Configuration `
                -Connection    $Connection

            $null = New-RfGiteaArchiveSnapshot `
                -RepoId        $repo.RepoId `
                -HeadCommitSha $headSha `
                -Reason        $Reason `
                -Notes         $Notes `
                -Connection    $Connection
            $snapshotsTaken++
        } catch {
            $errors.Add(("[{0}] {1}" -f $repo.RepoId, $_.Exception.Message)) | Out-Null
        }
    }

    [PSCustomObject]@{
        ReposCovered   = $reposCovered
        SnapshotsTaken = $snapshotsTaken
        Errors         = @($errors)
    }
}
