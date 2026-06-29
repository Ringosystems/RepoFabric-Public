function Restore-RfGiteaFromArchive {
    <#
    .SYNOPSIS
        Reconstructs a virtual repo's manifest tree from the SQLite
        gitea_archive_* tables into a bare git repository on disk.

    .DESCRIPTION
        Phase D.7. The archive captured by Phase D.6 is the canonical
        backup; this cmdlet is the restore counterpart that turns those
        rows back into a real git repository whose head commit SHA
        matches the archived value byte-for-byte.

        Procedure:
          1. Look up the snapshot row -> head_commit_sha + repo_id.
          2. Walk gitea_archive_commits backwards from head, following
             parent_shas_json, building a topologically-sorted list
             (parents before children).
          3. Initialise a bare git repo at -DestinationBareRepo.
          4. For each commit in the sorted list:
               * For each file in gitea_archive_files, read its blob
                 from gitea_archive_blobs and 'git hash-object -w' it
                 into the bare repo's object DB.
               * Build the tree with 'git mktree' from the index lines.
               * Build the commit with 'git commit-tree' using the
                 archived author / committer / date / parent metadata
                 via GIT_AUTHOR_* / GIT_COMMITTER_* env vars.
               * Verify the computed commit SHA matches the archived
                 commit_sha. Abort on mismatch unless -AllowMismatch.
          5. Update refs/heads/main to point at the head commit.
          6. Return a summary.

        The cmdlet does NOT push the reconstructed repo to Gitea by
        default. The reconstruction is the verifiable part; pushing
        is a separate operator decision (real disaster recovery, not
        a drill). Pass -PushToTarget to push via the configured
        gitea_pat after reconstruction.

    .PARAMETER SnapshotId
        gitea_archive_snapshots.snapshot_id to restore from.

    .PARAMETER DestinationBareRepo
        Filesystem path for the reconstructed bare repo. Must NOT
        exist (the cmdlet creates it). Use a tmpfs path under
        /tmp/repofabric-restore-... when verifying a backup.

    .PARAMETER AllowMismatch
        Continue past a commit whose reconstructed SHA does not match
        the archive's stored SHA. By default, a mismatch aborts the
        restore. Mismatches are very rare and indicate either an
        archive bug or a git-version object-format discrepancy.

    .PARAMETER PushToTarget
        After reconstruction, push refs/heads/main to the live Gitea
        repo for the snapshot's repo_id using the configured PAT.
        Destination is the empty Gitea repo at gitea_repo_path. The
        push uses -force; the caller is asserting they have already
        emptied (or freshly created) the target repo.

    .PARAMETER Configuration
        Optional resolved Configuration.

    .PARAMETER Connection
        Optional state DB path.

    .OUTPUTS
        PSCustomObject:
          * SnapshotId
          * RepoId
          * ExpectedHeadSha
          * ReconstructedHeadSha
          * ShaMatches      bool
          * CommitsWalked   int
          * FilesWritten    int
          * BytesWritten    int
          * BareRepoPath    string
          * Pushed          bool
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][int]$SnapshotId,
        [Parameter(Mandatory)][string]$DestinationBareRepo,
        [switch]$AllowMismatch,
        [switch]$PushToTarget,
        [hashtable]$Configuration,
        [object]$Connection
    )

    if (-not $Connection)    { $Connection    = Open-RfStateDatabase }
    if (-not $Configuration) { $Configuration = Get-RfConfiguration }

    if (Test-Path -LiteralPath $DestinationBareRepo) {
        throw "DestinationBareRepo '$DestinationBareRepo' already exists. Choose an empty path."
    }

    $snapshot = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT snapshot_id, repo_id, head_commit_sha, taken_at_utc
  FROM gitea_archive_snapshots
 WHERE snapshot_id = @id
