function Update-RfDriftDetection {
    <#
    .SYNOPSIS
        Detects external commits on each virtual repo's Gitea backing
        tree and records them as drift_events for operator review.

    .DESCRIPTION
        Phase D.5. Anyone with the configured Gitea PAT (typically
        operators with shell access to the box, or scripts using the
        same credentials) can push directly to the manifest repos,
        bypassing RepoFabric's publisher. This cmdlet walks each
        virtual repo's recent commit history via Gitea's REST API
        and writes a drift_events row for any commit whose author
        email does not match the configured publisher identity.

        The cron entry calls this every 15 minutes by default. Running
        it manually is supported for testing; -RepoId scopes the run
        to one repo.

        The cmdlet's INSERT is OR IGNORE, so re-running for already-
        recorded commits is a no-op. The unique (repo_id, commit_sha)
        index guarantees no duplicates.

    .PARAMETER RepoId
        Optional. Scope detection to a single virtual repo. When
        omitted, iterates every active row in virtual_repos.

    .PARAMETER LookbackCommits
        Number of recent commits to inspect per repo. Default 50.
        The Gitea API caps at 50 by default; raising this implies
        paged calls which the current implementation does not do.

    .PARAMETER Connection
        Optional state DB path.

    .PARAMETER Configuration
        Optional resolved Configuration object.

    .OUTPUTS
        PSCustomObject:
          * ReposScanned   int
          * CommitsScanned int
          * DriftDetected  int (new rows written)
          * Errors         array of per-repo error strings (non-fatal)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoId,
        [int]$LookbackCommits = 50,
        [object]$Connection,
        [hashtable]$Configuration
    )

    if (-not $Connection)    { $Connection = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    $target = $Configuration.target
    if (-not $target -or -not $target.gitea_url -or -not $target.gitea_pat -or -not $target.gitea_user) {
        throw "Drift detection requires gitea_url, gitea_pat, and gitea_user in solution.yaml.targets."
    }

    # Any commit by one of these author emails is treated as "our
    # publisher" and skipped. The list includes the current
    # gitea_author_email plus historical identities (e.g. wgrs-publisher
    # from the pre-RepoFabric era) so rename-history commits do not
    # generate drift noise. Operators can add more via
    # solution.yaml's targets.gitea_known_publisher_emails.
    $knownPublisherEmails = @($Configuration.target.gitea_known_publisher_emails) | Where-Object { $_ }
    if (-not $knownPublisherEmails -or $knownPublisherEmails.Count -eq 0) {
        $knownPublisherEmails = @(
            if ($target.gitea_author_email) { [string]$target.gitea_author_email } else { 'repofabric-publisher@example.com' },
            'wgrs-publisher@example.com'
        )
    }

    $repos = if ($RepoId) {
        @(Get-RfVirtualRepo -RepoId $RepoId -DataSource $Connection)
    } else {
        @(Get-RfVirtualRepo -DataSource $Connection | Where-Object { $_.Status -eq 'active' })
    }

    $baseUrl = ([string]$target.gitea_url).TrimEnd('/')
    $authHeader = 'Basic ' + [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("$($target.gitea_user):$($target.gitea_pat)")
    )
    $headers = @{
        Authorization = $authHeader
        Accept        = 'application/json'
    }

    $reposScanned   = 0
    $commitsScanned = 0
    $driftDetected  = 0
    $errors         = New-Object System.Collections.Generic.List[string]
    $nowUtc         = (Get-Date).ToUniversalTime().ToString('o')

    foreach ($repo in @($repos)) {
        if (-not $repo -or -not $repo.GiteaRepoPath) { continue }
        $reposScanned++
        $branch = 'main'
        $commitsUrl = "$baseUrl/api/v1/repos/$($repo.GiteaRepoPath)/commits?sha=$branch&limit=$LookbackCommits"

        try {
            $commits = Invoke-RestMethod -Method Get -Uri $commitsUrl -Headers $headers -ErrorAction Stop
        } catch {
            $errors.Add(("[{0}] commits fetch failed: {1}" -f $repo.RepoId, $_.Exception.Message)) | Out-Null
            continue
        }

        foreach ($c in @($commits)) {
            $commitsScanned++
            $sha = [string]$c.sha
            if (-not $sha) { continue }

            $authorEmail = ''
            try { $authorEmail = [string]$c.commit.author.email } catch {}
            # Skip our own publisher commits (current and historical).
            $isKnownPublisher = $false
            foreach ($known in $knownPublisherEmails) {
                if ($authorEmail -and $authorEmail -ieq $known) { $isKnownPublisher = $true; break }
            }
            if ($isKnownPublisher) { continue }

            $authorName = ''
            try { $authorName = [string]$c.commit.author.name } catch {}
            $commitMsg  = ''
            try { $commitMsg = [string]$c.commit.message } catch {}
            $commitDate = ''
            try { $commitDate = [string]$c.commit.author.date } catch {}

            # Files-changed list lives in c.files; structure varies by
            # Gitea version. Best-effort capture as JSON.
            $filesJson = '[]'
            try {
                if ($c.files) {
                    $filesJson = ConvertTo-Json -InputObject @($c.files | ForEach-Object {
                        @{ filename = [string]$_.filename; status = [string]$_.status }
                    }) -Compress -Depth 4
                }
            } catch { }

            $inserted = Invoke-RfSqliteReturning -DataSource $Connection -Query @'
INSERT OR IGNORE INTO drift_events
    (detected_at_utc, repo_id, gitea_commit_sha,
     gitea_commit_author, gitea_commit_author_email,
     gitea_commit_message, gitea_commit_date, files_changed_json)
VALUES
    (@now, @rid, @sha, @aname, @aemail, @msg, @date, @files)
RETURNING drift_event_id
'@ -SqlParameters @{
                now    = $nowUtc
                rid    = [string]$repo.RepoId
                sha    = $sha
                aname  = if ($authorName) { $authorName } else { [DBNull]::Value }
                aemail = if ($authorEmail) { $authorEmail } else { [DBNull]::Value }
                msg    = if ($commitMsg) { $commitMsg } else { [DBNull]::Value }
                date   = if ($commitDate) { $commitDate } else { [DBNull]::Value }
                files  = $filesJson
            }

            if ($inserted -and $inserted.Count -gt 0) {
                $driftDetected++
                Write-RfLog -Level Warning -Message ("Drift detected in '{0}': commit {1} by {2} ({3}) -- {4}" -f
                    $repo.RepoId, $sha.Substring(0, [Math]::Min(8, $sha.Length)), $authorName, $authorEmail,
                    (($commitMsg -split "`n", 2)[0]))

                # Archive the drift commit so a future restore can include
                # the operator's external changes if they choose to keep
                # them. Best-effort.
                try {
                    $null = Save-RfGiteaArchiveCommit `
                        -RepoId        $repo.RepoId `
                        -CommitSha     $sha `
                        -Source        'drift_captured' `
                        -Configuration $Configuration `
                        -Connection    $Connection
                    $null = New-RfGiteaArchiveSnapshot `
                        -RepoId         $repo.RepoId `
                        -HeadCommitSha  $sha `
                        -Reason         'drift' `
                        -TriggerEventId ([int]$inserted[0].drift_event_id) `
                        -Notes          ("Drift snapshot: commit by " + $authorName + " <" + $authorEmail + ">") `
                        -Connection     $Connection
                } catch {
                    Write-RfLog -Level Warning -Message ("Gitea archive write failed for drift commit {0}: {1}" -f $sha, $_.Exception.Message)
                }
            }
        }
    }

    if ($driftDetected -gt 0) {
        Write-RfAdminEvent -EventType 'drift_detected' -Subject "$driftDetected new" -Actor 'SYSTEM (cron)' -Data @{
            repos_scanned   = $reposScanned
            commits_scanned = $commitsScanned
            drift_detected  = $driftDetected
            errors          = @($errors)
        }
    }

    [PSCustomObject]@{
        ReposScanned   = $reposScanned
        CommitsScanned = $commitsScanned
        DriftDetected  = $driftDetected
        Errors         = @($errors)
    }
}
