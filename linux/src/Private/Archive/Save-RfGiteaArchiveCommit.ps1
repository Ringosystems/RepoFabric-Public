function Save-RfGiteaArchiveCommit {
    <#
    .SYNOPSIS
        Archives a single Gitea commit into the local content-addressed
        archive tables for byte-perfect restore.

    .DESCRIPTION
        Phase D.6. Called by Invoke-RfPublish, Invoke-RfPromote,
        Invoke-RfRevert (on successful pushes) and Update-RfDriftDetection
        (on detected external commits) so every commit on every virtual
        repo's main branch ends up in SQLite with its full content.

        Three-step pull from Gitea's REST API:
          1. GET /repos/{org}/{name}/git/commits/{sha} returns the commit
             metadata (author, committer, message, tree sha, parents).
          2. GET /repos/{org}/{name}/git/trees/{tree_sha}?recursive=1
             returns the tree listing (every file path under the commit's
             root tree, with each file's blob sha).
          3. For each file blob, GET /repos/{org}/{name}/git/blobs/{sha}
             returns base64-encoded content. We decode, hash with
             SHA-256, and store under content_sha256.

        Idempotent: every INSERT is OR IGNORE keyed on the natural key
        (content_sha256 for blobs, commit_sha for commits, (commit_sha,
        file_path) for files). Re-archiving the same commit is a fast
        no-op driven entirely by primary-key uniqueness checks.

    .PARAMETER RepoId
        Virtual repo id; written verbatim into gitea_archive_commits.repo_id.

    .PARAMETER CommitSha
        The commit to archive. Must already exist on Gitea.

    .PARAMETER Source
        Why this commit is being archived: 'publish' | 'promote' |
        'revert' | 'drift_captured' | 'snapshot_backfill' | 'restore'.

    .PARAMETER Configuration
        Optional resolved Configuration. Defaults to Get-RfConfiguration.

    .PARAMETER Connection
        Optional state DB path.

    .OUTPUTS
        PSCustomObject:
          * CommitSha       echoes input
          * AlreadyArchived true if the commit was already in the table
          * BlobsWritten    count of new blobs added (0 if AlreadyArchived)
          * FilesIndexed    count of files in the commit's tree
          * BytesArchived   total bytes of new blob content
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$CommitSha,
        [Parameter(Mandatory)]
        [ValidateSet('publish','promote','revert','drift_captured','snapshot_backfill','restore')]
        [string]$Source,
        [hashtable]$Configuration,
        [object]$Connection
    )

    if (-not $Configuration) { $Configuration = Get-RfConfiguration }
    if (-not $Connection)    { $Connection    = Open-RfStateDatabase }

    # Idempotency check before any network calls.
    $existing = Invoke-RfSqliteQuery -DataSource $Connection `
        -Query 'SELECT 1 AS hit FROM gitea_archive_commits WHERE commit_sha = @sha LIMIT 1' `
        -SqlParameters @{ sha = $CommitSha } | Select-Object -First 1
    if ($existing) {
        return [PSCustomObject]@{
            CommitSha       = $CommitSha
            AlreadyArchived = $true
            BlobsWritten    = 0
            FilesIndexed    = 0
            BytesArchived   = 0
        }
    }

    # Resolve the Gitea repo path. For 'main' and any other named virtual
    # repo, Get-RfRepoTargetPaths gives the canonical 'org/repo' string.
    $repoPaths = Get-RfRepoTargetPaths -RepoId $RepoId -DataSource $Connection
    $orgRepo = [string]$repoPaths.GiteaRepoPath

    $target = $Configuration.target
    foreach ($req in 'gitea_url','gitea_pat','gitea_user') {
        if (-not $target.$req) { throw "Save-RfGiteaArchiveCommit needs target.$req in configuration." }
    }
    $baseUrl = ([string]$target.gitea_url).TrimEnd('/')
    $authHeader = 'Basic ' + [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes("$($target.gitea_user):$($target.gitea_pat)"))
    $headers = @{ Authorization = $authHeader; Accept = 'application/json' }

    # ---------- 1. Commit metadata ----------
    $commitUrl = "$baseUrl/api/v1/repos/$orgRepo/git/commits/$CommitSha"
    $commit = Invoke-RestMethod -Method Get -Uri $commitUrl -Headers $headers -ErrorAction Stop

    $treeSha = [string]$commit.tree.sha
    $parentShas = @($commit.parents | ForEach-Object { [string]$_.sha }) | Where-Object { $_ }

    # ---------- 2. Tree listing (recursive) ----------
    $treeUrl = "$baseUrl/api/v1/repos/$orgRepo/git/trees/$treeSha`?recursive=true&per_page=1000"
    $tree = Invoke-RestMethod -Method Get -Uri $treeUrl -Headers $headers -ErrorAction Stop
    $entries = @($tree.tree | Where-Object { $_.type -eq 'blob' })

    $now = Get-RfTimestamp
    $blobsWritten = 0
    $bytesArchived = 0
    $filesIndexed = 0

    # ---------- 3. Per-file blobs ----------
    # The build order matters for the FK references: blobs first, then
    # the commit row, then files (which reference both).
    $fileRows = New-Object System.Collections.Generic.List[hashtable]
    foreach ($e in $entries) {
        $filePath = [string]$e.path
        $blobSha = [string]$e.sha   # Gitea's git-object sha; not the same as content_sha256

        $blobUrl = "$baseUrl/api/v1/repos/$orgRepo/git/blobs/$blobSha"
        $blob = Invoke-RestMethod -Method Get -Uri $blobUrl -Headers $headers -ErrorAction Stop

        $contentBytes = [byte[]]@()
        if ($blob.encoding -eq 'base64' -and $blob.content) {
            $contentBytes = [Convert]::FromBase64String([string]$blob.content)
        } elseif ($blob.content) {
            $contentBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$blob.content)
        }
        $contentText = [System.Text.Encoding]::UTF8.GetString($contentBytes)
        $contentSize = $contentBytes.Length

        $sha256Hex = ''
        if ($contentSize -gt 0) {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashBytes = $hasher.ComputeHash($contentBytes)
                $sha256Hex = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
            } finally { $hasher.Dispose() }
        } else {
            # SHA-256 of empty input is the standard empty hash; preserves
            # the FK chain even for an empty file (rare but possible).
            $sha256Hex = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        }

        # Insert blob row (OR IGNORE on the primary key dedupes).
        $rowCheck = Invoke-RfSqliteQuery -DataSource $Connection `
            -Query 'SELECT 1 AS hit FROM gitea_archive_blobs WHERE content_sha256 = @s LIMIT 1' `
            -SqlParameters @{ s = $sha256Hex } | Select-Object -First 1
        if (-not $rowCheck) {
            Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT OR IGNORE INTO gitea_archive_blobs (content_sha256, content_text, content_size, first_seen_utc)
VALUES (@s, @c, @sz, @now)
'@ -SqlParameters @{
                s   = $sha256Hex
                c   = $contentText
                sz  = [int]$contentSize
                now = $now
            } | Out-Null
            $blobsWritten++
            $bytesArchived += $contentSize
        }

        $mode = if ($e.mode) { [string]$e.mode } else { '100644' }
        $fileRows.Add(@{
            CommitSha     = $CommitSha
            FilePath      = $filePath
            ContentSha256 = $sha256Hex
            Mode          = $mode
        })
        $filesIndexed++
    }

    # ---------- Commit row ----------
    $authorName     = [string]$commit.commit.author.name
    $authorEmail    = [string]$commit.commit.author.email
    $authorDate     = [string]$commit.commit.author.date
    $committerName  = [string]$commit.commit.committer.name
    $committerEmail = [string]$commit.commit.committer.email
    $committerDate  = [string]$commit.commit.committer.date
    $message        = [string]$commit.commit.message

    Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT OR IGNORE INTO gitea_archive_commits
    (commit_sha, repo_id, parent_shas_json, tree_sha,
     author_name, author_email, author_date_utc,
     committer_name, committer_email, committer_date_utc,
     message, source, archived_at_utc)