'@ -SqlParameters @{ id = $SnapshotId } | Select-Object -First 1
    if (-not $snapshot) {
        throw "Snapshot #$SnapshotId not found."
    }
    $repoId = [string]$snapshot.repo_id
    $headSha = [string]$snapshot.head_commit_sha

    if (-not $PSCmdlet.ShouldProcess("Snapshot #$SnapshotId (repo '$repoId', head $($headSha.Substring(0, 8)))", "Restore into $DestinationBareRepo")) { return }

    $git = Get-Command git -ErrorAction Stop

    # ---------- 1. init bare repo ----------
    New-Item -ItemType Directory -Path $DestinationBareRepo -Force | Out-Null
    & $git.Source init --bare $DestinationBareRepo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init --bare failed at $DestinationBareRepo" }
    # Block the inherited config from rewriting refs.
    & $git.Source -C $DestinationBareRepo config gc.auto 0 2>&1 | Out-Null

    # ---------- 2. topological walk of commits ----------
    # Pull every reachable commit from head_sha. SQLite's recursive CTE
    # follows parent_shas_json entries. JSON_EACH is in SQLite 3.38+
    # which the Debian 12 image ships. The CTE returns each ancestor
    # exactly once thanks to the visited set + DISTINCT outer select.
    $reachableRows = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
WITH RECURSIVE
    walk(sha) AS (
        SELECT @head
        UNION
        SELECT j.value
          FROM walk w
          JOIN gitea_archive_commits c ON c.commit_sha = w.sha
          JOIN json_each(c.parent_shas_json) j
    )
SELECT DISTINCT c.commit_sha, c.parent_shas_json, c.author_name, c.author_email,
                c.author_date_utc, c.committer_name, c.committer_email,
                c.committer_date_utc, c.message
  FROM walk w
  JOIN gitea_archive_commits c ON c.commit_sha = w.sha
'@ -SqlParameters @{ head = $headSha }

    $commitsBySha = @{}
    foreach ($r in @($reachableRows)) {
        $commitsBySha[[string]$r.commit_sha] = $r
    }
    if (-not $commitsBySha.ContainsKey($headSha)) {
        throw "Head commit $headSha is not present in gitea_archive_commits; archive is incomplete for this snapshot."
    }

    # Kahn-style topological sort: parents before children. Build a
    # parents map per commit and an in-degree count over reachable
    # parents only (commits whose parents are outside the reachable
    # set, e.g. the repo's initial commit, get in-degree zero).
    $parentMap = @{}
    $inDegree  = @{}
    foreach ($sha in $commitsBySha.Keys) {
        $parents = @()
        try {
            $parsed = $commitsBySha[$sha].parent_shas_json | ConvertFrom-Json
            $parents = @($parsed | Where-Object { $_ -and $commitsBySha.ContainsKey([string]$_) })
        } catch {}
        $parentMap[$sha] = @($parents | ForEach-Object { [string]$_ })
        $inDegree[$sha]  = 0
    }
    foreach ($sha in $commitsBySha.Keys) {
        foreach ($p in $parentMap[$sha]) {
            $inDegree[$sha]++
        }
    }
    # Reverse adjacency: for each parent, the children that depend on it.
    $childrenOf = @{}
    foreach ($sha in $commitsBySha.Keys) {
        foreach ($p in $parentMap[$sha]) {
            if (-not $childrenOf.ContainsKey($p)) { $childrenOf[$p] = New-Object System.Collections.Generic.List[string] }
            $childrenOf[$p].Add($sha) | Out-Null
        }
    }
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($sha in $commitsBySha.Keys) {
        if ($inDegree[$sha] -eq 0) { $queue.Enqueue($sha) }
    }
    $ordered = New-Object System.Collections.Generic.List[string]
    while ($queue.Count -gt 0) {
        $sha = $queue.Dequeue()
        $ordered.Add($sha) | Out-Null
        if ($childrenOf.ContainsKey($sha)) {
            foreach ($child in $childrenOf[$sha]) {
                $inDegree[$child]--
                if ($inDegree[$child] -eq 0) { $queue.Enqueue($child) }
            }
        }
    }
    if ($ordered.Count -ne $commitsBySha.Count) {
        throw "Topological sort failed (cycle or missing parent in archive)."
    }

    # ---------- 3-4. reconstruct ----------
    $filesWritten = 0
    $bytesWritten = 0
    $shaRemap = @{}    # archive sha -> reconstructed sha (should always equal in ideal case)
    $mismatchedCommits = New-Object System.Collections.Generic.List[string]

    foreach ($archiveSha in $ordered) {
        $row = $commitsBySha[$archiveSha]

        # Load the file listing for this commit.
        $files = Invoke-RfSqliteQuery -DataSource $Connection -Query @'
SELECT f.file_path, f.mode, b.content_text, b.content_size
  FROM gitea_archive_files f
  JOIN gitea_archive_blobs  b ON b.content_sha256 = f.content_sha256
 WHERE f.commit_sha = @sha
 ORDER BY f.file_path
'@ -SqlParameters @{ sha = $archiveSha }

        # Build the index by hash-object'ing each blob into the bare
        # repo. Capture the resulting git blob sha; that is what
        # mktree consumes.
        $mktreeLines = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($files)) {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmpFile, [string]$f.content_text, [System.Text.UTF8Encoding]::new($false))
                $blobSha = (& $git.Source --git-dir=$DestinationBareRepo hash-object -w $tmpFile 2>&1).Trim()
                if ($LASTEXITCODE -ne 0 -or -not $blobSha) {
                    throw "git hash-object failed for $($f.file_path) in $archiveSha"
                }
                $filesWritten++
                $bytesWritten += [int64]$f.content_size

                $mode = [string]$f.mode
                if (-not $mode) { $mode = '100644' }
                $mktreeLines.Add(("{0} blob {1}`t{2}" -f $mode, $blobSha, $f.file_path)) | Out-Null
            } finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        # mktree builds a tree from path-by-path lines. It does not
        # support nested paths directly; we need git update-index +
        # write-tree instead. Switch to that pattern.
        # Use an index file in the bare repo's $GIT_DIR/index.
        $env:GIT_INDEX_FILE = (Join-Path $DestinationBareRepo "restore-index-$archiveSha")
        if (Test-Path -LiteralPath $env:GIT_INDEX_FILE) { Remove-Item -LiteralPath $env:GIT_INDEX_FILE -Force }
        try {
            foreach ($line in $mktreeLines) {
                # Parse 'MODE blob SHA\tPATH'.
                $tabIdx = $line.IndexOf("`t")
                $left  = $line.Substring(0, $tabIdx)
                $path  = $line.Substring($tabIdx + 1)
                $parts = $left.Split(' ', 3)
                $mode  = $parts[0]
                $blob  = $parts[2]
                & $git.Source --git-dir=$DestinationBareRepo update-index --add --cacheinfo "$mode,$blob,$path" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "git update-index failed for $path in $archiveSha" }
            }
            $treeSha = (& $git.Source --git-dir=$DestinationBareRepo write-tree 2>&1).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $treeSha) { throw "git write-tree failed for $archiveSha" }

            # Build the commit. Parents must be rewritten to their
            # reconstructed shas (which equal archive shas in the
            # happy path), so we look them up via $shaRemap.
            $parentArgs = @()
            foreach ($p in $parentMap[$archiveSha]) {
                $reconstructedParent = if ($shaRemap.ContainsKey($p)) { $shaRemap[$p] } else { $p }
                $parentArgs += '-p'
                $parentArgs += $reconstructedParent
            }

            # Env vars carry the original author/committer/date so the
            # commit's SHA matches the archive byte-for-byte.
            $env:GIT_AUTHOR_NAME     = [string]$row.author_name
            $env:GIT_AUTHOR_EMAIL    = [string]$row.author_email
            $env:GIT_AUTHOR_DATE     = [string]$row.author_date_utc
            $env:GIT_COMMITTER_NAME  = [string]$row.committer_name
            $env:GIT_COMMITTER_EMAIL = [string]$row.committer_email
            $env:GIT_COMMITTER_DATE  = [string]$row.committer_date_utc

            $message = [string]$row.message
            $tmpMsg = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmpMsg, $message, [System.Text.UTF8Encoding]::new($false))
                $commitArgs = @('--git-dir=' + $DestinationBareRepo, 'commit-tree', $treeSha) + $parentArgs + @('-F', $tmpMsg)
                $reconstructedSha = (& $git.Source @commitArgs 2>&1).Trim()
                if ($LASTEXITCODE -ne 0 -or -not $reconstructedSha) {
                    throw "git commit-tree failed for $archiveSha"
                }
            } finally {
                Remove-Item -LiteralPath $tmpMsg -Force -ErrorAction SilentlyContinue
            }

            $shaRemap[$archiveSha] = $reconstructedSha
            if ($reconstructedSha -ne $archiveSha) {
                $mismatchedCommits.Add($archiveSha) | Out-Null
                if (-not $AllowMismatch) {
                    throw "Commit SHA mismatch: archive=$archiveSha vs reconstructed=$reconstructedSha. Pass -AllowMismatch to continue."
                }
            }
        } finally {
            if (Test-Path -LiteralPath $env:GIT_INDEX_FILE) { Remove-Item -LiteralPath $env:GIT_INDEX_FILE -Force }
            Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
            Remove-Item Env:\GIT_AUTHOR_NAME, Env:\GIT_AUTHOR_EMAIL, Env:\GIT_AUTHOR_DATE,
                        Env:\GIT_COMMITTER_NAME, Env:\GIT_COMMITTER_EMAIL, Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        }
    }

    # ---------- 5. set refs/heads/main ----------
    $reconstructedHead = $shaRemap[$headSha]
    & $git.Source --git-dir=$DestinationBareRepo update-ref refs/heads/main $reconstructedHead 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git update-ref refs/heads/main failed" }
    & $git.Source --git-dir=$DestinationBareRepo symbolic-ref HEAD refs/heads/main 2>&1 | Out-Null

    $shaMatches = ($reconstructedHead -eq $headSha)

    # ---------- 6. optional push ----------
    $pushed = $false
    if ($PushToTarget) {
        $repoPaths = Get-RfRepoTargetPaths -RepoId $repoId -DataSource $Connection
        $target = $Configuration.target
        $patPlain = if ($target.gitea_pat) { [string]$target.gitea_pat } elseif ($env:REPOFABRIC_GITEA_PAT) { [string]$env:REPOFABRIC_GITEA_PAT } else { $null }
        if (-not $patPlain) { throw "PushToTarget requires gitea_pat (no override available)." }
        $author = if ($target.gitea_user) { [string]$target.gitea_user } else { 'repofabric-publisher' }
        $cloneUrl = "$($target.gitea_url.TrimEnd('/'))/$($repoPaths.GiteaRepoPath).git"
        $authHeaderVal = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${author}:${patPlain}"))
        & $git.Source --git-dir=$DestinationBareRepo -c http.extraHeader="AUTHORIZATION: $authHeaderVal" push --force $cloneUrl "refs/heads/main:refs/heads/main" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git push to $cloneUrl failed" }
        $pushed = $true
    }

    [PSCustomObject]@{
        SnapshotId             = $SnapshotId
        RepoId                 = $repoId
        ExpectedHeadSha        = $headSha
        ReconstructedHeadSha   = $reconstructedHead
        ShaMatches             = $shaMatches
        CommitsWalked          = $ordered.Count
        FilesWritten           = $filesWritten
        BytesWritten           = $bytesWritten
        MismatchedCommits      = @($mismatchedCommits)
        BareRepoPath           = $DestinationBareRepo
        Pushed                 = $pushed
    }
}