VALUES
    (@sha, @rid, @parents, @tree,
     @aname, @aemail, @adate,
     @cname, @cemail, @cdate,
     @msg, @src, @now)
'@ -SqlParameters @{
        sha     = $CommitSha
        rid     = $RepoId
        parents = (ConvertTo-Json -InputObject @($parentShas) -Compress -AsArray)
        tree    = if ($treeSha) { $treeSha } else { [DBNull]::Value }
        aname   = if ($authorName) { $authorName } else { [DBNull]::Value }
        aemail  = if ($authorEmail) { $authorEmail } else { [DBNull]::Value }
        adate   = if ($authorDate) { $authorDate } else { [DBNull]::Value }
        cname   = if ($committerName) { $committerName } else { [DBNull]::Value }
        cemail  = if ($committerEmail) { $committerEmail } else { [DBNull]::Value }
        cdate   = if ($committerDate) { $committerDate } else { [DBNull]::Value }
        msg     = if ($message) { $message } else { [DBNull]::Value }
        src     = $Source
        now     = $now
    } | Out-Null

    # ---------- File rows ----------
    foreach ($fr in $fileRows) {
        Invoke-RfSqliteQuery -DataSource $Connection -Query @'
INSERT OR IGNORE INTO gitea_archive_files (commit_sha, file_path, content_sha256, mode)
VALUES (@sha, @path, @csha, @mode)
'@ -SqlParameters @{
            sha  = $fr.CommitSha
            path = $fr.FilePath
            csha = $fr.ContentSha256
            mode = $fr.Mode
        } | Out-Null
    }

    [PSCustomObject]@{
        CommitSha       = $CommitSha
        AlreadyArchived = $false
        BlobsWritten    = $blobsWritten
        FilesIndexed    = $filesIndexed
        BytesArchived   = $bytesArchived
    }
}
